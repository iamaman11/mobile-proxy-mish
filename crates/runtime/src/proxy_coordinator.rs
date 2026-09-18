//! Native Proxy Serving lifecycle and recovery on the shared process Tokio runtime.
//!
//! Proxy protocol/authentication stays in mish-proxy. Cellular owns outbound authority. Mesh and
//! readiness own their facts. This coordinator owns only the cross-owner use-case of one current
//! Proxy Serving generation, terminal-failure publication and bounded restart scheduling.

use crate::{
    CellularRuntimeCoordinator, MeshCompositionCoordinator, ProxyServingFailure,
    ProxyServingRuntime, ProxyServingState, ReadinessRuntimeCoordinator, RuntimeExecutor,
    proxy_recovery_delay_ms, proxy_serving_failure_recoverable,
};
use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
use std::net::{IpAddr, Ipv4Addr};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;
use tokio::task::spawn_blocking;
use tokio::time::sleep;

pub type ProxyRuntimeObserver =
    Arc<dyn Fn(ProxyRuntimePublication) + Send + Sync + 'static>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProxyRuntimePublication {
    pub state: ProxyServingState,
    pub failure: Option<ProxyServingFailure>,
    pub serving_generation: Option<u64>,
    pub credential_version: Option<u64>,
    pub recovery_pending: bool,
    pub recovery_attempts_since_success: u32,
    pub recovery_next_delay_ms: u64,
}

struct ProxyCoordinatorState {
    current: Option<Arc<ProxyServingRuntime>>,
    state: ProxyServingState,
    failure: Option<ProxyServingFailure>,
    serving_generation: Option<u64>,
    next_serving_generation: u64,
    credential_version: Option<u64>,
    credentials: Option<ProxyCredentialMaterial>,
    recovery_pending: bool,
    recovery_attempts: u32,
    recovery_epoch: u64,
    observer: Option<ProxyRuntimeObserver>,
    closed: bool,
}

pub struct ProxyRuntimeCoordinator {
    executor: Arc<RuntimeExecutor>,
    cellular: Arc<CellularRuntimeCoordinator>,
    mesh: Arc<MeshCompositionCoordinator>,
    readiness: Arc<ReadinessRuntimeCoordinator>,
    operation_timeout: Duration,
    state: Mutex<ProxyCoordinatorState>,
}

impl ProxyRuntimeCoordinator {
    pub fn new(
        executor: Arc<RuntimeExecutor>,
        cellular: Arc<CellularRuntimeCoordinator>,
        mesh: Arc<MeshCompositionCoordinator>,
        readiness: Arc<ReadinessRuntimeCoordinator>,
        operation_timeout: Duration,
    ) -> Arc<Self> {
        Arc::new(Self {
            executor,
            cellular,
            mesh,
            readiness,
            operation_timeout,
            state: Mutex::new(ProxyCoordinatorState {
                current: None,
                state: ProxyServingState::Stopped,
                failure: None,
                serving_generation: None,
                next_serving_generation: 1,
                credential_version: None,
                credentials: None,
                recovery_pending: false,
                recovery_attempts: 0,
                recovery_epoch: 0,
                observer: None,
                closed: false,
            }),
        })
    }

