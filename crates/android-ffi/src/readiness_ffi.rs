use mish_application::{EgressProbeCoordinator, EgressProbeError, ProbeTicket};
use mish_readiness::{
    CellularOwnerGeneration, CellularReadinessFact, CredentialReadinessFact, CredentialVersion,
    EgressProbeObservation, FreshnessMarker, MeshAdmissionEpoch, MeshReadinessFact,
    ProbeBinding, ProbeOutcome, ProductReadinessInput, ProxyReadinessFact,
    ProxyServingGeneration, Readiness as OwnerReadiness, RuntimeGeneration, RuntimeReadinessFact,
    project,
};
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProductReadinessState {
    Ready,
    NotReady,
    Degraded,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum EgressProbeOutcome {
    Succeeded,
    DnsFailed,
    TlsFailed,
    AuthenticationFailed,
    TransportFailed,
    Timeout,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProbeBindingView {
    pub cellular_owner_generation: u64,
    pub runtime_generation: u64,
    pub proxy_serving_generation: u64,
    pub mesh_admission_epoch: u64,
    pub credential_version: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProbeTicketView {
    pub binding: ProbeBindingView,
    pub freshness: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct EgressProbeObservationView {
    pub outcome: EgressProbeOutcome,
    pub binding: ProbeBindingView,
    pub freshness: u64,
}

/// Flattened adapter facts. Presence and generation identity remain explicit; no readiness state is
/// stored in this record or in the FFI seam.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProductReadinessFactsView {
    pub cellular_owner_generation: Option<u64>,
    pub cellular_admitted: bool,
    pub root_policy_verified: bool,
    pub runtime_generation: Option<u64>,
    pub private_bridge_healthy: bool,
    pub proxy_runtime_generation: Option<u64>,
    pub proxy_serving_generation: Option<u64>,
    pub proxy_credential_version: Option<u64>,
    pub proxy_healthy: bool,
    pub credential_version: Option<u64>,
    pub credential_active: bool,
    pub mesh_runtime_generation: Option<u64>,
    pub mesh_admission_epoch: Option<u64>,
    pub mesh_admitted: bool,
    pub mesh_ingress_running: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum ReadinessBoundaryError {
    InvalidOwnerKey,
    ProbeFreshnessExhausted,
}

impl fmt::Display for ReadinessBoundaryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidOwnerKey => "readiness input contains a zero/invalid owner key",
            Self::ProbeFreshnessExhausted => "probe freshness sequence is exhausted",
        })
    }
}

impl std::error::Error for ReadinessBoundaryError {}

/// Thin boundary over the application-owned probe freshness coordinator plus the stateless
/// readiness projection. It stores no leaf facts and no READY/NOT_READY value.
#[derive(uniffi::Object)]
pub struct ProductReadinessController {
    probe: Mutex<EgressProbeCoordinator>,
}

#[uniffi::export]
impl ProductReadinessController {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            probe: Mutex::new(EgressProbeCoordinator::new()),
        })
    }

    pub fn begin_probe(
        &self,
        binding: ProbeBindingView,
    ) -> Result<ProbeTicketView, ReadinessBoundaryError> {
        let binding = map_binding_in(binding)?;
        self.probe_mut()
            .begin(binding)
            .map(map_ticket_out)
            .map_err(map_probe_error)
    }

    pub fn invalidate_probe(&self) -> Result<u64, ReadinessBoundaryError> {
        self.probe_mut()
            .invalidate()
            .map(FreshnessMarker::raw)
            .map_err(map_probe_error)
    }

    pub fn expected_freshness(&self) -> Option<u64> {
        self.probe().expected_freshness().map(FreshnessMarker::raw)
    }

    pub fn complete_probe(
        &self,
        ticket: ProbeTicketView,
        outcome: EgressProbeOutcome,
    ) -> Result<Option<EgressProbeObservationView>, ReadinessBoundaryError> {
        let ticket = map_ticket_in(ticket)?;
        Ok(self
            .probe()
            .complete(ticket, map_outcome_in(outcome))
            .map(map_observation_out))
    }

    pub fn project(
        &self,
        facts: ProductReadinessFactsView,
        probe: Option<EgressProbeObservationView>,
    ) -> Result<ProductReadinessState, ReadinessBoundaryError> {
        let expected_freshness = self.probe().expected_freshness();
        let input = map_input(facts, expected_freshness, probe)?;
        Ok(map_readiness(project(input)))
    }
}

impl ProductReadinessController {
    fn probe(&self) -> MutexGuard<'_, EgressProbeCoordinator> {
        self.probe
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn probe_mut(&self) -> MutexGuard<'_, EgressProbeCoordinator> {
        self.probe()
    }
}

