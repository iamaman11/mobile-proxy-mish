//! Process-generation readiness orchestration on the shared Tokio runtime.
//!
//! Leaf facts remain owned by Cellular, Proxy, Credentials and Mesh. This coordinator owns only
//! the cross-owner readiness use-case: exact binding formation, probe freshness, async execution,
//! refresh scheduling, stale completion rejection and publication into Mesh composition.

use crate::readiness_network::{ReadinessNetworkError, execute_readiness_probe_async};
use crate::{
    CellularPolicyPublication, MeshCompositionCoordinator, RootPolicyResult, RuntimeExecutionError,
    RuntimeExecutor,
};
use mish_application::{
    DEFAULT_EGRESS_PROBE_BUDGET, DEFAULT_EGRESS_PROBE_REFRESH_DELAY, EgressProbeCoordinator,
    ProbeTicket,
};
use mish_cellular::{CellularAdmissionSnapshot, CellularAdmissionState};
use mish_readiness::{
    CellularOwnerGeneration, CellularReadinessFact, CredentialReadinessFact, CredentialVersion,
    EgressProbeObservation, FreshnessMarker, MeshAdmissionEpoch, MeshReadinessFact, ProbeBinding,
    ProbeEligibility, ProductReadinessInput, ProxyReadinessFact, ProxyServingGeneration, Readiness,
    RuntimeGeneration, RuntimeReadinessFact, probe_eligibility, project,
};
use mish_transport::{MeshAdmissionState, MeshTransportSnapshot};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;
use tokio::time::{Instant, sleep};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadinessRuntimeError {
    InvalidRuntimeGeneration,
    InvalidOwnerKey,
    StateUnavailable,
    ExecutorUnavailable,
}

pub type ReadinessObserver = Arc<dyn Fn(Readiness) + Send + Sync + 'static>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ReadinessDiagnosticSnapshot {
    pub state: Readiness,
    pub root_policy_verified: bool,
    pub proxy_healthy: bool,
    pub credential_active: bool,
    pub mesh_admitted: bool,
    pub binding_eligible: bool,
    pub binding: Option<ProbeBinding>,
    pub expected_freshness: Option<FreshnessMarker>,
    pub observed_freshness: Option<FreshnessMarker>,
    pub probe_in_flight: bool,
    pub refresh_pending: bool,
}

#[derive(Clone, PartialEq, Eq)]
struct ProbeCredentials {
    version: CredentialVersion,
    username: String,
    password: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct StructuralFacts {
    cellular: Option<CellularReadinessFact>,
    runtime: RuntimeReadinessFact,
    proxy: Option<ProxyReadinessFact>,
    credential: Option<CredentialReadinessFact>,
    mesh: Option<MeshReadinessFact>,
}

struct ReadinessRuntimeState {
    facts: StructuralFacts,
    probe: EgressProbeCoordinator,
    observation: Option<EgressProbeObservation>,
    projected: Readiness,
    probe_in_flight: bool,
    refresh_epoch: u64,
    refresh_pending: bool,
    credentials: Option<ProbeCredentials>,
    observer: Option<ReadinessObserver>,
    closed: bool,
}

pub struct ReadinessRuntimeCoordinator {
    executor: Arc<RuntimeExecutor>,
    mesh: Arc<MeshCompositionCoordinator>,
    state: Mutex<ReadinessRuntimeState>,
}

impl ReadinessRuntimeCoordinator {
    pub fn new(
        executor: Arc<RuntimeExecutor>,
        mesh: Arc<MeshCompositionCoordinator>,
        runtime_generation: u64,
    ) -> Result<Arc<Self>, ReadinessRuntimeError> {
        let generation = RuntimeGeneration::new(runtime_generation)
            .ok_or(ReadinessRuntimeError::InvalidRuntimeGeneration)?;
        let runtime = RuntimeReadinessFact { generation };
        let facts = StructuralFacts {
            cellular: None,
            runtime,
            proxy: None,
            credential: None,
            mesh: None,
        };
        let probe = EgressProbeCoordinator::new();
        let projected = project(input_for(facts, &probe, None));

        Ok(Arc::new(Self {
            executor,
            mesh,
            state: Mutex::new(ReadinessRuntimeState {
                facts,
                probe,
                observation: None,
                projected,
                probe_in_flight: false,
                refresh_epoch: 0,
                refresh_pending: false,
                credentials: None,
                observer: None,
                closed: false,
            }),
        }))
    }

