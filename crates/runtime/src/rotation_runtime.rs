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

/// One narrow platform effect used only after Rust has confirmed airplane OFF and entered
/// Cellular recovery. The implementation may re-arm Android's existing CELLULAR+INTERNET
/// request, but owns no retry/timing/currentness semantics.
pub trait CellularRequestRearmEffect: Send + Sync + 'static {
    fn rearm_cellular_request(&self) -> bool;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum RotationAction {
    BeforeIp,
    EnableAirplane,
    DisableAirplane,
    AfterIp,
    RestoreOff,
}

/// Read-only monotonic timing evidence for the single current/recent Rotation operation.
///
/// These values are observations only. They never drive state transitions, retries or deadlines.
/// Every phase timestamp is elapsed milliseconds from the successful prepare origin.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct RotationRuntimeTimingSnapshot {
    pub operation_id: Option<u64>,
    pub operation_age_ms: Option<u64>,
    pub activated_ms: Option<u64>,
    pub pre_rotation_probe_started_ms: Option<u64>,
    pub pre_rotation_probe_completed_ms: Option<u64>,
    pub airplane_enable_started_ms: Option<u64>,
    pub airplane_enable_effect_completed_ms: Option<u64>,
    pub airplane_on_observed_ms: Option<u64>,
    pub cellular_loss_observed_ms: Option<u64>,
    pub radio_power_off_observed_ms: Option<u64>,
    pub airplane_disable_started_ms: Option<u64>,
    pub airplane_disable_effect_completed_ms: Option<u64>,
    pub airplane_off_observed_ms: Option<u64>,
    pub cellular_request_rearm_started_ms: Option<u64>,
    pub cellular_request_rearm_completed_ms: Option<u64>,
    pub first_platform_cellular_observation_ms: Option<u64>,
    pub platform_cellular_observations_after_rearm: u64,
    pub fresh_cellular_observed_ms: Option<u64>,
    pub fresh_cellular_generation: Option<u64>,
    pub root_authorized_ms: Option<u64>,
    pub root_authorized_generation: Option<u64>,
    pub post_rotation_probe_started_ms: Option<u64>,
    pub post_rotation_probe_completed_ms: Option<u64>,
    pub terminal_ms: Option<u64>,
    pub restore_completed_ms: Option<u64>,
}

struct RotationRuntimeTiming {
    origin: Instant,
    snapshot: RotationRuntimeTimingSnapshot,
}

impl RotationRuntimeTiming {
    fn new(operation_id: u64) -> Self {
        Self {
            origin: Instant::now(),
            snapshot: RotationRuntimeTimingSnapshot {
                operation_id: Some(operation_id),
                ..RotationRuntimeTimingSnapshot::default()
            },
        }
    }

    fn snapshot_at(&self, now: Instant) -> RotationRuntimeTimingSnapshot {
        let mut snapshot = self.snapshot;
        snapshot.operation_age_ms = Some(elapsed_ms_since(now, self.origin));
        snapshot
    }

    fn mark<F>(&mut self, operation_id: u64, mark: F) -> bool
    where
        F: FnOnce(&mut RotationRuntimeTimingSnapshot, u64),
    {
        if self.snapshot.operation_id != Some(operation_id) {
            return false;
        }
        let elapsed_ms = elapsed_ms_since(Instant::now(), self.origin);
        mark(&mut self.snapshot, elapsed_ms);
        true
    }
}

fn set_once(slot: &mut Option<u64>, elapsed_ms: u64) {
    if slot.is_none() {
        *slot = Some(elapsed_ms);
    }
}