    pub fn set_observer(&self, observer: ProxyRuntimeObserver) {
        let publication = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observer = Some(Arc::clone(&observer));
            publication(&state)
        };
        notify(Some((observer, publication)));
    }

    pub fn snapshot(&self) -> ProxyRuntimePublication {
        self.state()
            .map(|state| publication(&state))
            .unwrap_or(ProxyRuntimePublication {
                state: ProxyServingState::Failed,
                failure: Some(ProxyServingFailure::RuntimeStateUnavailable),
                serving_generation: None,
                credential_version: None,
                recovery_pending: false,
                recovery_attempts_since_success: 0,
                recovery_next_delay_ms: proxy_recovery_delay_ms(0),
            })
    }

    pub fn active_sessions(&self) -> u32 {
        self.state()
            .ok()
            .and_then(|state| state.current.clone())
            .map(|runtime| runtime.active_sessions().min(u32::MAX as usize) as u32)
            .unwrap_or(0)
    }

    pub fn start(
        self: &Arc<Self>,
        credential_version: u64,
        username: String,
        password: String,
    ) -> ProxyRuntimePublication {
        if credential_version == 0 {
            return self.publish_start_failure(ProxyServingFailure::ProxyConfigurationRejected);
        }
        let credentials = match ProxyCredentialMaterial::new(username, password) {
            Ok(credentials) => credentials,
            Err(_) => {
                return self.publish_start_failure(
                    ProxyServingFailure::ProxyConfigurationRejected,
                );
            }
        };

        let starting = {
            let Ok(mut state) = self.state.lock() else {
                return self.unavailable_publication();
            };
            if state.closed {
                return publication(&state);
            }
            if state.current.is_some()
                && matches!(state.state, ProxyServingState::Starting | ProxyServingState::Running)
            {
                return publication(&state);
            }

            state.recovery_epoch = state.recovery_epoch.wrapping_add(1);
            state.recovery_pending = false;
            state.credentials = Some(credentials.clone());
            state.credential_version = Some(credential_version);
            state.state = ProxyServingState::Starting;
            state.failure = None;
            publication(&state)
        };
        self.notify(starting);

        match start_candidate(
            Arc::clone(&self.executor),
            Arc::clone(&self.cellular),
            credentials,
            self.operation_timeout,
        ) {
            Ok(runtime) => self.finish_started(runtime, credential_version),
            Err(failure) => self.publish_start_failure(failure),
        }
    }

    pub fn stop(self: &Arc<Self>) -> ProxyRuntimePublication {
        self.stop_internal(false)
    }

    pub fn shutdown(self: &Arc<Self>) -> ProxyRuntimePublication {
        self.stop_internal(true)
    }

    fn finish_started(
        self: &Arc<Self>,
        runtime: Arc<ProxyServingRuntime>,
        credential_version: u64,
    ) -> ProxyRuntimePublication {
        let generation = {
            let Ok(mut state) = self.state.lock() else {
                let _ = runtime.stop();
                return self.unavailable_publication();
            };
            if state.closed {
                drop(state);
                let _ = runtime.stop();
                return self.snapshot();
            }
            let generation = state.next_serving_generation;
            let Some(next) = generation.checked_add(1) else {
                drop(state);
                let _ = runtime.stop();
                return self.publish_start_failure(ProxyServingFailure::RuntimeStateUnavailable);
            };
            state.next_serving_generation = next;
            state.current = Some(Arc::clone(&runtime));
            state.serving_generation = Some(generation);
            state.credential_version = Some(credential_version);
            state.state = ProxyServingState::Starting;
            state.failure = None;
            state.recovery_pending = false;
            generation
        };

        let weak = Arc::downgrade(self);
        runtime.set_terminal_observer(Arc::new(move |failure| {
            if let Some(owner) = Weak::upgrade(&weak) {
                owner.on_terminal_failure(generation, failure);
            }
        }));

        let still_current = self
            .state()
            .is_ok_and(|state| {
                state.serving_generation == Some(generation)
                    && state.current.as_ref().is_some_and(|current| Arc::ptr_eq(current, &runtime))
                    && state.failure.is_none()
            });
        if !still_current {
            return self.snapshot();
        }

        let composition = self
            .mesh
            .install_proxy(Arc::clone(&runtime))
            .and_then(|snapshot| {
                self.readiness
                    .observe_mesh(snapshot)
                    .map_err(|_| mish_transport::MeshTransportError::StateUnavailable)
            })
            .and_then(|_| {
                let credentials = self
                    .state()
                    .ok()
                    .and_then(|state| state.credentials.clone())
                    .ok_or(mish_transport::MeshTransportError::StateUnavailable)?;
                self.readiness
                    .observe_proxy_started(
                        generation,
                        credential_version,
                        credentials.username().to_owned(),
                        credentials.password().to_owned(),
                    )
                    .map_err(|_| mish_transport::MeshTransportError::StateUnavailable)
            });

        if composition.is_err() {
            self.on_terminal_failure(generation, ProxyServingFailure::RuntimeStateUnavailable);
            return self.snapshot();
        }

        let publication = {
            let Ok(mut state) = self.state.lock() else {
                return self.unavailable_publication();
            };
            if state.serving_generation != Some(generation) || state.failure.is_some() {
                return publication(&state);
            }
            state.state = ProxyServingState::Running;
            state.failure = None;
            state.recovery_pending = false;
            state.recovery_attempts = 0;
            publication(&state)
        };
        self.notify(publication);
        publication
    }

    fn publish_start_failure(
        self: &Arc<Self>,
        failure: ProxyServingFailure,
    ) -> ProxyRuntimePublication {
        let publication = {
            let Ok(mut state) = self.state.lock() else {
                return self.unavailable_publication();
            };
            if state.closed {
                return publication(&state);
            }
            state.current = None;
            state.serving_generation = None;
            state.state = ProxyServingState::Failed;
            state.failure = Some(failure);
            schedule_recovery_state(&mut state, failure)
        };
        self.notify(publication);
        self.spawn_recovery_if_pending();
        publication
    }

    fn on_terminal_failure(
        self: &Arc<Self>,
        generation: u64,
        failure: ProxyServingFailure,
    ) {
        let (old_runtime, publication) = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed || state.serving_generation != Some(generation) {
                return;
            }
            let old_runtime = state.current.take();
            state.state = ProxyServingState::Failed;
            state.failure = Some(failure);
            let publication = schedule_recovery_state(&mut state, failure);
            (old_runtime, publication)
        };

        let _ = self.readiness.observe_proxy_stopped();
        if let Ok(snapshot) = self.mesh.clear_proxy() {
            let _ = self.readiness.observe_mesh(snapshot);
        }
        self.notify(publication);
        self.spawn_recovery(old_runtime);
    }

    fn spawn_recovery_if_pending(self: &Arc<Self>) {
        self.spawn_recovery(None);
    }

    fn spawn_recovery(self: &Arc<Self>, old_runtime: Option<Arc<ProxyServingRuntime>>) {
        let (epoch, delay) = {
            let Ok(state) = self.state.lock() else {
                return;
            };
            if state.closed || !state.recovery_pending {
                return;
            }
            (
                state.recovery_epoch,
                Duration::from_millis(proxy_recovery_delay_ms(
                    state.recovery_attempts.saturating_sub(1),
                )),
            )
        };

        let owner = Arc::clone(self);
        let _ = self.executor.spawn(async move {
            if let Some(runtime) = old_runtime {
                let _ = spawn_blocking(move || runtime.stop()).await;
            }
            sleep(delay).await;
            owner.recover(epoch).await;
        });
    }

    async fn recover(self: Arc<Self>, epoch: u64) {
        let (credential_version, credentials) = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed || !state.recovery_pending || state.recovery_epoch != epoch {
                return;
            }
            state.recovery_pending = false;
            let Some(version) = state.credential_version else {
                return;
            };
            let Some(credentials) = state.credentials.clone() else {
                return;
            };
            state.state = ProxyServingState::Starting;
            state.failure = None;
            (version, credentials)
        };
        self.notify(self.snapshot());

        let executor = Arc::clone(&self.executor);
        let cellular = Arc::clone(&self.cellular);
        let timeout = self.operation_timeout;
        let result = spawn_blocking(move || {
            start_candidate(executor, cellular, credentials, timeout)
        })
        .await;

        match result {
            Ok(Ok(runtime)) => {
                let _ = self.finish_started(runtime, credential_version);
            }
            Ok(Err(failure)) => {
                let _ = self.publish_start_failure(failure);
            }
            Err(_) => {
                let _ = self.publish_start_failure(ProxyServingFailure::ExecutorUnavailable);
            }
        }
    }

    fn stop_internal(self: &Arc<Self>, close: bool) -> ProxyRuntimePublication {
        let (runtime, publication) = {
            let Ok(mut state) = self.state.lock() else {
                return self.unavailable_publication();
            };
            state.recovery_epoch = state.recovery_epoch.wrapping_add(1);
            state.recovery_pending = false;
            let runtime = state.current.take();
            state.serving_generation = None;
            state.state = ProxyServingState::Stopped;
            state.failure = None;
            state.credentials = None;
            state.credential_version = None;
            state.recovery_attempts = 0;
            if close {
                state.closed = true;
            }
            (runtime, publication(&state))
        };

        let readiness_clean = self.readiness.observe_proxy_stopped().is_ok();
        let mesh_clean = self
            .mesh
            .clear_proxy()
            .and_then(|snapshot| {
                self.readiness
                    .observe_mesh(snapshot)
                    .map_err(|_| mish_transport::MeshTransportError::StateUnavailable)
            })
            .is_ok();
        let proxy_clean = runtime.map_or(true, |runtime| runtime.stop().is_ok());

        let publication = if readiness_clean && mesh_clean && proxy_clean {
            publication
        } else {
            let Ok(mut state) = self.state.lock() else {
                return self.unavailable_publication();
            };
            state.state = ProxyServingState::Failed;
            state.failure = Some(ProxyServingFailure::ShutdownFailed);
            publication(&state)
        };
        self.notify(publication);
        publication
    }

    fn notify(&self, publication: ProxyRuntimePublication) {
        let observer = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.observer.clone());
        notify(observer.map(|observer| (observer, publication)));
    }

    fn state(&self) -> Result<MutexGuard<'_, ProxyCoordinatorState>, ()> {
        self.state.lock().map_err(|_| ())
    }

    fn unavailable_publication(&self) -> ProxyRuntimePublication {
        ProxyRuntimePublication {
            state: ProxyServingState::Failed,
            failure: Some(ProxyServingFailure::RuntimeStateUnavailable),
            serving_generation: None,
            credential_version: None,
            recovery_pending: false,
            recovery_attempts_since_success: 0,
            recovery_next_delay_ms: proxy_recovery_delay_ms(0),
        }
    }
}