    pub fn snapshot(&self) -> Readiness {
        self.state()
            .map_or(Readiness::Unknown, |state| state.projected)
    }

    pub fn set_observer(&self, observer: ReadinessObserver) {
        let current = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            state.observer = Some(Arc::clone(&observer));
            state.projected
        };
        notify_readiness(Some((observer, current)));
    }

    pub fn diagnostic_snapshot(&self) -> ReadinessDiagnosticSnapshot {
        self.state().map_or(
            ReadinessDiagnosticSnapshot {
                state: Readiness::Unknown,
                root_policy_verified: false,
                proxy_healthy: false,
                credential_active: false,
                mesh_admitted: false,
                binding_eligible: false,
                binding: None,
                expected_freshness: None,
                observed_freshness: None,
                probe_in_flight: false,
                refresh_pending: false,
            },
            |state| {
                let input = input_for(state.facts, &state.probe, state.observation);
                let binding = match probe_eligibility(input) {
                    ProbeEligibility::Eligible(binding) => Some(binding),
                    ProbeEligibility::NotReady | ProbeEligibility::Unknown => None,
                };
                ReadinessDiagnosticSnapshot {
                    state: state.projected,
                    root_policy_verified: state
                        .facts
                        .cellular
                        .is_some_and(|cellular| cellular.root_policy_verified),
                    proxy_healthy: state.facts.proxy.is_some_and(|proxy| proxy.healthy),
                    credential_active: state
                        .facts
                        .credential
                        .is_some_and(|credential| credential.active),
                    mesh_admitted: state.facts.mesh.is_some_and(|mesh| mesh.admitted),
                    binding_eligible: binding.is_some(),
                    binding,
                    expected_freshness: state.probe.expected_freshness(),
                    observed_freshness: state.observation.map(|observation| observation.freshness),
                    probe_in_flight: state.probe_in_flight,
                    refresh_pending: state.refresh_pending,
                }
            },
        )
    }

    pub fn observe_cellular_admission(
        self: &Arc<Self>,
        admission: CellularAdmissionSnapshot,
    ) -> Result<(), ReadinessRuntimeError> {
        let fact = cellular_fact(admission, false)?;
        self.update_structural(|state| state.facts.cellular = fact)
    }

    pub fn observe_cellular(
        self: &Arc<Self>,
        publication: CellularPolicyPublication,
    ) -> Result<(), ReadinessRuntimeError> {
        let fact = cellular_fact(
            publication.admission,
            matches!(publication.result, RootPolicyResult::Enforced),
        )?;
        self.update_structural(|state| state.facts.cellular = fact)
    }

    pub fn observe_mesh(
        self: &Arc<Self>,
        snapshot: MeshTransportSnapshot,
    ) -> Result<(), ReadinessRuntimeError> {
        let runtime_generation = self.runtime_generation()?;
        let admission = snapshot.admission();
        let epoch = admission
            .admission_epoch()
            .map(|raw| MeshAdmissionEpoch::new(raw).ok_or(ReadinessRuntimeError::InvalidOwnerKey))
            .transpose()?;
        let fact = MeshReadinessFact {
            runtime_generation,
            admission_epoch: epoch,
            admitted: admission.state() == MeshAdmissionState::Admitted,
            // Public ingress is an effect of READY, never an input to READY eligibility.
            ingress_running: false,
        };
        self.update_structural(|state| state.facts.mesh = Some(fact))
    }

