use mish_transport::{
    MeshAdmissionReason as OwnerAdmissionReason, MeshAdmissionSnapshot as OwnerAdmissionSnapshot,
    MeshAdmissionState as OwnerAdmissionState, MeshEndpointOwner, MeshIngressError,
    MeshIngressRuntime, MeshOwnerError,
};
use std::fmt;
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex, MutexGuard};

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

struct MeshTransportState {
    owner: MeshEndpointOwner,
    ingress: Option<MeshIngressRuntime>,
    ingress_epoch: Option<u64>,
}

#[derive(uniffi::Object)]
pub struct MeshTransportController {
    state: Mutex<MeshTransportState>,
}

#[uniffi::export]
impl MeshTransportController {
    #[uniffi::constructor]
    pub fn new(
        accepted_network: String,
        accepted_prefix: u8,
    ) -> Result<Arc<Self>, MeshTransportBoundaryError> {
        let network = accepted_network
            .parse::<Ipv4Addr>()
            .map_err(|_| MeshTransportBoundaryError::InvalidAcceptedCidr)?;
        let owner = MeshEndpointOwner::new(network, accepted_prefix)?;
        Ok(Arc::new(Self {
            state: Mutex::new(MeshTransportState {
                owner,
                ingress: None,
                ingress_epoch: None,
            }),
        }))
    }

    pub fn admission_snapshot(&self) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        let state = self.state()?;
        Ok(map_view(&state))
    }

    /// Publishes one complete local-IPv4 observation to the Rust natural owner.
    ///
    /// Android supplies raw locally assigned IPv4 strings only. CIDR filtering, uniqueness,
    /// endpoint admission, epoch semantics and fail-closed listener teardown remain here.
    pub fn observe_local_ipv4(
        &self,
        sequence: u64,
        local_ipv4: Vec<String>,
    ) -> Result<MeshAdmissionView, MeshTransportBoundaryError> {
        let addresses = local_ipv4
            .into_iter()
            .filter_map(|raw| raw.parse::<Ipv4Addr>().ok())
            .collect::<Vec<_>>();
        let mut state = self.state()?;
        let snapshot = state.owner.observe_local_ipv4(sequence, addresses)?;

        if state.ingress_epoch.is_some() && state.ingress_epoch != snapshot.admission_epoch() {
            stop_ingress_locked(&mut state)?;
        }
        Ok(map_view(&state))
    }

    /// Starts the exact-address ingress only for the caller's still-current admission epoch.
    pub fn start_ingress(&self, admission_epoch: u64) -> Result<bool, MeshTransportBoundaryError> {
        let mut state = self.state()?;
        let snapshot = state.owner.snapshot();
        if snapshot.state() != OwnerAdmissionState::Admitted
            || snapshot.admission_epoch() != Some(admission_epoch)
        {
            return Ok(false);
        }

        if state.ingress_epoch == Some(admission_epoch) {
            if state
                .ingress
                .as_ref()
                .is_some_and(MeshIngressRuntime::is_healthy)
            {
                return Ok(true);
            }
            stop_ingress_locked(&mut state)?;
        } else if state.ingress.is_some() {
            stop_ingress_locked(&mut state)?;
        }

        let endpoint = snapshot
            .admitted_endpoint()
            .ok_or(MeshTransportBoundaryError::IngressUnavailable)?;
        let ingress = MeshIngressRuntime::start_product(endpoint).map_err(map_ingress_error)?;
        state.ingress = Some(ingress);
        state.ingress_epoch = Some(admission_epoch);
        Ok(true)
    }

    pub fn stop_ingress(&self) -> Result<bool, MeshTransportBoundaryError> {
        let mut state = self.state()?;
        stop_ingress_locked(&mut state)?;
        Ok(true)
    }

    pub fn ingress_healthy(&self) -> Result<bool, MeshTransportBoundaryError> {
        let state = self.state()?;
        Ok(state
            .ingress
            .as_ref()
            .is_some_and(MeshIngressRuntime::is_healthy))
    }
}

impl MeshTransportController {
    fn state(&self) -> Result<MutexGuard<'_, MeshTransportState>, MeshTransportBoundaryError> {
        self.state
            .lock()
            .map_err(|_| MeshTransportBoundaryError::OwnerUnavailable)
    }
}

fn stop_ingress_locked(state: &mut MeshTransportState) -> Result<(), MeshTransportBoundaryError> {
    state.ingress_epoch = None;
    let Some(mut ingress) = state.ingress.take() else {
        return Ok(());
    };
    ingress
        .stop()
        .map_err(|_| MeshTransportBoundaryError::IngressShutdownFailed)
}

fn map_view(state: &MeshTransportState) -> MeshAdmissionView {
    let snapshot = state.owner.snapshot();
    MeshAdmissionView {
        state: match snapshot.state() {
            OwnerAdmissionState::NotAdmitted => MeshAdmissionState::NotAdmitted,
            OwnerAdmissionState::Admitted => MeshAdmissionState::Admitted,
        },
        reason: snapshot.reason().map(|reason| match reason {
            OwnerAdmissionReason::NoObservation => MeshAdmissionReason::NoObservation,
            OwnerAdmissionReason::NoAcceptedAddress => MeshAdmissionReason::NoAcceptedAddress,
            OwnerAdmissionReason::MultipleAcceptedAddresses => {
                MeshAdmissionReason::MultipleAcceptedAddresses
            }
        }),
        admission_epoch: snapshot.admission_epoch(),
        last_sequence: snapshot.last_sequence(),
        ingress_running: state
            .ingress
            .as_ref()
            .is_some_and(MeshIngressRuntime::is_healthy),
        active_sessions: state
            .ingress
            .as_ref()
            .map_or(0, |ingress| ingress.active_sessions() as u64),
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
    fn boundary_delegates_exact_candidate_admission_to_owner() {
        let controller =
            MeshTransportController::new("100.96.0.0".to_owned(), 12).expect("controller");
        let admitted = controller
            .observe_local_ipv4(
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
    fn boundary_fails_closed_on_multiple_mesh_addresses() {
        let controller =
            MeshTransportController::new("100.96.0.0".to_owned(), 12).expect("controller");
        let view = controller
            .observe_local_ipv4(1, vec!["100.96.2.4".to_owned(), "100.97.2.5".to_owned()])
            .expect("observation");
        assert_eq!(view.state, MeshAdmissionState::NotAdmitted);
        assert_eq!(
            view.reason,
            Some(MeshAdmissionReason::MultipleAcceptedAddresses)
        );
    }

    #[test]
    fn stale_boundary_observation_is_rejected() {
        let controller =
            MeshTransportController::new("100.96.0.0".to_owned(), 12).expect("controller");
        controller
            .observe_local_ipv4(2, vec!["100.96.2.4".to_owned()])
            .expect("current");
        assert_eq!(
            controller.observe_local_ipv4(1, vec!["100.96.2.5".to_owned()]),
            Err(MeshTransportBoundaryError::StaleObservation)
        );
    }
}