fn map_input(
    facts: ProductReadinessFactsView,
    expected_freshness: Option<FreshnessMarker>,
    probe: Option<EgressProbeObservationView>,
) -> Result<ProductReadinessInput, ReadinessBoundaryError> {
    let cellular = facts
        .cellular_owner_generation
        .map(|raw| {
            Ok(CellularReadinessFact {
                owner_generation: cellular_generation(raw)?,
                admitted: facts.cellular_admitted,
                root_policy_verified: facts.root_policy_verified,
            })
        })
        .transpose()?;
    let runtime = facts
        .runtime_generation
        .map(|raw| {
            Ok(RuntimeReadinessFact {
                generation: runtime_generation(raw)?,
                private_bridge_healthy: facts.private_bridge_healthy,
            })
        })
        .transpose()?;
    let proxy = match (
        facts.proxy_runtime_generation,
        facts.proxy_credential_version,
    ) {
        (Some(runtime_raw), Some(credential_raw)) => Some(ProxyReadinessFact {
            runtime_generation: runtime_generation(runtime_raw)?,
            serving_generation: facts
                .proxy_serving_generation
                .map(proxy_generation)
                .transpose()?,
            credential_version: credential_version(credential_raw)?,
            healthy: facts.proxy_healthy,
        }),
        (None, None) => None,
        _ => return Err(ReadinessBoundaryError::InvalidOwnerKey),
    };
    let credential = facts
        .credential_version
        .map(|raw| {
            Ok(CredentialReadinessFact {
                version: credential_version(raw)?,
                active: facts.credential_active,
            })
        })
        .transpose()?;
    let mesh = facts
        .mesh_runtime_generation
        .map(|raw| {
            Ok(MeshReadinessFact {
                runtime_generation: runtime_generation(raw)?,
                admission_epoch: facts.mesh_admission_epoch.map(mesh_epoch).transpose()?,
                admitted: facts.mesh_admitted,
                ingress_running: facts.mesh_ingress_running,
            })
        })
        .transpose()?;
    Ok(ProductReadinessInput {
        cellular,
        runtime,
        proxy,
        credential,
        mesh,
        expected_freshness,
        probe: probe.map(map_observation_in).transpose()?,
    })
}

fn map_binding_in(view: ProbeBindingView) -> Result<ProbeBinding, ReadinessBoundaryError> {
    Ok(ProbeBinding {
        cellular_owner_generation: cellular_generation(view.cellular_owner_generation)?,
        runtime_generation: runtime_generation(view.runtime_generation)?,
        proxy_serving_generation: proxy_generation(view.proxy_serving_generation)?,
        mesh_admission_epoch: mesh_epoch(view.mesh_admission_epoch)?,
        credential_version: credential_version(view.credential_version)?,
    })
}

fn map_binding_out(binding: ProbeBinding) -> ProbeBindingView {
    ProbeBindingView {
        cellular_owner_generation: binding.cellular_owner_generation.raw(),
        runtime_generation: binding.runtime_generation.raw(),
        proxy_serving_generation: binding.proxy_serving_generation.raw(),
        mesh_admission_epoch: binding.mesh_admission_epoch.raw(),
        credential_version: binding.credential_version.raw(),
    }
}

fn map_ticket_in(view: ProbeTicketView) -> Result<ProbeTicket, ReadinessBoundaryError> {
    let binding = map_binding_in(view.binding)?;
    let freshness = freshness(view.freshness)?;
    Ok(ProbeTicket::from_parts(binding, freshness))
}

fn map_ticket_out(ticket: ProbeTicket) -> ProbeTicketView {
    ProbeTicketView {
        binding: map_binding_out(ticket.binding()),
        freshness: ticket.freshness().raw(),
    }
}

fn map_observation_in(
    view: EgressProbeObservationView,
) -> Result<EgressProbeObservation, ReadinessBoundaryError> {
    Ok(EgressProbeObservation {
        outcome: map_outcome_in(view.outcome),
        binding: map_binding_in(view.binding)?,
        freshness: freshness(view.freshness)?,
    })
}

fn map_observation_out(observation: EgressProbeObservation) -> EgressProbeObservationView {
    EgressProbeObservationView {
        outcome: map_outcome_out(observation.outcome),
        binding: map_binding_out(observation.binding),
        freshness: observation.freshness.raw(),
    }
}

fn map_outcome_in(outcome: EgressProbeOutcome) -> ProbeOutcome {
    match outcome {
        EgressProbeOutcome::Succeeded => ProbeOutcome::Succeeded,
        EgressProbeOutcome::DnsFailed => ProbeOutcome::DnsFailed,
        EgressProbeOutcome::TlsFailed => ProbeOutcome::TlsFailed,
        EgressProbeOutcome::AuthenticationFailed => ProbeOutcome::AuthenticationFailed,
        EgressProbeOutcome::TransportFailed => ProbeOutcome::TransportFailed,
        EgressProbeOutcome::Timeout => ProbeOutcome::Timeout,
    }
}

