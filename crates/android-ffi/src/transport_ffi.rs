use mish_configuration::MeshAcceptedCidr;
use mish_proxy::canonical_listeners;
use mish_transport::{
    MeshAdmissionReason as OwnerAdmissionReason, MeshAdmissionState as OwnerAdmissionState,
    MeshIngressError, MeshOwnerError, MeshPortForward, MeshTransportCoordinator,
    MeshTransportError as OwnerTransportError, MeshTransportSnapshot as OwnerTransportSnapshot,
    MeshVpnObservation as OwnerVpnObservation,
};
use std::fmt;
use std::net::Ipv4Addr;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MeshAdmissionState {
    NotAdmitted,
    Admitted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MeshAdmissionReason {
    NoObservation,
    NoAcceptedAddress,
    MultipleAcceptedAddresses,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct MeshAdmissionView {
    pub state: MeshAdmissionState,
    pub reason: Option<MeshAdmissionReason>,
    pub admission_epoch: Option<u64>,
    pub last_sequence: Option<u64>,
    pub ingress_running: bool,
    pub active_sessions: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum MeshTransportBoundaryError {
    InvalidAcceptedCidr,
    InvalidObservationSequence,
    InvalidVpnObservation,
    StaleObservation,
    AdmissionEpochExhausted,
    OwnerUnavailable,
    IngressUnavailable,
    IngressBindFailed,
    IngressShutdownFailed,
}

impl fmt::Display for MeshTransportBoundaryError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidAcceptedCidr => "accepted Mesh CIDR is invalid",
            Self::InvalidObservationSequence => "Mesh observation sequence must be non-zero",
            Self::InvalidVpnObservation => "Mesh VPN observation contains an invalid IPv4 value",
            Self::StaleObservation => "stale Mesh observation was rejected",
            Self::AdmissionEpochExhausted => "Mesh admission epoch space is exhausted",
            Self::OwnerUnavailable => "Mesh transport owner state is unavailable",
            Self::IngressUnavailable => "Mesh ingress is unavailable for the requested owner epoch",
            Self::IngressBindFailed => "exact Mesh ingress could not bind all product ports",
            Self::IngressShutdownFailed => "Mesh ingress did not shut down cleanly",
        })
    }
}

impl std::error::Error for MeshTransportBoundaryError {}

/// Typed projection of the single Proxy Serving listener contract for platform health checks.
#[uniffi::export]
pub fn proxy_listener_ports() -> Vec<u16> {
    canonical_listeners()
        .iter()
        .map(|listener| listener.port)
        .collect()
}

fn proxy_transport_mappings() -> Vec<MeshPortForward> {
    canonical_listeners()
        .iter()
        .map(|listener| MeshPortForward::same(listener.port))
        .collect()
}

/// Narrow UniFFI handle over the Transport Reachability natural-owner coordinator.
#[derive(uniffi::Object)]
pub struct MeshTransportController {
    runtime: Arc<MeshTransportCoordinator>,
}

#[uniffi::export]
impl MeshTransportController {
    /// Creates one Transport controller from the repository-owned, owner-validated desired Mesh
    /// CIDR. Android does not carry a second literal or choose a provider range at runtime.
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, MeshTransportBoundaryError> {
        let accepted = MeshAcceptedCidr::deployment()
            .map_err(|_| MeshTransportBoundaryError::InvalidAcceptedCidr)?;
        let runtime = MeshTransportCoordinator::new(accepted.network(), accepted.prefix())?;
        Ok(Arc::new(Self { runtime }))
    }

    pub fn admission_snapshot(&self) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        self.runtime
            .snapshot()
            .map(map_view)
            .map_err(map_transport_error)
    }

    /// Publishes a complete snapshot proving that no current VPN Network exists.
    pub fn observe_vpn_absent(
        &self,
        sequence: u64,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        self.runtime
            .observe_vpn(sequence, OwnerVpnObservation::Absent)
            .map(map_view)
            .map_err(map_transport_error)
    }

    /// Publishes one complete current-VPN snapshot. Android supplies only raw current VPN-local
    /// IPv4 values; CIDR filtering, 0/1/>1 acceptance, endpoint identity and epoch remain in Rust.
    pub fn observe_unique_vpn(
        &self,
        sequence: u64,
        local_ipv4: Vec<String>,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        let addresses = local_ipv4
            .into_iter()
            .map(|raw| {
                raw.parse::<Ipv4Addr>()
                    .map_err(|_| MeshTransportBoundaryError::InvalidVpnObservation)
            })
            .collect::<Result<Vec<_>, _>>()?;
        self.runtime
            .observe_vpn(
                sequence,
                OwnerVpnObservation::UniqueVpn {
                    local_ipv4: addresses,
                },
            )
            .map(map_view)
            .map_err(map_transport_error)
    }

    /// Publishes a complete snapshot proving that more than one current VPN Network exists.
    pub fn observe_vpn_ambiguous(
        &self,
        sequence: u64,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        self.runtime
            .observe_vpn(sequence, OwnerVpnObservation::AmbiguousVpn)
            .map(map_view)
            .map_err(map_transport_error)
    }

    /// Starts the exact-address ingress only for the caller's still-current admission epoch.
    /// Proxy listener ports are projected from the Proxy Serving owner at this composition seam.
    pub fn start_ingress(&self, admission_epoch: u64) -> Result<bool, MeshTransportBoundaryError> {
        let mappings = proxy_transport_mappings();
        self.runtime
            .start_ingress(admission_epoch, &mappings)
            .map_err(map_transport_error)
    }

    pub fn stop_ingress(&self) -> Result<bool, MeshTransportBoundaryError> {
        self.runtime.stop_ingress().map_err(map_transport_error)?;
        Ok(true)
    }

    pub fn ingress_healthy(&self) -> Result<bool, MeshTransportBoundaryError> {
        self.runtime.ingress_healthy().map_err(map_transport_error)
    }
}