    pub fn observe_proxy_started(
        self: &Arc<Self>,
        serving_generation: u64,
        credential_version: u64,
        username: String,
        password: String,
    ) -> Result<(), ReadinessRuntimeError> {
        let version = CredentialVersion::new(credential_version)
            .ok_or(ReadinessRuntimeError::InvalidOwnerKey)?;
        let runtime_generation = self.runtime_generation()?;
        let serving_generation = ProxyServingGeneration::new(serving_generation)
            .ok_or(ReadinessRuntimeError::InvalidOwnerKey)?;
        self.update_structural(|state| {
            state.facts.proxy = Some(ProxyReadinessFact {
                runtime_generation,
                serving_generation: Some(serving_generation),
                credential_version: Some(version),
                healthy: true,
            });
            state.facts.credential = Some(CredentialReadinessFact {
                version,
                active: true,
            });
            state.credentials = Some(ProbeCredentials {
                version,
                username,
                password,
            });
        })
    }

    pub fn observe_proxy_stopped(self: &Arc<Self>) -> Result<(), ReadinessRuntimeError> {
        self.update_structural(|state| {
            if let Some(proxy) = state.facts.proxy.as_mut() {
                proxy.healthy = false;
                proxy.serving_generation = None;
                proxy.credential_version = None;
            }
            state.credentials = None;
        })
    }

    pub fn observe_credential(
        self: &Arc<Self>,
        version: Option<u64>,
        active: bool,
    ) -> Result<(), ReadinessRuntimeError> {
        let credential = version
            .map(|raw| {
                CredentialVersion::new(raw)
                    .map(|version| CredentialReadinessFact { version, active })
                    .ok_or(ReadinessRuntimeError::InvalidOwnerKey)
            })
            .transpose()?;
        self.update_structural(|state| {
            state.facts.credential = credential;
            if !active {
                state.credentials = None;
            }
        })
    }

