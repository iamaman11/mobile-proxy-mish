//! First-class PRODUCT IP rotation orchestration on the shared Tokio runtime.
//!
//! mish-rotation owns transition semantics. This coordinator executes exactly one operation using
//! the existing Cellular owner, root session and U4 public-IP path. It never owns a second network,
//! credential or runtime state machine.

use crate::airplane_effect::{AirplaneEffectError, AirplaneModeEffect, AirplaneModeState};
use crate::{
    CellularPolicyCoordinator, CellularPolicyPublication, CellularRuntimeCoordinator,
    ProxyCredentialGuard, ProxyRuntimeCoordinator, RootPolicyResult, RuntimeExecutionError,
    RuntimeExecutor,
};
use mish_cellular::{CellularAdmissionSnapshot, CellularAdmissionState};
use mish_rotation::{
    RotationFailure, RotationMutationOutcome, RotationPhase, RotationRestoreResult,
    RotationSnapshot, RotationStartError, RotationStateMachine,
};
use std::collections::HashSet;
use std::future::Future;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::task::JoinHandle;
use tokio::time::{Instant, timeout, timeout_at};

const ROTATION_SAFETY_DEADLINE: Duration = Duration::from_secs(90);
const PUBLIC_IP_EFFECT_TIMEOUT: Duration = Duration::from_secs(15);
const RESTORE_EFFECT_TIMEOUT: Duration = Duration::from_secs(15);
const SHUTDOWN_TASK_DRAIN_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationRuntimeStartError {
    RuntimeNotRunning,
    AlreadyInProgress,
    NoCurrentCellular,
    RootPolicyUnavailable,
    CredentialUnavailable,
    ExecutorUnavailable,
    StateUnavailable,
}

pub type RotationObserver = Arc<dyn Fn(RotationSnapshot) + Send + Sync + 'static>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum RotationAction {
    BeforeIp,
    EnableAirplane,
    DisableAirplane,
    AfterIp,
    RestoreOff,
}

struct RotationRuntimeState {
    machine: RotationStateMachine,
    deadline: Option<(u64, Instant)>,
    credential_guard: Option<ProxyCredentialGuard>,
    claimed: HashSet<(u64, RotationAction)>,
    cancel: Option<Arc<Notify>>,
    tasks: Vec<JoinHandle<()>>,
    observer: Option<RotationObserver>,
    closed: bool,
}

pub struct RotationRuntimeCoordinator {
    executor: Arc<RuntimeExecutor>,
    cellular: Arc<CellularRuntimeCoordinator>,
    policy: Arc<CellularPolicyCoordinator>,
    proxy: Arc<ProxyRuntimeCoordinator>,
    airplane: Arc<AirplaneModeEffect>,
    state: Mutex<RotationRuntimeState>,
}

impl RotationRuntimeCoordinator {
    pub fn new(
        executor: Arc<RuntimeExecutor>,
        cellular: Arc<CellularRuntimeCoordinator>,
        policy: Arc<CellularPolicyCoordinator>,
        proxy: Arc<ProxyRuntimeCoordinator>,
    ) -> Arc<Self> {
        let coordinator = Arc::new(Self {
            executor,
            cellular,
            airplane: policy.airplane_effect(),
            policy: Arc::clone(&policy),
            proxy,
            state: Mutex::new(RotationRuntimeState {
                machine: RotationStateMachine::new(),
                deadline: None,
                credential_guard: None,
                claimed: HashSet::new(),
                cancel: None,
                tasks: Vec::new(),
                observer: None,
                closed: false,
            }),
        });

        let weak: Weak<Self> = Arc::downgrade(&coordinator);
        policy.add_internal_observer(Arc::new(move |publication| {
            if let Some(coordinator) = weak.upgrade() {
                coordinator.observe_root_policy(publication);
            }
        }));

        coordinator
    }

    pub fn snapshot(&self) -> RotationSnapshot {
        self.state()
            .map(|state| state.machine.snapshot())
            .unwrap_or_else(|_| RotationSnapshot::idle())
    }