struct RotationRuntimeState {
    machine: RotationStateMachine,
    timing: Option<RotationRuntimeTiming>,
    deadline: Option<(u64, Instant)>,
    credential_guard: Option<ProxyCredentialGuard>,
    cellular_request_rearm: Option<(u64, Arc<dyn CellularRequestRearmEffect>)>,
    claimed: HashSet<(u64, RotationAction)>,
    cancel: Option<Arc<Notify>>,
    tasks: Vec<JoinHandle<()>>,
    observer: Option<RotationObserver>,
    internal_observers: Vec<RotationObserver>,
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
                timing: None,
                deadline: None,
                credential_guard: None,
                cellular_request_rearm: None,
                claimed: HashSet::new(),
                cancel: None,
                tasks: Vec::new(),
                observer: None,
                internal_observers: Vec::new(),
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

    pub fn timing_snapshot(&self) -> RotationRuntimeTimingSnapshot {
        self.timing_snapshot_at(Instant::now())
    }

    pub(crate) fn timing_snapshot_at(&self, now: Instant) -> RotationRuntimeTimingSnapshot {
        self.state()
            .ok()
            .and_then(|state| state.timing.as_ref().map(|timing| timing.snapshot_at(now)))
            .unwrap_or_default()
    }

    fn mark_timing<F>(&self, operation_id: u64, mark: F)
    where
        F: FnOnce(&mut RotationRuntimeTimingSnapshot, u64),
    {
        if let Ok(mut state) = self.state.lock()
            && let Some(timing) = state.timing.as_mut()
        {
            let _ = timing.mark(operation_id, mark);
        }
    }

    pub fn active_task_count(&self) -> u32 {
        self.state()
            .map(|state| {
                state
                    .tasks
                    .iter()
                    .filter(|task| !task.is_finished())
                    .count()
                    .min(u32::MAX as usize) as u32
            })
            .unwrap_or(u32::MAX)
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

    /// Internal native composition subscribers do not displace the Android projection observer.
    pub fn add_internal_observer(&self, observer: RotationObserver) {
        let snapshot = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.internal_observers.push(Arc::clone(&observer));
            state.machine.snapshot()
        };
        notify(Some((observer, snapshot)));
    }

    pub fn start(
        self: &Arc<Self>,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
    ) -> Result<u64, RotationRuntimeStartError> {
        let operation_id = self.prepare(cellular_request_rearm)?;
        if let Err(error) = self.activate_prepared(operation_id) {
            self.fail_prepared_before_mutation(operation_id);
            return Err(error);
        }
        Ok(operation_id)
    }

    /// Reserves exactly one operation id after all PRODUCT preconditions have been validated.
    ///
    /// No timer, public-IP probe, airplane mutation or recovery task is started here. This narrow
    /// two-phase seam exists so a remote controller can durably observe ACCEPTED(operation_id)
    /// before the existing Rotation owner is allowed to begin the disruptive operation.
    pub fn prepare(
        self: &Arc<Self>,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
    ) -> Result<u64, RotationRuntimeStartError> {
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
        state.timing = Some(RotationRuntimeTiming::new(operation_id));
        state.deadline = None;
        state.credential_guard = Some(credential_guard);
        state.cellular_request_rearm = Some((operation_id, cellular_request_rearm));
        state.claimed.clear();
        state.cancel = None;
        state.tasks.retain(|task| !task.is_finished());
        Ok(operation_id)
    }