fn schedule_recovery_state(
    state: &mut ProxyCoordinatorState,
    failure: ProxyServingFailure,
) -> ProxyRuntimePublication {
    if proxy_serving_failure_recoverable(failure) && state.credentials.is_some() {
        state.recovery_pending = true;
        state.recovery_epoch = state.recovery_epoch.wrapping_add(1);
        state.recovery_attempts = state.recovery_attempts.saturating_add(1);
    } else {
        state.recovery_pending = false;
    }
    publication(state)
}

fn publication(state: &ProxyCoordinatorState) -> ProxyRuntimePublication {
    ProxyRuntimePublication {
        state: state.state,
        failure: state.failure,
        serving_generation: state.serving_generation,
        credential_version: state.credential_version,
        recovery_pending: state.recovery_pending,
        recovery_attempts_since_success: state.recovery_attempts,
        recovery_next_delay_ms: proxy_recovery_delay_ms(
            state.recovery_attempts.saturating_sub(1),
        ),
    }
}

fn start_candidate(
    executor: Arc<RuntimeExecutor>,
    cellular: Arc<CellularRuntimeCoordinator>,
    credentials: ProxyCredentialMaterial,
    operation_timeout: Duration,
) -> Result<Arc<ProxyServingRuntime>, ProxyServingFailure> {
    let plan = ProxyServingPlan::canonical(IpAddr::V4(Ipv4Addr::LOCALHOST), credentials)
        .map_err(|_| ProxyServingFailure::ProxyConfigurationRejected)?;
    let connector = cellular
        .outbound_connector(operation_timeout)
        .map_err(|_| ProxyServingFailure::CellularConnectorUnavailable)?;
    ProxyServingRuntime::start(executor, plan, connector)
        .map_err(|error| error.lifecycle_failure())
}