    pub fn set_observer(&self, observer: RotationObserver) {
        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observer = Some(Arc::clone(&observer));
            state.machine.snapshot()
        };
        notify(Some((observer, snapshot)));
    }

    pub fn start(self: &Arc<Self>) -> Result<u64, RotationRuntimeStartError> {
        let admission = self
            .cellular
            .admission_snapshot()
            .map_err(|_| RotationRuntimeStartError::StateUnavailable)?;
        let before_generation =
            admitted_generation(admission).ok_or(RotationRuntimeStartError::NoCurrentCellular)?;

        let root_current = self.policy.last_publication().is_some_and(|publication| {
            publication
                .admission
                .last_sequence()
                .is_some_and(|sequence| sequence.raw() == before_generation)
                && matches!(publication.result, RootPolicyResult::Enforced)
        });
        if !root_current {
            return Err(RotationRuntimeStartError::RootPolicyUnavailable);
        }

        let credential_guard = self
            .proxy
            .credential_guard()
            .ok_or(RotationRuntimeStartError::CredentialUnavailable)?;

        let (operation_id, snapshot, cancel, deadline) = {
            let mut state = self
                .state_mut()
                .map_err(|_| RotationRuntimeStartError::StateUnavailable)?;
            if state.closed {
                return Err(RotationRuntimeStartError::StateUnavailable);
            }
            let operation_id = state
                .machine
                .start(before_generation)
                .map_err(map_start_error)?;
            let deadline = Instant::now()
                .checked_add(ROTATION_SAFETY_DEADLINE)
                .ok_or(RotationRuntimeStartError::StateUnavailable)?;
            let cancel = Arc::new(Notify::new());
            state.deadline = Some((operation_id, deadline));
            state.credential_guard = Some(credential_guard);
            state.claimed.clear();
            state.cancel = Some(Arc::clone(&cancel));
            state.tasks.retain(|task| !task.is_finished());
            (operation_id, state.machine.snapshot(), cancel, deadline)
        };

        self.publish(snapshot);
        self.spawn_deadline(operation_id, deadline, cancel)?;
        self.schedule_for(snapshot)?;
        Ok(operation_id)
    }

    pub fn observe_cellular(self: &Arc<Self>, admission: CellularAdmissionSnapshot) {
        let Some(generation) = admission.last_sequence().map(|sequence| sequence.raw()) else {
            return;
        };
        let admitted = admission.state() == CellularAdmissionState::Admitted;
        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed {
                return;
            }
            let current = state.machine.snapshot();
            let Some(operation_id) = current.operation_id else {
                return;
            };
            if current.phase.terminal() {
                return;
            }
            match state
                .machine
                .observe_cellular(operation_id, generation, admitted)
            {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            }
        };
        self.after_transition(snapshot);
    }

    pub async fn shutdown(self: &Arc<Self>) -> bool {
        let (operation_id, cancel, tasks, snapshot) = {
            let Ok(mut state) = self.state.lock() else {
                return false;
            };
            if state.closed {
                return true;
            }
            state.closed = true;
            let current = state.machine.snapshot();
            let snapshot = if let Some(operation_id) = current.operation_id {
                if current.phase.terminal() {
                    current
                } else {
                    state
                        .machine
                        .fail(operation_id, RotationFailure::StateUnavailable)
                        .unwrap_or(current)
                }
            } else {
                current
            };
            (
                snapshot.operation_id,
                state.cancel.take(),
                std::mem::take(&mut state.tasks),
                snapshot,
            )
        };

        if let Some(cancel) = cancel {
            cancel.notify_waiters();
        }
        self.publish(snapshot);

        let mut clean = true;
        for task in tasks {
            if timeout(SHUTDOWN_TASK_DRAIN_TIMEOUT, task).await.is_err() {
                clean = false;
            }
        }

        if let Some(operation_id) = operation_id {
            let current = self.snapshot();
            if current.phase == RotationPhase::Failed && current.restore_required {
                self.restore_off_direct(operation_id).await;
            }
        }
        clean
    }

    fn observe_root_policy(self: &Arc<Self>, publication: CellularPolicyPublication) {
        let Some(generation) = publication
            .admission
            .last_sequence()
            .map(|sequence| sequence.raw())
        else {
            return;
        };
        let authorized = matches!(publication.result, RootPolicyResult::Enforced);
        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed {
                return;
            }
            let current = state.machine.snapshot();
            let Some(operation_id) = current.operation_id else {
                return;
            };
            if current.phase.terminal() {
                return;
            }
            match state
                .machine
                .observe_root_policy(operation_id, generation, authorized)
            {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            }
        };
        self.after_transition(snapshot);
    }

    fn spawn_deadline(
        self: &Arc<Self>,
        operation_id: u64,
        deadline: Instant,
        cancel: Arc<Notify>,
    ) -> Result<(), RotationRuntimeStartError> {
        let this = Arc::clone(self);
        self.spawn_owned(async move {
            if timeout_at(deadline, cancel.notified()).await.is_ok() {
                return;
            }
            let snapshot = {
                let Ok(mut state) = this.state.lock() else {
                    return;
                };
                if state.closed {
                    return;
                }
                let current = state.machine.snapshot();
                if current.operation_id != Some(operation_id) || current.phase.terminal() {
                    return;
                }
                match state.machine.deadline_exceeded(operation_id) {
                    Ok(snapshot) => snapshot,
                    Err(_) => return,
                }
            };
            this.after_transition(snapshot);
        })
        .map_err(|_| RotationRuntimeStartError::ExecutorUnavailable)
    }

    fn schedule_for(
        self: &Arc<Self>,
        snapshot: RotationSnapshot,
    ) -> Result<(), RotationRuntimeStartError> {
        let Some(operation_id) = snapshot.operation_id else {
            return Ok(());
        };
        let action = match snapshot.phase {
            RotationPhase::Preparing => Some(RotationAction::BeforeIp),
            RotationPhase::AirplaneEnabling => Some(RotationAction::EnableAirplane),
            RotationPhase::AirplaneDisabling => Some(RotationAction::DisableAirplane),
            RotationPhase::ProbingPublicIp => Some(RotationAction::AfterIp),
            RotationPhase::Failed if snapshot.restore_required => Some(RotationAction::RestoreOff),
            _ => None,
        };
        let Some(action) = action else {
            return Ok(());
        };

        {
            let mut state = self
                .state_mut()
                .map_err(|_| RotationRuntimeStartError::StateUnavailable)?;
            if state.closed || !state.claimed.insert((operation_id, action)) {
                return Ok(());
            }
        }

        let this = Arc::clone(self);
        let future: std::pin::Pin<Box<dyn Future<Output = ()> + Send>> = match action {
            RotationAction::BeforeIp => {
                Box::pin(async move { this.run_before_ip(operation_id).await })
            }
            RotationAction::EnableAirplane => {
                Box::pin(async move { this.run_enable_airplane(operation_id).await })
            }
            RotationAction::DisableAirplane => {
                Box::pin(async move { this.run_disable_airplane(operation_id).await })
            }
            RotationAction::AfterIp => {
                Box::pin(async move { this.run_after_ip(operation_id).await })
            }
            RotationAction::RestoreOff => {
                Box::pin(async move { this.restore_off_direct(operation_id).await })
            }
        };
        self.spawn_owned(future)
            .map_err(|_| RotationRuntimeStartError::ExecutorUnavailable)
    }

    async fn run_before_ip(self: Arc<Self>, operation_id: u64) {
        let Some((before_generation, deadline)) =
            self.operation_generation_deadline(operation_id, true)
        else {
            return;
        };
        let timeout_duration = remaining(deadline).min(PUBLIC_IP_EFFECT_TIMEOUT);
        let observation = match timeout_at(
            deadline,
            self.cellular
                .observe_public_egress_ip_async(timeout_duration),
        )
        .await
        {
            Ok(Ok(observation)) if observation.generation() == before_generation => observation,
            Ok(Ok(_)) | Ok(Err(_)) => {
                self.fail(operation_id, RotationFailure::BeforeIpFailed);
                return;
            }
            Err(_) => {
                self.fail(operation_id, RotationFailure::DeadlineExceeded);
                return;
            }
        };

        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if !operation_current(&state, operation_id) {
                return;
            }
            match state.machine.record_before_ip(
                operation_id,
                observation.generation(),
                observation.address(),
            ) {
                Ok(snapshot) => snapshot,
                Err(_) => {
                    drop(state);
                    self.fail(operation_id, RotationFailure::BeforeIpFailed);
                    return;
                }
            }
        };
        self.after_transition(snapshot);
    }

    async fn run_enable_airplane(self: Arc<Self>, operation_id: u64) {
        let Some(deadline) = self.operation_deadline(operation_id) else {
            return;
        };
        let outcome = match timeout_at(deadline, self.airplane.set(AirplaneModeState::Enabled))
            .await
        {
            Err(_) => {
                self.fail(operation_id, RotationFailure::DeadlineExceeded);
                return;
            }
            Ok(Ok(())) => RotationMutationOutcome::Applied,
            Ok(Err(AirplaneEffectError::MutationRejected)) => RotationMutationOutcome::Rejected,
            Ok(Err(AirplaneEffectError::MutationUncertain)) => RotationMutationOutcome::Uncertain,
            Ok(Err(_)) => {
                self.fail(operation_id, RotationFailure::AirplaneEnableFailed);
                return;
            }
        };

        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if !operation_current(&state, operation_id) {
                return;
            }
            match state
                .machine
                .airplane_enable_effect_completed(operation_id, outcome)
            {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            }
        };
        self.after_transition(snapshot);
        if snapshot.phase.terminal() {
            return;
        }

        let observed = match timeout_at(deadline, self.airplane.observe()).await {
            Ok(Ok(state)) => state,
            Err(_) => {
                self.fail(operation_id, RotationFailure::DeadlineExceeded);
                return;
            }
            Ok(Err(_)) => {
                self.fail(operation_id, RotationFailure::AirplaneObservationFailed);
                return;
            }
        };
        self.record_airplane_observation(operation_id, observed);
    }

    async fn run_disable_airplane(self: Arc<Self>, operation_id: u64) {
        let Some(deadline) = self.operation_deadline(operation_id) else {
            return;
        };
        let outcome = match timeout_at(deadline, self.airplane.set(AirplaneModeState::Disabled))
            .await
        {
            Err(_) => {
                self.fail(operation_id, RotationFailure::DeadlineExceeded);
                return;
            }
            Ok(Ok(())) => RotationMutationOutcome::Applied,
            Ok(Err(AirplaneEffectError::MutationRejected)) => RotationMutationOutcome::Rejected,
            Ok(Err(AirplaneEffectError::MutationUncertain)) => RotationMutationOutcome::Uncertain,
            Ok(Err(_)) => {
                self.fail(operation_id, RotationFailure::AirplaneDisableFailed);
                return;
            }
        };

        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if !operation_current(&state, operation_id) {
                return;
            }
            match state
                .machine
                .airplane_disable_effect_completed(operation_id, outcome)
            {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            }
        };
        self.after_transition(snapshot);
        if snapshot.phase.terminal() {
            return;
        }

        let observed = match timeout_at(deadline, self.airplane.observe()).await {
            Ok(Ok(state)) => state,
            Err(_) => {
                self.fail(operation_id, RotationFailure::DeadlineExceeded);
                return;
            }
            Ok(Err(_)) => {
                self.fail(operation_id, RotationFailure::AirplaneObservationFailed);
                return;
            }
        };
        self.record_airplane_observation(operation_id, observed);
    }

    async fn run_after_ip(self: Arc<Self>, operation_id: u64) {
        let Some((after_generation, deadline)) =
            self.operation_generation_deadline(operation_id, false)
        else {
            return;
        };
        let timeout_duration = remaining(deadline).min(PUBLIC_IP_EFFECT_TIMEOUT);
        let observation = match timeout_at(
            deadline,
            self.cellular
                .observe_public_egress_ip_async(timeout_duration),
        )
        .await
        {
            Ok(Ok(observation)) if observation.generation() == after_generation => observation,
            Ok(Ok(_)) | Ok(Err(_)) => {
                self.fail(operation_id, RotationFailure::AfterIpFailed);
                return;
            }
            Err(_) => {
                self.fail(operation_id, RotationFailure::DeadlineExceeded);
                return;
            }
        };

        if !self.credential_guard_current(operation_id) {
            self.fail(operation_id, RotationFailure::CredentialChanged);
            return;
        }

        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if !operation_current(&state, operation_id) {
                return;
            }
            match state.machine.record_after_ip(
                operation_id,
                observation.generation(),
                observation.address(),
            ) {
                Ok(snapshot) => snapshot,
                Err(_) => {
                    drop(state);
                    self.fail(operation_id, RotationFailure::AfterIpFailed);
                    return;
                }
            }
        };
        self.after_transition(snapshot);
    }

    fn record_airplane_observation(
        self: &Arc<Self>,
        operation_id: u64,
        observed: AirplaneModeState,
    ) {
        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if !operation_current(&state, operation_id) {
                return;
            }
            match state
                .machine
                .observe_airplane(operation_id, observed == AirplaneModeState::Enabled)
            {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            }
        };
        self.after_transition(snapshot);
    }

    fn fail(self: &Arc<Self>, operation_id: u64, failure: RotationFailure) {
        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if !operation_current(&state, operation_id) {
                return;
            }
            let effective_failure = if credential_guard_matches(&self.proxy, &state, operation_id) {
                failure
            } else {
                RotationFailure::CredentialChanged
            };
            match state.machine.fail(operation_id, effective_failure) {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            }
        };
        self.after_transition(snapshot);
    }

    fn after_transition(self: &Arc<Self>, snapshot: RotationSnapshot) {
        if snapshot.phase.terminal()
            && let Ok(state) = self.state.lock()
            && let Some(cancel) = state.cancel.as_ref()
        {
            cancel.notify_waiters();
        }
        self.publish(snapshot);
        let _ = self.schedule_for(snapshot);
    }

    async fn restore_off_direct(self: &Arc<Self>, operation_id: u64) {
        let restore = match timeout(RESTORE_EFFECT_TIMEOUT, self.airplane.observe()).await {
            Ok(Ok(AirplaneModeState::Disabled)) => RotationRestoreResult::AlreadyOff,
            Ok(Ok(AirplaneModeState::Enabled)) => {
                match timeout(
                    RESTORE_EFFECT_TIMEOUT,
                    self.airplane.set(AirplaneModeState::Disabled),
                )
                .await
                {
                    Ok(Ok(())) | Ok(Err(AirplaneEffectError::MutationUncertain)) => {
                        match timeout(RESTORE_EFFECT_TIMEOUT, self.airplane.observe()).await {
                            Ok(Ok(AirplaneModeState::Disabled)) => {
                                RotationRestoreResult::RestoredOff
                            }
                            Ok(Ok(AirplaneModeState::Enabled)) => RotationRestoreResult::Uncertain,
                            Ok(Err(_)) | Err(_) => RotationRestoreResult::Uncertain,
                        }
                    }
                    Ok(Err(AirplaneEffectError::MutationRejected)) => RotationRestoreResult::Failed,
                    Ok(Err(_)) | Err(_) => RotationRestoreResult::Failed,
                }
            }
            Ok(Err(_)) | Err(_) => RotationRestoreResult::Uncertain,
        };

        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            let current = state.machine.snapshot();
            if current.operation_id != Some(operation_id) || current.phase != RotationPhase::Failed
            {
                return;
            }
            match state.machine.record_restore(operation_id, restore) {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            }
        };
        self.publish(snapshot);
    }

    fn operation_generation_deadline(
        &self,
        operation_id: u64,
        before: bool,
    ) -> Option<(u64, Instant)> {
        let state = self.state().ok()?;
        let snapshot = state.machine.snapshot();
        if state.closed || snapshot.operation_id != Some(operation_id) || snapshot.phase.terminal()
        {
            return None;
        }
        let generation = if before {
            snapshot.before_generation?
        } else {
            snapshot.after_generation?
        };
        let deadline = state
            .deadline
            .filter(|(id, _)| *id == operation_id)
            .map(|(_, deadline)| deadline)?;
        Some((generation, deadline))
    }

    fn operation_deadline(&self, operation_id: u64) -> Option<Instant> {
        let state = self.state().ok()?;
        if state.closed || state.machine.snapshot().operation_id != Some(operation_id) {
            return None;
        }
        state
            .deadline
            .filter(|(id, _)| *id == operation_id)
            .map(|(_, deadline)| deadline)
    }

    fn credential_guard_current(&self, operation_id: u64) -> bool {
        let Ok(state) = self.state.lock() else {
            return false;
        };
        credential_guard_matches(&self.proxy, &state, operation_id)
    }

    fn spawn_owned<F>(self: &Arc<Self>, future: F) -> Result<(), RuntimeExecutionError>
    where
        F: Future<Output = ()> + Send + 'static,
    {
        let mut state = self
            .state
            .lock()
            .map_err(|_| RuntimeExecutionError::StateUnavailable)?;
        if state.closed {
            return Err(RuntimeExecutionError::StateUnavailable);
        }
        let task = self.executor.spawn(future)?;
        state.tasks.push(task);
        Ok(())
    }

    fn publish(&self, snapshot: RotationSnapshot) {
        let observer = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.observer.clone());
        notify(observer.map(|observer| (observer, snapshot)));
    }

    fn state(&self) -> Result<MutexGuard<'_, RotationRuntimeState>, ()> {
        self.state.lock().map_err(|_| ())
    }

    fn state_mut(&self) -> Result<MutexGuard<'_, RotationRuntimeState>, ()> {
        self.state()
    }
}

