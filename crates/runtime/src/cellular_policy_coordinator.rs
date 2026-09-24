//! Rust-owned Cellular/root-policy reconciliation and recovery.
//!
//! Android supplies raw network observations and an exact-handle interface hint. This coordinator
//! owns latest-generation coalescing, quiescence, policy execution, authorization and retry state.

use crate::root_session::RootSessionManager;
use crate::{
    CellularRuntimeCoordinator, CellularRuntimeError, RootPolicyResult, RootPolicyRuntime,
    RuntimeExecutionError, RuntimeExecutor,
};
use mish_cellular::{
    CellularAdmissionSnapshot, CellularAdmissionState, NetworkHandle, NetworkObservation,
    ObservationSequence, RootPolicyNamespace,
};
use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::time::sleep;

const EFFECT_DRAIN_TIMEOUT: Duration = Duration::from_secs(15);
const RECOVERY_DELAYS_MS: [u64; 6] = [0, 1_000, 5_000, 15_000, 30_000, 60_000];

#[derive(Debug, Clone, PartialEq, Eq)]
struct ReconcileRequest {
    admission: CellularAdmissionSnapshot,
    interface_name: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularReconcileDiagnostic {
    pub requested: u64,
    pub executed: u64,
    pub coalesced: u64,
    pub pending: bool,
    pub drain_scheduled: bool,
    pub last_owner_sequence: Option<u64>,
    pub last_dequeue_wait_ms: u64,
    pub max_dequeue_wait_ms: u64,
    pub last_quiesce_wait_ms: u64,
    pub max_quiesce_wait_ms: u64,
    pub stale_after_reconcile: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RootRecoveryDiagnostic {
    pub pending: bool,
    pub attempts_since_reset: u32,
    pub next_delay_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularPolicyPublication {
    pub admission: CellularAdmissionSnapshot,
    pub result: RootPolicyResult,
}

pub type CellularPolicyObserver = Arc<dyn Fn(CellularPolicyPublication) + Send + Sync + 'static>;
pub type CellularAdmissionObserver = Arc<dyn Fn(CellularAdmissionSnapshot) + Send + Sync + 'static>;

struct CoordinatorState {
    latest: Option<ReconcileRequest>,
    latest_enqueued_at: Option<Instant>,
    drain_scheduled: bool,
    requested: u64,
    executed: u64,
    coalesced: u64,
    last_owner_sequence: Option<u64>,
    last_dequeue_wait_ms: u64,
    max_dequeue_wait_ms: u64,
    last_quiesce_wait_ms: u64,
    max_quiesce_wait_ms: u64,
    stale_after_reconcile: u64,
    interface_hints: HashMap<NetworkHandle, String>,
    recovery_pending: bool,
    recovery_attempts: u32,
    recovery_epoch: u64,
    last_policy_result: Option<RootPolicyResult>,
    last_publication: Option<CellularPolicyPublication>,
    last_admission: Option<CellularAdmissionSnapshot>,
    observer: Option<CellularPolicyObserver>,
    internal_observers: Vec<CellularPolicyObserver>,
    admission_observers: Vec<CellularAdmissionObserver>,
    closed: bool,
}

pub struct CellularPolicyCoordinator {
    executor: Arc<RuntimeExecutor>,
    cellular: Arc<CellularRuntimeCoordinator>,
    root_session: Arc<RootSessionManager>,
    root_policy: Arc<RootPolicyRuntime>,
    state: Mutex<CoordinatorState>,
}

impl CellularPolicyCoordinator {
    pub fn new(
        executor: Arc<RuntimeExecutor>,
        cellular: Arc<CellularRuntimeCoordinator>,
        product_uid: u32,
        namespace: RootPolicyNamespace,
    ) -> Result<Arc<Self>, RuntimeExecutionError> {
        let root_session = Arc::new(RootSessionManager::new());
        let root_policy = RootPolicyRuntime::new(Arc::clone(&root_session), product_uid, namespace)
            .ok_or(RuntimeExecutionError::StateUnavailable)?;
        Ok(Arc::new(Self {
            executor,
            cellular,
            root_session,
            root_policy,
            state: Mutex::new(CoordinatorState {
                latest: None,
                latest_enqueued_at: None,
                drain_scheduled: false,
                requested: 0,
                executed: 0,
                coalesced: 0,
                last_owner_sequence: None,
                last_dequeue_wait_ms: 0,
                max_dequeue_wait_ms: 0,
                last_quiesce_wait_ms: 0,
                max_quiesce_wait_ms: 0,
                stale_after_reconcile: 0,
                interface_hints: HashMap::new(),
                recovery_pending: false,
                recovery_attempts: 0,
                recovery_epoch: 0,
                last_policy_result: None,
                last_publication: None,
                last_admission: None,
                observer: None,
                internal_observers: Vec::new(),
                admission_observers: Vec::new(),
                closed: false,
            }),
        }))
    }

    pub fn cellular(&self) -> Arc<CellularRuntimeCoordinator> {
        Arc::clone(&self.cellular)
    }

    pub fn start(self: &Arc<Self>) -> Result<(), CellularRuntimeError> {
        let admission = self.cellular.admission_snapshot()?;
        self.publish_admission(admission);
        self.enqueue_owner_generation(admission)
    }

    pub fn set_observer(&self, observer: CellularPolicyObserver) {
        let publication = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observer = Some(Arc::clone(&observer));
            state.last_publication
        };
        if let Some(publication) = publication {
            notify_observer(Some((observer, publication)));
        }
    }

    /// Registers an internal runtime observer without displacing the Android projection observer.
    ///
    /// Readiness and other native composition must subscribe here rather than polling or asking
    /// Kotlin to relay already-native owner facts.
    pub fn add_internal_observer(&self, observer: CellularPolicyObserver) {
        let publication = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.internal_observers.push(Arc::clone(&observer));
            state.last_publication
        };
        if let Some(publication) = publication {
            notify_observer(Some((observer, publication)));
        }
    }

    /// Registers a synchronous raw Cellular admission/currentness observer.
    ///
    /// This negative/currentness path invalidates stale readiness immediately on owner change/loss.
    /// Root-policy authorization still comes exclusively from policy publications after reconcile.
    pub fn add_internal_admission_observer(&self, observer: CellularAdmissionObserver) {
        let admission = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.admission_observers.push(Arc::clone(&observer));
            state.last_admission
        };
        if let Some(admission) = admission {
            notify_admission_observer(Some((observer, admission)));
        }
    }