    /// Activates one exact prepared operation. The caller must have completed any external
    /// acceptance handshake before entering this method.
    pub fn activate_prepared(
        self: &Arc<Self>,
        operation_id: u64,
    ) -> Result<(), RotationRuntimeStartError> {
        let (snapshot, cancel, deadline) = {
            let mut state = self
                .state_mut()
                .map_err(|_| RotationRuntimeStartError::StateUnavailable)?;
            if state.closed
                || state.deadline.is_some()
                || state.cancel.is_some()
                || state.machine.snapshot().operation_id != Some(operation_id)
                || state.machine.snapshot().phase != RotationPhase::Preparing
            {
                return Err(RotationRuntimeStartError::StateUnavailable);
            }
            let deadline = Instant::now()
                .checked_add(ROTATION_SAFETY_DEADLINE)
                .ok_or(RotationRuntimeStartError::StateUnavailable)?;
            let cancel = Arc::new(Notify::new());
            state.deadline = Some((operation_id, deadline));
            state.cancel = Some(Arc::clone(&cancel));
            if let Some(timing) = state.timing.as_mut() {
                let _ = timing.mark(operation_id, |snapshot, elapsed_ms| {
                    set_once(&mut snapshot.activated_ms, elapsed_ms);
                });
            }
            (state.machine.snapshot(), cancel, deadline)
        };

        self.publish(snapshot);
        if let Err(error) = self.spawn_deadline(operation_id, deadline, Arc::clone(&cancel)) {
            self.fail_prepared_before_mutation(operation_id);
            return Err(error);
        }
        if let Err(error) = self.schedule_for(snapshot) {
            self.fail_prepared_before_mutation(operation_id);
            return Err(error);
        }
        Ok(())
    }