fn admitted_generation(admission: CellularAdmissionSnapshot) -> Option<u64> {
    (admission.state() == CellularAdmissionState::Admitted)
        .then_some(admission.last_sequence())
        .flatten()
        .map(|sequence| sequence.raw())
}

fn operation_current(state: &RotationRuntimeState, operation_id: u64) -> bool {
    !state.closed
        && state.machine.snapshot().operation_id == Some(operation_id)
        && !state.machine.snapshot().phase.terminal()
}

fn credential_guard_matches(
    proxy: &ProxyRuntimeCoordinator,
    state: &RotationRuntimeState,
    operation_id: u64,
) -> bool {
    state.machine.snapshot().operation_id == Some(operation_id)
        && state
            .credential_guard
            .as_ref()
            .is_some_and(|guard| proxy.credential_guard_matches(guard))
}

fn remaining(deadline: Instant) -> Duration {
    deadline
        .saturating_duration_since(Instant::now())
        .max(Duration::from_millis(1))
}

fn map_start_error(error: RotationStartError) -> RotationRuntimeStartError {
    match error {
        RotationStartError::AlreadyInProgress => RotationRuntimeStartError::AlreadyInProgress,
        RotationStartError::InvalidGeneration | RotationStartError::OperationIdExhausted => {
            RotationRuntimeStartError::StateUnavailable
        }
    }
}

fn notify(notification: Option<(RotationObserver, RotationSnapshot)>) {
    if let Some((observer, snapshot)) = notification {
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| observer(snapshot)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normal_path_has_no_arbitrary_dwell_constant() {
        assert!(ROTATION_SAFETY_DEADLINE >= PUBLIC_IP_EFFECT_TIMEOUT);
        assert!(RESTORE_EFFECT_TIMEOUT <= ROTATION_SAFETY_DEADLINE);
    }
}