    pub fn observe_network(
        self: &Arc<Self>,
        observation: NetworkObservation,
        observed_handle: NetworkHandle,
        interface_name: Option<String>,
    ) -> Result<CellularAdmissionSnapshot, CellularRuntimeError> {
        let admission = self.cellular.observe_network(observation)?;
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| CellularRuntimeError::StateUnavailable)?;
            if let Some(interface_name) = interface_name {
                state
                    .interface_hints
                    .insert(observed_handle, interface_name);
            }
        }
        self.publish_admission(admission);
        self.enqueue_owner_generation(admission)?;
        Ok(admission)
    }

    pub fn network_lost(
        self: &Arc<Self>,
        sequence: ObservationSequence,
        network_handle: NetworkHandle,
    ) -> Result<CellularAdmissionSnapshot, CellularRuntimeError> {
        let admission = self.cellular.network_lost(sequence, network_handle)?;
        {
            let mut state = self
                .state
                .lock()
                .map_err(|_| CellularRuntimeError::StateUnavailable)?;
            state.interface_hints.remove(&network_handle);
        }
        self.publish_admission(admission);
        self.enqueue_owner_generation(admission)?;
        Ok(admission)
    }

    pub fn reconcile_diagnostic(&self) -> CellularReconcileDiagnostic {
        self.state.lock().map_or(
            CellularReconcileDiagnostic {
                requested: 0,
                executed: 0,
                coalesced: 0,
                pending: false,
                drain_scheduled: false,
                last_owner_sequence: None,
                last_dequeue_wait_ms: 0,
                max_dequeue_wait_ms: 0,
                last_quiesce_wait_ms: 0,
                max_quiesce_wait_ms: 0,
                stale_after_reconcile: 0,
            },
            |state| CellularReconcileDiagnostic {
                requested: state.requested,
                executed: state.executed,
                coalesced: state.coalesced,
                pending: state.latest.is_some(),
                drain_scheduled: state.drain_scheduled,
                last_owner_sequence: state.last_owner_sequence,
                last_dequeue_wait_ms: state.last_dequeue_wait_ms,
                max_dequeue_wait_ms: state.max_dequeue_wait_ms,
                last_quiesce_wait_ms: state.last_quiesce_wait_ms,
                max_quiesce_wait_ms: state.max_quiesce_wait_ms,
                stale_after_reconcile: state.stale_after_reconcile,
            },
        )
    }

    pub fn recovery_diagnostic(&self) -> RootRecoveryDiagnostic {
        self.state.lock().map_or(
            RootRecoveryDiagnostic {
                pending: false,
                attempts_since_reset: 0,
                next_delay_ms: RECOVERY_DELAYS_MS[0],
            },
            |state| RootRecoveryDiagnostic {
                pending: state.recovery_pending,
                attempts_since_reset: state.recovery_attempts,
                next_delay_ms: recovery_delay_ms(state.recovery_attempts),
            },
        )
    }

    pub fn last_policy_result(&self) -> Option<RootPolicyResult> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.last_policy_result)
    }

    /// Last fully published policy result bound to the exact owner admission it authorized/rejected.
    pub fn last_publication(&self) -> Option<CellularPolicyPublication> {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.last_publication)
    }

    pub(crate) fn airplane_effect(&self) -> Arc<crate::airplane_effect::AirplaneModeEffect> {
        crate::airplane_effect::AirplaneModeEffect::new(Arc::clone(&self.root_session))
    }

    /// Current persistent root-session generation, when a live shell exists.
    pub fn root_session_generation_blocking(
        &self,
        executor: &RuntimeExecutor,
    ) -> Result<Option<u64>, RuntimeExecutionError> {
        executor.block_on(self.root_session.session_generation())
    }

    pub async fn root_policy_diagnostic(&self) -> crate::RootPolicyReconcileDiagnostic {
        self.root_policy.diagnostic().await
    }

    pub fn root_policy_diagnostic_blocking(
        &self,
        executor: &RuntimeExecutor,
    ) -> Result<crate::RootPolicyReconcileDiagnostic, RuntimeExecutionError> {
        executor.block_on(self.root_policy_diagnostic())
    }

    pub fn shutdown_blocking(
        &self,
        executor: &RuntimeExecutor,
    ) -> Result<bool, RuntimeExecutionError> {
        executor.block_on(self.shutdown())
    }

    pub async fn shutdown(&self) -> bool {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
            state.latest = None;
            state.latest_enqueued_at = None;
            state.recovery_epoch = state.recovery_epoch.wrapping_add(1);
            state.recovery_pending = false;
        }

        let gate_closed = self.cellular.close_root_policy_gate().is_ok();
        let quiesced = self
            .cellular
            .await_root_policy_quiesced_async(EFFECT_DRAIN_TIMEOUT)
            .await
            .unwrap_or(false);
        let cleanup = gate_closed && quiesced && self.root_policy.cleanup_exact().await.is_ok();
        self.root_session.shutdown().await;
        cleanup
    }

    fn enqueue_owner_generation(
        self: &Arc<Self>,
        admission: CellularAdmissionSnapshot,
    ) -> Result<(), CellularRuntimeError> {
        let request = {
            let state = self
                .state
                .lock()
                .map_err(|_| CellularRuntimeError::StateUnavailable)?;
            if state.closed {
                return Err(CellularRuntimeError::StateUnavailable);
            }
            let interface_name = admission
                .admitted_network()
                .and_then(|handle| state.interface_hints.get(&handle).cloned());
            ReconcileRequest {
                admission,
                interface_name,
            }
        };
        self.offer_new_owner_request(request)
            .map_err(|_| CellularRuntimeError::StateUnavailable)
    }

    fn offer_new_owner_request(
        self: &Arc<Self>,
        request: ReconcileRequest,
    ) -> Result<(), RuntimeExecutionError> {
        let schedule = {
            let mut state = self
                .state
                .lock()
                .map_err(|_| RuntimeExecutionError::StateUnavailable)?;
            if state.closed {
                return Err(RuntimeExecutionError::StateUnavailable);
            }
            state.requested = state.requested.saturating_add(1);
            if state.latest.is_some() {
                state.coalesced = state.coalesced.saturating_add(1);
            }
            state.latest = Some(request);
            state.latest_enqueued_at = Some(Instant::now());
            state.recovery_epoch = state.recovery_epoch.wrapping_add(1);
            state.recovery_pending = false;
            state.recovery_attempts = 0;
            if state.drain_scheduled {
                false
            } else {
                state.drain_scheduled = true;
                true
            }
        };
        if schedule {
            let this = Arc::clone(self);
            self.executor.spawn(async move { this.drain().await })?;
        }
        Ok(())
    }

    async fn drain(self: Arc<Self>) {
        loop {
            let (request, enqueued_at) = {
                let Ok(mut state) = self.state.lock() else {
                    return;
                };
                if state.closed {
                    state.latest = None;
                    state.latest_enqueued_at = None;
                    state.drain_scheduled = false;
                    return;
                }
                match state.latest.take() {
                    Some(request) => {
                        let enqueued_at = state.latest_enqueued_at.take().unwrap_or_else(Instant::now);
                        (request, enqueued_at)
                    }
                    None => {
                        state.latest_enqueued_at = None;
                        state.drain_scheduled = false;
                        return;
                    }
                }
            };

            self.process_request(request.clone(), enqueued_at).await;
            if let Ok(mut state) = self.state.lock() {
                state.executed = state.executed.saturating_add(1);
            }
        }
    }

    async fn process_request(self: &Arc<Self>, request: ReconcileRequest, enqueued_at: Instant) {
        if !self.request_is_current(&request) {
            return;
        }

        let dequeue_wait_ms = duration_ms(enqueued_at.elapsed());
        let quiesce_started = Instant::now();
        let quiesced = self
            .cellular
            .await_root_policy_quiesced_async(EFFECT_DRAIN_TIMEOUT)
            .await
            .unwrap_or(false);
        let quiesce_wait_ms = duration_ms(quiesce_started.elapsed());
        if !quiesced || !self.request_is_current(&request) {
            return;
        }

        if let Ok(mut state) = self.state.lock() {
            state.last_owner_sequence = request
                .admission
                .last_sequence()
                .map(|sequence| sequence.raw());
            state.last_dequeue_wait_ms = dequeue_wait_ms;
            state.max_dequeue_wait_ms = state.max_dequeue_wait_ms.max(dequeue_wait_ms);
            state.last_quiesce_wait_ms = quiesce_wait_ms;
            state.max_quiesce_wait_ms = state.max_quiesce_wait_ms.max(quiesce_wait_ms);
        }

        let result = self
            .root_policy
            .reconcile(
                request.admission.state() == CellularAdmissionState::Admitted,
                request.interface_name.as_deref(),
            )
            .await;

        if !self.request_is_current(&request) {
            if let Ok(mut state) = self.state.lock() {
                state.stale_after_reconcile = state.stale_after_reconcile.saturating_add(1);
            }
            return;
        }

        match result {
            RootPolicyResult::Enforced => {
                let Some(sequence) = request.admission.last_sequence() else {
                    return;
                };
                let Some(handle) = request.admission.admitted_network() else {
                    return;
                };
                if self
                    .cellular
                    .authorize_root_policy(sequence, handle)
                    .unwrap_or(false)
                {
                    self.reset_recovery();
                    self.publish(request.admission, result);
                }
            }
            RootPolicyResult::FailClosed(None)
                if request.admission.state() != CellularAdmissionState::Admitted =>
            {
                self.reset_recovery();
                self.publish(request.admission, result);
            }
            retryable if retryable.retryable() => {
                self.publish(request.admission, retryable);
                self.schedule_recovery(request);
            }
            terminal => {
                self.reset_recovery();
                self.publish(request.admission, terminal);
            }
        }
    }

    fn request_is_current(&self, request: &ReconcileRequest) -> bool {
        self.cellular
            .admission_snapshot()
            .is_ok_and(|current| same_generation(request.admission, current))
    }

    fn schedule_recovery(self: &Arc<Self>, request: ReconcileRequest) {
        let scheduled = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed || state.recovery_pending {
                return;
            }
            let epoch = state.recovery_epoch;
            let delay_ms = recovery_delay_ms(state.recovery_attempts);
            state.recovery_attempts = state.recovery_attempts.saturating_add(1);
            state.recovery_pending = true;
            (epoch, delay_ms)
        };

        let this = Arc::clone(self);
        let spawn = self.executor.spawn(async move {
            if scheduled.1 != 0 {
                sleep(Duration::from_millis(scheduled.1)).await;
            } else {
                tokio::task::yield_now().await;
            }
            this.fire_recovery(scheduled.0, request);
        });
        if spawn.is_err()
            && let Ok(mut state) = self.state.lock()
        {
            state.recovery_pending = false;
        }
    }

    fn fire_recovery(self: &Arc<Self>, epoch: u64, request: ReconcileRequest) {
        let schedule_drain = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed || state.recovery_epoch != epoch || !state.recovery_pending {
                return;
            }
            state.recovery_pending = false;
            if !self.request_is_current(&request) {
                return;
            }
            if state.latest.is_some() {
                state.coalesced = state.coalesced.saturating_add(1);
            }
            state.latest = Some(request);
            state.latest_enqueued_at = Some(Instant::now());
            if state.drain_scheduled {
                false
            } else {
                state.drain_scheduled = true;
                true
            }
        };
        if schedule_drain {
            let this = Arc::clone(self);
            let _ = self.executor.spawn(async move { this.drain().await });
        }
    }

    fn publish_admission(&self, admission: CellularAdmissionSnapshot) {
        let observers = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.last_admission == Some(admission) {
                return;
            }
            state.last_admission = Some(admission);
            state.admission_observers.clone()
        };
        for observer in observers {
            notify_admission_observer(Some((observer, admission)));
        }
    }

    fn publish(&self, admission: CellularAdmissionSnapshot, result: RootPolicyResult) {
        let publication = CellularPolicyPublication { admission, result };
        let observers = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.last_policy_result = Some(result);
            state.last_publication = Some(publication);
            state
                .observer
                .iter()
                .cloned()
                .chain(state.internal_observers.iter().cloned())
                .collect::<Vec<_>>()
        };
        for observer in observers {
            notify_observer(Some((observer, publication)));
        }
    }

    fn reset_recovery(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.recovery_epoch = state.recovery_epoch.wrapping_add(1);
            state.recovery_pending = false;
            state.recovery_attempts = 0;
        }
    }
}