    pub fn shutdown(&self) {
        let readiness = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed {
                return;
            }
            state.closed = true;
            state.refresh_epoch = state.refresh_epoch.wrapping_add(1);
            state.refresh_pending = false;
            state.probe_in_flight = false;
            state.credentials = None;
            let _ = state.probe.invalidate();
            state.observation = None;
            state.projected = Readiness::Unknown;
            state.projected
        };
        let _ = self.mesh.set_readiness_ready(readiness == Readiness::Ready);
    }

    fn update_structural(
        self: &Arc<Self>,
        update: impl FnOnce(&mut ReadinessRuntimeState),
    ) -> Result<(), ReadinessRuntimeError> {
        let (readiness, ticket) = {
            let mut state = self.state_mut()?;
            if state.closed {
                return Err(ReadinessRuntimeError::StateUnavailable);
            }
            let before = state.facts;
            update(&mut state);
            if state.facts == before {
                return Ok(());
            }

            state.refresh_epoch = state.refresh_epoch.wrapping_add(1);
            state.refresh_pending = false;
            state.probe_in_flight = false;
            state
                .probe
                .invalidate()
                .map_err(|_| ReadinessRuntimeError::StateUnavailable)?;
            state.observation = None;

            let input = input_for(state.facts, &state.probe, None);
            let eligibility = probe_eligibility(input);
            state.projected = project(input);

            let ticket = match eligibility {
                ProbeEligibility::Eligible(binding) => {
                    let credentials_current =
                        state.credentials.as_ref().is_some_and(|credentials| {
                            credentials.version == binding.credential_version
                        });
                    if credentials_current {
                        let ticket = state
                            .probe
                            .begin(binding)
                            .map_err(|_| ReadinessRuntimeError::StateUnavailable)?;
                        state.probe_in_flight = true;
                        Some(ticket)
                    } else {
                        None
                    }
                }
                ProbeEligibility::NotReady | ProbeEligibility::Unknown => None,
            };
            (state.projected, ticket)
        };

        self.publish_readiness(readiness);
        if let Some(ticket) = ticket
            && let Err(error) = self.spawn_probe(ticket)
        {
            Arc::clone(self).complete_probe(
                ticket,
                mish_readiness::ProbeOutcome::TransportFailed,
                Duration::ZERO,
            );
            return Err(error);
        }
        Ok(())
    }

    fn spawn_probe(self: &Arc<Self>, ticket: ProbeTicket) -> Result<(), ReadinessRuntimeError> {
        let credentials = {
            let state = self.state()?;
            state
                .credentials
                .as_ref()
                .filter(|credentials| credentials.version == ticket.binding().credential_version)
                .cloned()
                .ok_or(ReadinessRuntimeError::StateUnavailable)?
        };
        let this = Arc::clone(self);
        self.executor
            .spawn(async move {
                let started = Instant::now();
                let outcome =
                    execute_readiness_probe_async(credentials.username, credentials.password)
                        .await
                        .unwrap_or_else(map_network_error);
                let elapsed = started.elapsed();
                this.complete_probe(ticket, outcome, elapsed);
            })
            .map(|_| ())
            .map_err(map_execution_error)
    }

    fn complete_probe(
        self: Arc<Self>,
        ticket: ProbeTicket,
        outcome: mish_readiness::ProbeOutcome,
        elapsed: Duration,
    ) {
        let (readiness, refresh) = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed {
                return;
            }
            let Some(observation) =
                state
                    .probe
                    .complete_bounded(ticket, outcome, elapsed, DEFAULT_EGRESS_PROBE_BUDGET)
            else {
                return;
            };
            state.probe_in_flight = false;
            state.observation = Some(observation);
            let input = input_for(state.facts, &state.probe, state.observation);
            state.projected = project(input);
            let binding_current = matches!(
                probe_eligibility(input),
                ProbeEligibility::Eligible(binding) if binding == observation.binding
            );
            let refresh = if binding_current {
                state.refresh_epoch = state.refresh_epoch.wrapping_add(1);
                state.refresh_pending = true;
                Some((state.refresh_epoch, observation.binding))
            } else {
                state.refresh_pending = false;
                None
            };
            (state.projected, refresh)
        };

        self.publish_readiness(readiness);
        if let Some((epoch, binding)) = refresh {
            self.spawn_refresh(epoch, binding);
        }
    }

    fn spawn_refresh(self: &Arc<Self>, epoch: u64, binding: ProbeBinding) {
        let this = Arc::clone(self);
        if self
            .executor
            .spawn(async move {
                sleep(DEFAULT_EGRESS_PROBE_REFRESH_DELAY).await;
                this.fire_refresh(epoch, binding);
            })
            .is_err()
            && let Ok(mut state) = self.state.lock()
            && state.refresh_epoch == epoch
        {
            state.refresh_pending = false;
        }
    }

    fn fire_refresh(self: Arc<Self>, epoch: u64, expected: ProbeBinding) {
        let ticket = {
            let Ok(mut state) = self.state.lock() else {
                return;
            };
            if state.closed || !state.refresh_pending || state.refresh_epoch != epoch {
                return;
            }
            let input = input_for(state.facts, &state.probe, state.observation);
            let current = match probe_eligibility(input) {
                ProbeEligibility::Eligible(binding) => binding,
                ProbeEligibility::NotReady | ProbeEligibility::Unknown => {
                    state.refresh_pending = false;
                    return;
                }
            };
            if current != expected {
                state.refresh_pending = false;
                return;
            }
            state.refresh_pending = false;
            let Ok(ticket) = state.probe.begin(current) else {
                return;
            };
            state.probe_in_flight = true;
            ticket
        };

        // Stale-while-revalidate: do not republish UNKNOWN when issuing a same-binding refresh.
        let _ = self.spawn_probe(ticket);
    }

    fn publish_readiness(&self, readiness: Readiness) {
        let _ = self.mesh.set_readiness_ready(readiness == Readiness::Ready);
        let observer = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.observer.clone());
        notify_readiness(observer.map(|observer| (observer, readiness)));
    }

    fn runtime_generation(&self) -> Result<RuntimeGeneration, ReadinessRuntimeError> {
        self.state().map(|state| state.facts.runtime.generation)
    }

    fn state(&self) -> Result<MutexGuard<'_, ReadinessRuntimeState>, ReadinessRuntimeError> {
        self.state
            .lock()
            .map_err(|_| ReadinessRuntimeError::StateUnavailable)
    }

    fn state_mut(&self) -> Result<MutexGuard<'_, ReadinessRuntimeState>, ReadinessRuntimeError> {
        self.state()
    }
}