fn notify(notification: Option<(ProxyRuntimeObserver, ProxyRuntimePublication)>) {
    if let Some((observer, publication)) = notification {
        let _ = catch_unwind(AssertUnwindSafe(|| observer(publication)));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CellularRuntimeCoordinator;

    struct EmptyResolver;
    impl crate::CellularDnsResolver for EmptyResolver {
        fn resolve(
            &self,
            _authority: mish_cellular::CellularNetworkAuthority,
            _hostname: &str,
        ) -> Result<Vec<std::net::IpAddr>, mish_proxy::ProxyOutboundConnectError> {
            Err(mish_proxy::ProxyOutboundConnectError::Unavailable)
        }
    }

    #[test]
    fn fresh_coordinator_is_stopped_without_recovery() {
        let executor = RuntimeExecutor::new().expect("executor");
        let cellular = CellularRuntimeCoordinator::new(Arc::new(EmptyResolver));
        let mesh = MeshCompositionCoordinator::new().expect("mesh");
        let readiness =
            ReadinessRuntimeCoordinator::new(Arc::clone(&executor), Arc::clone(&mesh), 1)
                .expect("readiness");
        let proxy = ProxyRuntimeCoordinator::new(
            Arc::clone(&executor),
            cellular,
            mesh,
            readiness,
            Duration::from_secs(1),
        );
        let snapshot = proxy.snapshot();
        assert_eq!(snapshot.state, ProxyServingState::Stopped);
        assert!(!snapshot.recovery_pending);
        let _ = proxy.shutdown();
        executor.shutdown().expect("shutdown");
    }

    #[test]
    fn zero_credential_version_fails_before_network_effect() {
        let executor = RuntimeExecutor::new().expect("executor");
        let cellular = CellularRuntimeCoordinator::new(Arc::new(EmptyResolver));
        let mesh = MeshCompositionCoordinator::new().expect("mesh");
        let readiness =
            ReadinessRuntimeCoordinator::new(Arc::clone(&executor), Arc::clone(&mesh), 1)
                .expect("readiness");
        let proxy = ProxyRuntimeCoordinator::new(
            Arc::clone(&executor),
            cellular,
            mesh,
            readiness,
            Duration::from_secs(1),
        );
        let snapshot = proxy.start(0, "user".to_owned(), "password".to_owned());
        assert_eq!(
            snapshot.failure,
            Some(ProxyServingFailure::ProxyConfigurationRejected)
        );
        let _ = proxy.shutdown();
        executor.shutdown().expect("shutdown");
    }
}