    /// Fails one reserved-but-not-yet-mutating operation. This never replays or starts a radio
    /// effect and is safe after a failed remote ACCEPTED write.
    pub fn fail_prepared_before_mutation(&self, operation_id: u64) -> bool {
        let (cancel, snapshot) = {
            let Ok(mut state) = self.state.lock() else {
                return false;
            };
            let current = state.machine.snapshot();
            if current.operation_id != Some(operation_id)
                || current.phase != RotationPhase::Preparing
            {
                return false;
            }
            let snapshot = match state
                .machine
                .fail(operation_id, RotationFailure::StateUnavailable)
            {
                Ok(snapshot) => snapshot,
                Err(_) => return false,
            };
            state.deadline = None;
            state.credential_guard = None;
            state.cellular_request_rearm = None;
            state.claimed.clear();
            (state.cancel.take(), snapshot)
        };
        if let Some(cancel) = cancel {
            cancel.notify_waiters();
        }
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.terminal_ms, elapsed_ms);
        });
        self.publish(snapshot);
        true
    }

    /// Records the Android framework observation entering Rust after the single post-airplane
    /// request rearm. This is read-only attribution evidence and does not affect admission,
    /// currentness, retries or Rotation transitions.
    pub(crate) fn observe_platform_cellular_observation(&self) {
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
        if current.phase.terminal()
            || !matches!(
                current.phase,
                RotationPhase::WaitingCellularRecovery | RotationPhase::WaitingRootPolicy
            )
        {
            return;
        }
        let Some(timing) = state.timing.as_mut() else {
            return;
        };
        if timing.snapshot.cellular_request_rearm_started_ms.is_none() {
            return;
        }
        let _ = timing.mark(operation_id, |timing, elapsed_ms| {
            set_once(
                &mut timing.first_platform_cellular_observation_ms,
                elapsed_ms,
            );
            timing.platform_cellular_observations_after_rearm = timing
                .platform_cellular_observations_after_rearm
                .saturating_add(1);
        });
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
            let snapshot = match state
                .machine
                .observe_cellular(operation_id, generation, admitted)
            {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            };
            let is_fresh = current
                .before_generation
                .is_some_and(|before_generation| generation > before_generation);
            if is_fresh
                && !admitted
                && matches!(
                    current.phase,
                    RotationPhase::AirplaneEnabling | RotationPhase::WaitingRadioDown
                )
                && let Some(timing) = state.timing.as_mut()
            {
                let _ = timing.mark(operation_id, |timing, elapsed_ms| {
                    set_once(&mut timing.cellular_loss_observed_ms, elapsed_ms);
                });
            }
            if is_fresh
                && admitted
                && matches!(
                    current.phase,
                    RotationPhase::AirplaneDisabling
                        | RotationPhase::WaitingCellularRecovery
                        | RotationPhase::WaitingRootPolicy
                )
                && let Some(timing) = state.timing.as_mut()
            {
                let _ = timing.mark(operation_id, |timing, elapsed_ms| {
                    if timing
                        .fresh_cellular_generation
                        .is_none_or(|known| generation >= known)
                    {
                        timing.fresh_cellular_generation = Some(generation);
                        timing.fresh_cellular_observed_ms = Some(elapsed_ms);
                    }
                });
            }
            snapshot
        };
        self.after_transition(snapshot);
    }

    /// Accepts one positive typed Android telephony fact for the current Rotation operation.
    ///
    /// The platform boundary owns only observation. Rust remains the sole owner of whether that
    /// fact is relevant and whether it completes the radio-down transition.
    pub fn observe_radio_power_off(self: &Arc<Self>) {
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
            let phase_before = current.phase;
            let snapshot = match state.machine.observe_radio_power_off(operation_id) {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            };
            if matches!(
                phase_before,
                RotationPhase::AirplaneEnabling | RotationPhase::WaitingRadioDown
            ) && let Some(timing) = state.timing.as_mut()
            {
                let _ = timing.mark(operation_id, |timing, elapsed_ms| {
                    set_once(&mut timing.radio_power_off_observed_ms, elapsed_ms);
                });
            }
            snapshot
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
            state.cellular_request_rearm = None;
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
            let snapshot =
                match state
                    .machine
                    .observe_root_policy(operation_id, generation, authorized)
                {
                    Ok(snapshot) => snapshot,
                    Err(_) => return,
                };
            let is_fresh = current
                .before_generation
                .is_some_and(|before_generation| generation > before_generation);
            if is_fresh
                && authorized
                && matches!(
                    current.phase,
                    RotationPhase::AirplaneDisabling
                        | RotationPhase::WaitingCellularRecovery
                        | RotationPhase::WaitingRootPolicy
                )
                && let Some(timing) = state.timing.as_mut()
            {
                let _ = timing.mark(operation_id, |timing, elapsed_ms| {
                    if timing
                        .root_authorized_generation
                        .is_none_or(|known| generation >= known)
                    {
                        timing.root_authorized_generation = Some(generation);
                        timing.root_authorized_ms = Some(elapsed_ms);
                    }
                });
            }
            snapshot
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
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.pre_rotation_probe_started_ms, elapsed_ms);
        });
        let timeout_duration = remaining(deadline).min(PUBLIC_IP_EFFECT_TIMEOUT);
        let observation_result = timeout_at(
            deadline,
            self.cellular
                .observe_public_egress_ip_async(timeout_duration),
        )
        .await;
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.pre_rotation_probe_completed_ms, elapsed_ms);
        });
        let observation = match observation_result {
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
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.airplane_enable_started_ms, elapsed_ms);
        });
        let effect_result =
            timeout_at(deadline, self.airplane.set(AirplaneModeState::Enabled)).await;
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.airplane_enable_effect_completed_ms, elapsed_ms);
        });
        let outcome = match effect_result {
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
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.airplane_disable_started_ms, elapsed_ms);
        });
        let effect_result =
            timeout_at(deadline, self.airplane.set(AirplaneModeState::Disabled)).await;
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.airplane_disable_effect_completed_ms, elapsed_ms);
        });
        let outcome = match effect_result {
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
        if observed == AirplaneModeState::Disabled
            && !self.rearm_cellular_request_if_waiting(operation_id)
        {
            self.fail(operation_id, RotationFailure::FreshCellularUnavailable);
        }
    }

    fn rearm_cellular_request_if_waiting(&self, operation_id: u64) -> bool {
        let selection = {
            let Ok(state) = self.state.lock() else {
                return false;
            };
            select_cellular_request_rearm(&state, operation_id)
        };

        let effect = match selection {
            Ok(None) => return true,
            Ok(Some(effect)) => effect,
            Err(()) => return false,
        };
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.cellular_request_rearm_started_ms, elapsed_ms);
        });
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            effect.rearm_cellular_request()
        }))
        .unwrap_or(false);
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.cellular_request_rearm_completed_ms, elapsed_ms);
        });
        result
    }

    async fn run_after_ip(self: Arc<Self>, operation_id: u64) {
        let Some((after_generation, deadline)) =
            self.operation_generation_deadline(operation_id, false)
        else {
            return;
        };
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.post_rotation_probe_started_ms, elapsed_ms);
        });
        let timeout_duration = remaining(deadline).min(PUBLIC_IP_EFFECT_TIMEOUT);
        let observation_result = timeout_at(
            deadline,
            self.cellular
                .observe_public_egress_ip_async(timeout_duration),
        )
        .await;
        self.mark_timing(operation_id, |timing, elapsed_ms| {
            set_once(&mut timing.post_rotation_probe_completed_ms, elapsed_ms);
        });
        let observation = match observation_result {
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
            let phase_before = state.machine.snapshot().phase;
            let snapshot = match state
                .machine
                .observe_airplane(operation_id, observed == AirplaneModeState::Enabled)
            {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            };
            if let Some(timing) = state.timing.as_mut() {
                let _ = timing.mark(operation_id, |timing, elapsed_ms| match observed {
                    AirplaneModeState::Enabled => {
                        set_once(&mut timing.airplane_on_observed_ms, elapsed_ms);
                    }
                    AirplaneModeState::Disabled
                        if phase_before != RotationPhase::WaitingRadioDown =>
                    {
                        set_once(&mut timing.airplane_off_observed_ms, elapsed_ms);
                    }
                    AirplaneModeState::Disabled => {}
                });
            }
            snapshot
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
        if snapshot.phase.terminal() {
            if let Some(operation_id) = snapshot.operation_id {
                self.mark_timing(operation_id, |timing, elapsed_ms| {
                    set_once(&mut timing.terminal_ms, elapsed_ms);
                });
            }
            let cancel = self.state.lock().ok().and_then(|mut state| {
                state.cellular_request_rearm = None;
                state.cancel.as_ref().map(Arc::clone)
            });
            if let Some(cancel) = cancel {
                cancel.notify_waiters();
            }
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
            let snapshot = match state.machine.record_restore(operation_id, restore) {
                Ok(snapshot) => snapshot,
                Err(_) => return,
            };
            if let Some(timing) = state.timing.as_mut() {
                let _ = timing.mark(operation_id, |timing, elapsed_ms| {
                    set_once(&mut timing.restore_completed_ms, elapsed_ms);
                });
            }
            snapshot
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
        let (observer, internal) = self
            .state
            .lock()
            .map(|state| (state.observer.clone(), state.internal_observers.clone()))
            .unwrap_or((None, Vec::new()));
        notify(observer.map(|observer| (observer, snapshot)));
        for observer in internal {
            notify(Some((observer, snapshot)));
        }
    }

    fn state(&self) -> Result<MutexGuard<'_, RotationRuntimeState>, ()> {
        self.state.lock().map_err(|_| ())
    }

    fn state_mut(&self) -> Result<MutexGuard<'_, RotationRuntimeState>, ()> {
        self.state()
    }
}