fn map_outcome_out(outcome: ProbeOutcome) -> EgressProbeOutcome {
    match outcome {
        ProbeOutcome::Succeeded => EgressProbeOutcome::Succeeded,
        ProbeOutcome::DnsFailed => EgressProbeOutcome::DnsFailed,
        ProbeOutcome::TlsFailed => EgressProbeOutcome::TlsFailed,
        ProbeOutcome::AuthenticationFailed => EgressProbeOutcome::AuthenticationFailed,
        ProbeOutcome::TransportFailed => EgressProbeOutcome::TransportFailed,
        ProbeOutcome::Timeout => EgressProbeOutcome::Timeout,
    }
}

fn map_readiness(readiness: OwnerReadiness) -> ProductReadinessState {
    match readiness {
        OwnerReadiness::Ready => ProductReadinessState::Ready,
        OwnerReadiness::NotReady => ProductReadinessState::NotReady,
        OwnerReadiness::Degraded => ProductReadinessState::Degraded,
        OwnerReadiness::Unknown => ProductReadinessState::Unknown,
    }
}

fn cellular_generation(raw: u64) -> Result<CellularOwnerGeneration, ReadinessBoundaryError> {
    CellularOwnerGeneration::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn runtime_generation(raw: u64) -> Result<RuntimeGeneration, ReadinessBoundaryError> {
    RuntimeGeneration::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn proxy_generation(raw: u64) -> Result<ProxyServingGeneration, ReadinessBoundaryError> {
    ProxyServingGeneration::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn mesh_epoch(raw: u64) -> Result<MeshAdmissionEpoch, ReadinessBoundaryError> {
    MeshAdmissionEpoch::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn credential_version(raw: u64) -> Result<CredentialVersion, ReadinessBoundaryError> {
    CredentialVersion::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn freshness(raw: u64) -> Result<FreshnessMarker, ReadinessBoundaryError> {
    FreshnessMarker::new(raw).ok_or(ReadinessBoundaryError::InvalidOwnerKey)
}

fn map_probe_error(error: EgressProbeError) -> ReadinessBoundaryError {
    match error {
        EgressProbeError::FreshnessExhausted => ReadinessBoundaryError::ProbeFreshnessExhausted,
        EgressProbeError::ZeroBudget | EgressProbeError::DeadlineOverflow => {
            ReadinessBoundaryError::InvalidOwnerKey
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ready_facts() -> ProductReadinessFactsView {
        ProductReadinessFactsView {
            cellular_owner_generation: Some(11),
            cellular_admitted: true,
            root_policy_verified: true,
            runtime_generation: Some(21),
            private_bridge_healthy: true,
            proxy_runtime_generation: Some(21),
            proxy_serving_generation: Some(21),
            proxy_credential_version: Some(51),
            proxy_healthy: true,
            credential_version: Some(51),
            credential_active: true,
            mesh_runtime_generation: Some(21),
            mesh_admission_epoch: Some(41),
            mesh_admitted: true,
            mesh_ingress_running: true,
        }
    }

    fn binding() -> ProbeBindingView {
        ProbeBindingView {
            cellular_owner_generation: 11,
            runtime_generation: 21,
            proxy_serving_generation: 21,
            mesh_admission_epoch: 41,
            credential_version: 51,
        }
    }

    #[test]
    fn boundary_never_projects_ready_before_current_probe_completion() {
        let controller = ProductReadinessController::new();
        let ticket = controller.begin_probe(binding()).expect("ticket");
        assert_eq!(
            controller.project(ready_facts(), None).expect("projection"),
            ProductReadinessState::Unknown
        );
        let observation = controller
            .complete_probe(ticket, EgressProbeOutcome::Succeeded)
            .expect("complete")
            .expect("current observation");
        assert_eq!(
            controller
                .project(ready_facts(), Some(observation))
                .expect("projection"),
            ProductReadinessState::Ready
        );
    }

    #[test]
    fn invalidation_rejects_late_success() {
        let controller = ProductReadinessController::new();
        let ticket = controller.begin_probe(binding()).expect("ticket");
        controller.invalidate_probe().expect("invalidate");
        assert_eq!(
            controller
                .complete_probe(ticket, EgressProbeOutcome::Succeeded)
                .expect("complete"),
            None
        );
    }

    #[test]
    fn explicit_mesh_loss_is_not_ready_without_epoch() {
        let controller = ProductReadinessController::new();
        let mut facts = ready_facts();
        facts.mesh_admitted = false;
        facts.mesh_ingress_running = false;
        facts.mesh_admission_epoch = None;
        assert_eq!(
            controller.project(facts, None).expect("projection"),
            ProductReadinessState::NotReady
        );
    }
}