fn map_view(snapshot: OwnerTransportSnapshot) -> MeshAdmissionView {
    let admission = snapshot.admission();
    MeshAdmissionView {
        state: match admission.state() {
            OwnerAdmissionState::NotAdmitted => MeshAdmissionState::NotAdmitted,
            OwnerAdmissionState::Admitted => MeshAdmissionState::Admitted,
        },
        reason: admission.reason().map(|reason| match reason {
            OwnerAdmissionReason::NoObservation => MeshAdmissionReason::NoObservation,
            OwnerAdmissionReason::NoAcceptedAddress => MeshAdmissionReason::NoAcceptedAddress,
            OwnerAdmissionReason::MultipleAcceptedAddresses => {
                MeshAdmissionReason::MultipleAcceptedAddresses
            }
        }),
        admission_epoch: admission.admission_epoch(),
        last_sequence: admission.last_sequence(),
        ingress_running: snapshot.ingress_running(),
        active_sessions: snapshot.active_sessions() as u64,
    }
}

fn map_transport_error(error: OwnerTransportError) -> MeshTransportBoundaryError {
    match error {
        OwnerTransportError::Owner(error) => error.into(),
        OwnerTransportError::StateUnavailable => MeshTransportBoundaryError::OwnerUnavailable,
        OwnerTransportError::IngressUnavailable => MeshTransportBoundaryError::IngressUnavailable,
        OwnerTransportError::Ingress(error) => map_ingress_error(error),
        OwnerTransportError::CleanupFailed => MeshTransportBoundaryError::IngressShutdownFailed,
    }
}

fn map_ingress_error(error: MeshIngressError) -> MeshTransportBoundaryError {
    match error {
        MeshIngressError::BindFailed => MeshTransportBoundaryError::IngressBindFailed,
        MeshIngressError::ShutdownTimedOut => MeshTransportBoundaryError::IngressShutdownFailed,
        MeshIngressError::InvalidEndpoint
        | MeshIngressError::InvalidPortMapping
        | MeshIngressError::ListenerConfigurationFailed
        | MeshIngressError::ThreadUnavailable => MeshTransportBoundaryError::IngressUnavailable,
    }
}

impl From<MeshOwnerError> for MeshTransportBoundaryError {
    fn from(error: MeshOwnerError) -> Self {
        match error {
            MeshOwnerError::InvalidAcceptedCidr => Self::InvalidAcceptedCidr,
            MeshOwnerError::InvalidObservationSequence => Self::InvalidObservationSequence,
            MeshOwnerError::StaleObservation => Self::StaleObservation,
            MeshOwnerError::AdmissionEpochExhausted => Self::AdmissionEpochExhausted,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deployment_desired_configuration_constructs_transport_owner() {
        assert!(MeshTransportController::new().is_ok());
    }

    #[test]
    fn proxy_listener_projection_is_exactly_owner_backed() {
        let expected = canonical_listeners()
            .iter()
            .map(|listener| listener.port)
            .collect::<Vec<_>>();
        assert_eq!(proxy_listener_ports(), expected);
        let mappings = proxy_transport_mappings();
        assert_eq!(mappings.len(), expected.len());
        for (mapping, port) in mappings.iter().zip(expected) {
            assert_eq!(mapping.ingress_port(), port);
            assert_eq!(mapping.backend_port(), port);
        }
    }

    #[test]
    fn boundary_delegates_exact_candidate_admission_to_owner() {
        let controller = MeshTransportController::new().expect("controller");
        let admitted = controller
            .observe_unique_vpn(
                1,
                vec![
                    "127.0.0.1".to_owned(),
                    "192.168.1.4".to_owned(),
                    "100.96.2.4".to_owned(),
                    "100.96.2.4".to_owned(),
                ],
            )
            .expect("observation");
        assert_eq!(admitted.state, MeshAdmissionState::Admitted);
        assert_eq!(admitted.admission_epoch, Some(1));
        assert!(!admitted.ingress_running);
    }

    #[test]
    fn boundary_fails_closed_on_vpn_cardinality_and_multiple_mesh_addresses() {
        let controller = MeshTransportController::new().expect("controller");
        let absent = controller.observe_vpn_absent(1).expect("absent");
        assert_eq!(absent.state, MeshAdmissionState::NotAdmitted);

        let ambiguous = controller.observe_vpn_ambiguous(2).expect("ambiguous");
        assert_eq!(ambiguous.state, MeshAdmissionState::NotAdmitted);

        let multiple = controller
            .observe_unique_vpn(
                3,
                vec!["100.96.2.4".to_owned(), "100.97.2.5".to_owned()],
            )
            .expect("observation");
        assert_eq!(multiple.state, MeshAdmissionState::NotAdmitted);
        assert_eq!(
            multiple.reason,
            Some(MeshAdmissionReason::MultipleAcceptedAddresses)
        );
    }

    #[test]
    fn malformed_platform_address_fails_closed_at_boundary() {
        let controller = MeshTransportController::new().expect("controller");
        assert_eq!(
            controller.observe_unique_vpn(1, vec!["not-an-ipv4".to_owned()]),
            Err(MeshTransportBoundaryError::InvalidVpnObservation)
        );
    }

    #[test]
    fn stale_boundary_observation_is_rejected() {
        let controller = MeshTransportController::new().expect("controller");
        controller
            .observe_unique_vpn(2, vec!["100.96.2.4".to_owned()])
            .expect("current");
        assert_eq!(
            controller.observe_vpn_absent(1),
            Err(MeshTransportBoundaryError::StaleObservation)
        );
    }
}