fn select_cellular_request_rearm(
    state: &RotationRuntimeState,
    operation_id: u64,
) -> Result<Option<Arc<dyn CellularRequestRearmEffect>>, ()> {
    let snapshot = state.machine.snapshot();
    if state.closed
        || snapshot.operation_id != Some(operation_id)
        || snapshot.phase != RotationPhase::WaitingCellularRecovery
    {
        return Ok(None);
    }

    state
        .cellular_request_rearm
        .as_ref()
        .filter(|(id, _)| *id == operation_id)
        .map(|(_, effect)| Arc::clone(effect))
        .map(Some)
        .ok_or(())
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

fn elapsed_ms_since(now: Instant, then: Instant) -> u64 {
    u64::try_from(now.saturating_duration_since(then).as_millis()).unwrap_or(u64::MAX)
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
    use std::net::{IpAddr, Ipv4Addr};

    struct TestRearmEffect;

    impl CellularRequestRearmEffect for TestRearmEffect {
        fn rearm_cellular_request(&self) -> bool {
            true
        }
    }

    fn waiting_cellular_recovery_state() -> (RotationRuntimeState, u64) {
        let mut machine = RotationStateMachine::new();
        let operation_id = machine.start(1).expect("rotation start");
        machine
            .record_before_ip(operation_id, 1, IpAddr::V4(Ipv4Addr::new(1, 1, 1, 1)))
            .expect("before IP");
        machine
            .airplane_enable_effect_completed(operation_id, RotationMutationOutcome::Applied)
            .expect("airplane enable effect");
        machine
            .observe_airplane(operation_id, true)
            .expect("airplane ON");
        machine
            .observe_cellular(operation_id, 2, false)
            .expect("cellular loss");
        machine
            .airplane_disable_effect_completed(operation_id, RotationMutationOutcome::Applied)
            .expect("airplane disable effect");
        machine
            .observe_airplane(operation_id, false)
            .expect("airplane OFF");

        assert_eq!(
            machine.snapshot().phase,
            RotationPhase::WaitingCellularRecovery
        );

        (
            RotationRuntimeState {
                machine,
                timing: None,
                deadline: None,
                credential_guard: None,
                cellular_request_rearm: Some((operation_id, Arc::new(TestRearmEffect))),
                claimed: HashSet::new(),
                cancel: None,
                tasks: Vec::new(),
                observer: None,
                internal_observers: Vec::new(),
                closed: false,
            },
            operation_id,
        )
    }

    #[test]
    fn cellular_request_rearm_is_selected_only_for_current_recovery_operation() {
        let (mut state, operation_id) = waiting_cellular_recovery_state();

        assert!(
            select_cellular_request_rearm(&state, operation_id)
                .expect("selection")
                .is_some()
        );
        assert!(
            select_cellular_request_rearm(&state, operation_id + 1)
                .expect("stale operation must not select")
                .is_none()
        );

        state.closed = true;
        assert!(
            select_cellular_request_rearm(&state, operation_id)
                .expect("closed runtime must not select")
                .is_none()
        );
    }

    #[test]
    fn waiting_recovery_without_bound_rearm_effect_fails_selection_closed() {
        let (mut state, operation_id) = waiting_cellular_recovery_state();
        state.cellular_request_rearm = None;

        assert!(matches!(
            select_cellular_request_rearm(&state, operation_id),
            Err(())
        ));
    }

    #[test]
    fn operation_timing_is_observation_only_and_rejects_stale_operation_updates() {
        let mut timing = RotationRuntimeTiming::new(7);
        assert!(!timing.mark(8, |snapshot, elapsed_ms| {
            snapshot.pre_rotation_probe_started_ms = Some(elapsed_ms);
        }));
        assert!(timing.snapshot.pre_rotation_probe_started_ms.is_none());

        assert!(timing.mark(7, |snapshot, elapsed_ms| {
            set_once(&mut snapshot.pre_rotation_probe_started_ms, elapsed_ms);
        }));
        assert!(timing.snapshot.pre_rotation_probe_started_ms.is_some());

        let replacement = RotationRuntimeTiming::new(8);
        assert_eq!(replacement.snapshot.operation_id, Some(8));
        assert!(replacement.snapshot.pre_rotation_probe_started_ms.is_none());
    }

    #[test]
    fn normal_path_has_no_arbitrary_dwell_constant() {
        assert!(ROTATION_SAFETY_DEADLINE >= PUBLIC_IP_EFFECT_TIMEOUT);
        assert!(RESTORE_EFFECT_TIMEOUT <= ROTATION_SAFETY_DEADLINE);
    }
}