fn notify_observer(notification: Option<(CellularPolicyObserver, CellularPolicyPublication)>) {
    if let Some((observer, publication)) = notification {
        let _ = catch_unwind(AssertUnwindSafe(|| observer(publication)));
    }
}

fn notify_admission_observer(
    notification: Option<(CellularAdmissionObserver, CellularAdmissionSnapshot)>,
) {
    if let Some((observer, admission)) = notification {
        let _ = catch_unwind(AssertUnwindSafe(|| observer(admission)));
    }
}

fn same_generation(
    expected: CellularAdmissionSnapshot,
    current: CellularAdmissionSnapshot,
) -> bool {
    if expected.last_sequence().is_none() {
        return expected.state() == CellularAdmissionState::Unknown
            && current.state() == CellularAdmissionState::Unknown
            && current.last_sequence().is_none()
            && expected.admitted_network().is_none()
            && current.admitted_network().is_none();
    }
    expected.last_sequence() == current.last_sequence()
        && expected.state() == current.state()
        && expected.admitted_network() == current.admitted_network()
}

fn duration_ms(duration: Duration) -> u64 {
    duration.as_millis().min(u128::from(u64::MAX)) as u64
}

fn recovery_delay_ms(attempt: u32) -> u64 {
    let index = usize::try_from(attempt)
        .unwrap_or(usize::MAX)
        .min(RECOVERY_DELAYS_MS.len() - 1);
    RECOVERY_DELAYS_MS[index]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_unknown_generation_is_current_only_until_first_owner_event() {
        let expected = mish_cellular::CellularEgress::new().admission();
        assert!(same_generation(expected, expected));

        let mut owner = mish_cellular::CellularEgress::new();
        owner.observe(NetworkObservation::new(
            ObservationSequence::new(1).expect("sequence"),
            NetworkHandle::new(42).expect("network"),
            true,
            true,
            true,
            true,
        ));
        assert!(!same_generation(expected, owner.admission()));
    }

    #[test]
    fn recovery_backoff_is_immediate_once_then_bounded() {
        assert_eq!(recovery_delay_ms(0), 0);
        assert_eq!(recovery_delay_ms(1), 1_000);
        assert_eq!(recovery_delay_ms(2), 5_000);
        assert_eq!(recovery_delay_ms(3), 15_000);
        assert_eq!(recovery_delay_ms(4), 30_000);
        assert_eq!(recovery_delay_ms(5), 60_000);
        assert_eq!(recovery_delay_ms(100), 60_000);
    }
}