fn cellular_fact(
    admission: CellularAdmissionSnapshot,
    root_policy_verified: bool,
) -> Result<Option<CellularReadinessFact>, ReadinessRuntimeError> {
    admission
        .last_sequence()
        .map(|sequence| {
            CellularOwnerGeneration::new(sequence.raw())
                .map(|owner_generation| CellularReadinessFact {
                    owner_generation,
                    admitted: admission.state() == CellularAdmissionState::Admitted,
                    root_policy_verified: root_policy_verified
                        && admission.state() == CellularAdmissionState::Admitted,
                })
                .ok_or(ReadinessRuntimeError::InvalidOwnerKey)
        })
        .transpose()
}

fn input_for(
    facts: StructuralFacts,
    probe: &EgressProbeCoordinator,
    observation: Option<EgressProbeObservation>,
) -> ProductReadinessInput {
    ProductReadinessInput {
        cellular: facts.cellular,
        runtime: Some(facts.runtime),
        proxy: facts.proxy,
        credential: facts.credential,
        mesh: facts.mesh,
        expected_freshness: probe.expected_freshness(),
        probe: observation,
    }
}

fn notify_readiness(notification: Option<(ReadinessObserver, Readiness)>) {
    if let Some((observer, readiness)) = notification {
        let _ = catch_unwind(AssertUnwindSafe(|| observer(readiness)));
    }
}

fn map_execution_error(_error: RuntimeExecutionError) -> ReadinessRuntimeError {
    ReadinessRuntimeError::ExecutorUnavailable
}

fn map_network_error(error: ReadinessNetworkError) -> mish_readiness::ProbeOutcome {
    match error {
        ReadinessNetworkError::TlsConfiguration => mish_readiness::ProbeOutcome::TlsFailed,
        ReadinessNetworkError::InvalidTarget
        | ReadinessNetworkError::InvalidCredentials
        | ReadinessNetworkError::ExecutorUnavailable => {
            mish_readiness::ProbeOutcome::TransportFailed
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_generation_is_required() {
        let executor = RuntimeExecutor::new().expect("executor");
        let mesh = MeshCompositionCoordinator::new().expect("mesh");
        assert!(matches!(
            ReadinessRuntimeCoordinator::new(executor.clone(), mesh, 0),
            Err(ReadinessRuntimeError::InvalidRuntimeGeneration)
        ));
        executor.shutdown().expect("shutdown");
    }

    #[test]
    fn fresh_runtime_starts_unknown_and_never_opens_mesh() {
        let executor = RuntimeExecutor::new().expect("executor");
        let mesh = MeshCompositionCoordinator::new().expect("mesh");
        let readiness =
            ReadinessRuntimeCoordinator::new(executor.clone(), mesh.clone(), 1).expect("readiness");
        assert_eq!(readiness.snapshot(), Readiness::Unknown);
        assert!(!mesh.snapshot().expect("mesh snapshot").ingress_running());
        readiness.shutdown();
        executor.shutdown().expect("shutdown");
    }

    #[test]
    fn raw_cellular_owner_change_immediately_invalidates_stale_ready_projection() {
        let executor = RuntimeExecutor::new().expect("executor");
        let mesh = MeshCompositionCoordinator::new().expect("mesh");
        let readiness =
            ReadinessRuntimeCoordinator::new(executor.clone(), mesh, 1).expect("readiness");

        {
            let mut state = readiness.state_mut().expect("state");
            state.projected = Readiness::Ready;
        }

        let mut owner = mish_cellular::CellularEgress::new();
        owner.observe(mish_cellular::NetworkObservation::new(
            mish_cellular::ObservationSequence::new(1).expect("sequence"),
            mish_cellular::NetworkHandle::new(42).expect("network"),
            true,
            true,
            true,
            true,
        ));

        readiness
            .observe_cellular_admission(owner.admission())
            .expect("raw admission");
        assert_ne!(readiness.snapshot(), Readiness::Ready);
        {
            let state = readiness.state().expect("state");
            let cellular = state.facts.cellular.expect("cellular fact");
            assert!(cellular.admitted);
            assert!(!cellular.root_policy_verified);
        }
        assert!(!readiness.diagnostic_snapshot().root_policy_verified);

        readiness.shutdown();
        executor.shutdown().expect("shutdown");
    }
}
