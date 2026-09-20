use mish_transport::{
    MeshAdmissionReason as OwnerAdmissionReason, MeshAdmissionState as OwnerAdmissionState,
    MeshIngressError, MeshOwnerError, MeshTransportError as OwnerTransportError,
    MeshTransportSnapshot as OwnerTransportSnapshot,
};
use std::fmt;

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
    pub endpoint: Option<String>,
    pub admission_epoch: Option<u64>,
    pub last_sequence: Option<u64>,
    pub ingress_running: bool,
    pub active_sessions: u64,
    pub capacity_rejects: u64,
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

/// UniFFI projection only. The sole Mesh owner is embedded in NativeProductRuntime.
pub(crate) fn map_view(snapshot: OwnerTransportSnapshot) -> MeshAdmissionView {
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
        endpoint: admission.admitted_endpoint().map(|address| address.to_string()),
        admission_epoch: admission.admission_epoch(),
        last_sequence: admission.last_sequence(),
        ingress_running: snapshot.ingress_running(),
        active_sessions: snapshot.active_sessions() as u64,
        capacity_rejects: snapshot.capacity_rejects() as u64,
    }
}

pub(crate) fn map_transport_error(error: OwnerTransportError) -> MeshTransportBoundaryError {
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
        | MeshIngressError::ExecutorUnavailable => MeshTransportBoundaryError::IngressUnavailable,
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
