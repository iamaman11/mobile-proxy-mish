//! Rust-owned Cellular/root-policy reconciliation and recovery.
//!
//! Android supplies raw network observations and an exact-handle interface hint. This coordinator
//! owns latest-generation coalescing, quiescence, policy execution, authorization and retry state.

use crate::{
    CellularRuntimeCoordinator, CellularRuntimeError, RootPolicyResult, RootPolicyRuntime,
    RuntimeExecutionError, RuntimeExecutor,
};
use crate::root_session::RootSessionManager;
use mish_cellular::{
    CellularAdmissionSnapshot, CellularAdmissionState, NetworkHandle, NetworkObservation,
    ObservationSequence, RootPolicyNamespace,
};
use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex};
use std::time::Duration;
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

pub type CellularPolicyObserver =
    Arc<dyn Fn(CellularPolicyPublication) + Send + Sync + 'static>;

struct CoordinatorState {
    latest: Option<ReconcileRequest>,
    drain_scheduled: bool,
    requested: u64,
    executed: u64,
    coalesced: u64,
    interface_hints: HashMap<NetworkHandle, String>,
    recovery_pending: bool,
    recovery_attempts: u32,
    recovery_epoch: u64,
    last_policy_result: Option<RootPolicyResult>,
    last_publication: Option<CellularPolicyPublication>,
    observer: Option<CellularPolicyObserver>,
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
    pub(crate) fn new(
        executor: Arc<RuntimeExecutor>,
        cellular: Arc<CellularRuntimeCoordinator>,
        product_uid: u32,
        namespace: RootPolicyNamespace,
    ) -> Result<Arc<Self>, RuntimeExecutionError> {
        let root_session = Arc::new(RootSessionManager::new());
        let root_policy = RootPolicyRuntime::new(
            Arc::clone(&root_session),
            product_uid,
            namespace,
        )
        .ok_or(RuntimeExecutionError::StateUnavailable)?;
        Ok(Arc::new(Self {
            executor,
            cellular,
            root_session,
            root_policy,
            state: Mutex::new(CoordinatorState {
                latest: None,
                drain_scheduled: false,
                requested: 0,
                executed: 0,
                coalesced: 0,
                interface_hints: HashMap::new(),
                recovery_pending: false,
                recovery_attempts: 0,
                recovery_epoch: 0,
                last_policy_result: None,
                last_publication: None,
                observer: None,
                closed: false,
            }),
        }))
    }

    pub fn cellular(&self) -> Arc<CellularRuntimeCoordinator> {
        Arc::clone(&self.cellular)
    }


    pub fn start(self: &Arc<Self>) -> Result<(), CellularRuntimeError> {
        let admission = self.cellular.admission_snapshot()?;
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

    pub fn observe_network(
        self: &Arc<Self>,
        observation: NetworkObservation,
        observed_handle: NetworkHandle,
        interface_name: Option<String>,
    ) -> Result<CellularAdmissionSnapshot, CellularRuntimeError> {
        let admission = self.cellular.observe_network(observation)?;
        {
            let mut state = self.state.lock().map_err(|_| CellularRuntimeError::StateUnavailable)?;
            if let Some(interface_name) = interface_name {
                state.interface_hints.insert(observed_handle, interface_name);
            }
        }
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
            let mut state = self.state.lock().map_err(|_| CellularRuntimeError::StateUnavailable)?;
            state.interface_hints.remove(&network_handle);
        }
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
            },
            |state| CellularReconcileDiagnostic {
                requested: state.requested,
                executed: state.executed,
                coalesced: state.coalesced,
                pending: state.latest.is_some(),
                drain_scheduled: state.drain_scheduled,
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
        self.state.lock().ok().and_then(|state| state.last_policy_result)
    }

    pub async fn shutdown(&self) -> bool {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
            state.latest = None;
            state.recovery_epoch = state.recovery_epoch.wrapping_add(1);
            state.recovery_pending = false;
        }
        let cleanup = self.root_policy.cleanup_exact().await.is_ok();
        self.root_session.shutdown().await;
        cleanup
    }

    fn enqueue_owner_generation(
        self: &Arc<Self>,
        admission: CellularAdmissionSnapshot,
    ) -> Result<(), CellularRuntimeError> {
        let request = {
            let mut state = self.state.lock().map_err(|_| CellularRuntimeError::StateUnavailable)?;
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
            let request = {
                let Ok(mut state) = self.state.lock() else {
                    return;
                };
                if state.closed {
                    state.latest = None;
                    state.drain_scheduled = false;
                    return;
                }
                match state.latest.take() {
                    Some(request) => request,
                    None => {
                        state.drain_scheduled = false;
                        return;
                    }
                }
            };

            self.process_request(request.clone()).await;
            if let Ok(mut state) = self.state.lock() {
                state.executed = state.executed.saturating_add(1);
            }
        }
    }

    async fn process_request(self: &Arc<Self>, request: ReconcileRequest) {
        if !self.request_is_current(&request) {
            return;
        }
        let quiesced = self
            .cellular
            .await_root_policy_quiesced_async(EFFECT_DRAIN_TIMEOUT)
            .await
            .unwrap_or(false);
        if !quiesced || !self.request_is_current(&request) {
            return;
        }

        let result = self
            .root_policy
            .reconcile(
                request.admission.state() == CellularAdmissionState::Admitted,
                request.interface_name.as_deref(),
            )
            .await;

        if !self.request_is_current(&request) {
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
        if spawn.is_err() {
            if let Ok(mut state) = self.state.lock() {
                state.recovery_pending = false;
            }
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

    fn publish(&self, admission: CellularAdmissionSnapshot, result: RootPolicyResult) {
        let publication = CellularPolicyPublication { admission, result };
        let observer = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.last_policy_result = Some(result);
            state.last_publication = Some(publication);
            state.observer.clone()
        };
        notify_observer(observer.map(|observer| (observer, publication)));
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
