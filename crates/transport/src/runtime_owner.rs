use crate::{
    MeshAdmissionSnapshot, MeshAdmissionState, MeshEndpointOwner, MeshIngressError,
    MeshIngressRuntime, MeshOwnerError, MeshPortForward,
};
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MeshVpnObservation {
    Absent,
    UniqueVpn { local_ipv4: Vec<Ipv4Addr> },
    AmbiguousVpn,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshTransportError {
    Owner(MeshOwnerError),
    StateUnavailable,
    IngressUnavailable,
    Ingress(MeshIngressError),
    CleanupFailed,
}

impl From<MeshOwnerError> for MeshTransportError {
    fn from(error: MeshOwnerError) -> Self {
        Self::Owner(error)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeshTransportSnapshot {
    admission: MeshAdmissionSnapshot,
    ingress_running: bool,
    active_sessions: usize,
}

impl MeshTransportSnapshot {
    pub const fn admission(self) -> MeshAdmissionSnapshot {
        self.admission
    }

    pub const fn ingress_running(self) -> bool {
        self.ingress_running
    }

    pub const fn active_sessions(self) -> usize {
        self.active_sessions
    }
}

struct MeshTransportState {
    owner: MeshEndpointOwner,
    ingress: Option<MeshIngressRuntime>,
    ingress_epoch: Option<u64>,
    cleanup_failed: bool,
}

/// Natural-owner runtime coordination for one exact-address Mesh ingress generation.
///
/// Admission semantics, ingress epoch ownership and sticky cleanup-failure disposition live here.
/// Platform/FFI adapters supply one complete typed current-VPN observation and an owner-approved
/// port mapping, but they do not choose an endpoint or own independent lifecycle state.
pub struct MeshTransportCoordinator {
    state: Mutex<MeshTransportState>,
}

impl MeshTransportCoordinator {
    pub fn new(
        accepted_network: Ipv4Addr,
        accepted_prefix: u8,
    ) -> Result<Arc<Self>, MeshOwnerError> {
        Ok(Arc::new(Self {
            state: Mutex::new(MeshTransportState {
                owner: MeshEndpointOwner::new(accepted_network, accepted_prefix)?,
                ingress: None,
                ingress_epoch: None,
                cleanup_failed: false,
            }),
        }))
    }

    pub fn snapshot(&self) -> Result<MeshTransportSnapshot, MeshTransportError> {
        let state = self.state()?;
        Ok(snapshot_locked(&state))
    }

    pub fn observe_vpn(
        &self,
        sequence: u64,
        observation: MeshVpnObservation,
    ) -> Result<MeshTransportSnapshot, MeshTransportError> {
        let mut state = self.state()?;
        let addresses = match observation {
            MeshVpnObservation::Absent | MeshVpnObservation::AmbiguousVpn => Vec::new(),
            MeshVpnObservation::UniqueVpn { local_ipv4 } => local_ipv4,
        };
        let admission = state.owner.observe_local_ipv4(sequence, addresses)?;
        if state.ingress_epoch.is_some() && state.ingress_epoch != admission.admission_epoch() {
            // The state mutex makes observation replacement atomic to every caller. Old listeners
            // and sessions are closed before this method can publish/return the new owner view.
            stop_ingress_locked(&mut state)?;
        }
        Ok(snapshot_locked(&state))
    }

    pub fn start_ingress(
        &self,
        admission_epoch: u64,
        mappings: &[MeshPortForward],
    ) -> Result<bool, MeshTransportError> {
        let mut state = self.state()?;
        if state.cleanup_failed {
            return Err(MeshTransportError::CleanupFailed);
        }

        let admission = state.owner.snapshot();
        if admission.state() != MeshAdmissionState::Admitted
            || admission.admission_epoch() != Some(admission_epoch)
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

        let endpoint = admission
            .admitted_endpoint()
            .ok_or(MeshTransportError::IngressUnavailable)?;
        let ingress =
            MeshIngressRuntime::start(endpoint, mappings).map_err(MeshTransportError::Ingress)?;
        state.ingress = Some(ingress);
        state.ingress_epoch = Some(admission_epoch);
        Ok(true)
    }

    pub fn stop_ingress(&self) -> Result<(), MeshTransportError> {
        let mut state = self.state()?;
        stop_ingress_locked(&mut state)
    }

    pub fn ingress_healthy(&self) -> Result<bool, MeshTransportError> {
        Ok(self.snapshot()?.ingress_running())
    }

    fn state(&self) -> Result<MutexGuard<'_, MeshTransportState>, MeshTransportError> {
        self.state
            .lock()
            .map_err(|_| MeshTransportError::StateUnavailable)
    }
}

fn stop_ingress_locked(state: &mut MeshTransportState) -> Result<(), MeshTransportError> {
    state.ingress_epoch = None;
    let Some(mut ingress) = state.ingress.take() else {
        return if state.cleanup_failed {
            Err(MeshTransportError::CleanupFailed)
        } else {
            Ok(())
        };
    };

    if ingress.stop().is_err() {
        state.cleanup_failed = true;
        return Err(MeshTransportError::CleanupFailed);
    }
    if state.cleanup_failed {
        Err(MeshTransportError::CleanupFailed)
    } else {
        Ok(())
    }
}

fn snapshot_locked(state: &MeshTransportState) -> MeshTransportSnapshot {
    MeshTransportSnapshot {
        admission: state.owner.snapshot(),
        ingress_running: !state.cleanup_failed
            && state
                .ingress
                .as_ref()
                .is_some_and(MeshIngressRuntime::is_healthy),
        active_sessions: state
            .ingress
            .as_ref()
            .map_or(0, MeshIngressRuntime::active_sessions),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::MeshAdmissionReason;
    use std::net::TcpListener;

    fn coordinator() -> Arc<MeshTransportCoordinator> {
        MeshTransportCoordinator::new(Ipv4Addr::new(100, 96, 0, 0), 12)
            .expect("valid Mesh coordinator")
    }

    fn unique(addresses: impl IntoIterator<Item = Ipv4Addr>) -> MeshVpnObservation {
        MeshVpnObservation::UniqueVpn {
            local_ipv4: addresses.into_iter().collect(),
        }
    }

    #[test]
    fn zero_or_multiple_current_vpns_fail_closed() {
        let runtime = coordinator();
        let absent = runtime
            .observe_vpn(1, MeshVpnObservation::Absent)
            .expect("absent observation");
        assert_eq!(absent.admission().state(), MeshAdmissionState::NotAdmitted);
        assert_eq!(
            absent.admission().reason(),
            Some(MeshAdmissionReason::NoAcceptedAddress)
        );

        let ambiguous = runtime
            .observe_vpn(2, MeshVpnObservation::AmbiguousVpn)
            .expect("ambiguous observation");
        assert_eq!(ambiguous.admission().state(), MeshAdmissionState::NotAdmitted);
        assert_eq!(ambiguous.admission().admission_epoch(), None);
    }

    #[test]
    fn unique_vpn_filters_zero_one_or_multiple_allowed_addresses() {
        let runtime = coordinator();
        let zero = runtime
            .observe_vpn(
                1,
                unique([
                    Ipv4Addr::new(127, 0, 0, 1),
                    Ipv4Addr::new(192, 168, 1, 4),
                ]),
            )
            .expect("zero accepted");
        assert_eq!(zero.admission().state(), MeshAdmissionState::NotAdmitted);

        let one = runtime
            .observe_vpn(
                2,
                unique([
                    Ipv4Addr::new(192, 168, 1, 4),
                    Ipv4Addr::new(100, 96, 2, 4),
                ]),
            )
            .expect("one accepted");
        assert_eq!(one.admission().state(), MeshAdmissionState::Admitted);
        assert_eq!(one.admission().admission_epoch(), Some(1));

        let multiple = runtime
            .observe_vpn(
                3,
                unique([
                    Ipv4Addr::new(100, 96, 2, 4),
                    Ipv4Addr::new(100, 97, 2, 5),
                ]),
            )
            .expect("multiple accepted");
        assert_eq!(multiple.admission().state(), MeshAdmissionState::NotAdmitted);
        assert_eq!(
            multiple.admission().reason(),
            Some(MeshAdmissionReason::MultipleAcceptedAddresses)
        );
    }

    #[test]
    fn loss_and_same_address_reappearance_create_fresh_epoch() {
        let runtime = coordinator();
        let first = runtime
            .observe_vpn(1, unique([Ipv4Addr::new(100, 96, 2, 4)]))
            .expect("first");
        let first_epoch = first.admission().admission_epoch().expect("first epoch");

        runtime
            .observe_vpn(2, MeshVpnObservation::Absent)
            .expect("loss");
        let returned = runtime
            .observe_vpn(3, unique([Ipv4Addr::new(100, 96, 2, 4)]))
            .expect("return");
        assert_ne!(returned.admission().admission_epoch(), Some(first_epoch));
    }

    #[test]
    fn replacement_gets_fresh_epoch() {
        let runtime = coordinator();
        let first = runtime
            .observe_vpn(1, unique([Ipv4Addr::new(100, 96, 2, 4)]))
            .expect("first");
        let changed = runtime
            .observe_vpn(2, unique([Ipv4Addr::new(100, 96, 2, 5)]))
            .expect("replacement");
        assert_ne!(
            changed.admission().admission_epoch(),
            first.admission().admission_epoch()
        );
    }

    #[test]
    fn cleanup_failure_taint_blocks_fresh_ingress_in_same_generation() {
        let runtime = coordinator();
        let admitted = runtime
            .observe_vpn(1, unique([Ipv4Addr::new(100, 96, 2, 4)]))
            .expect("observation");
        let epoch = admitted.admission().admission_epoch().expect("epoch");
        runtime.state().expect("state").cleanup_failed = true;

        assert_eq!(
            runtime.start_ingress(epoch, &[MeshPortForward::same(40001)]),
            Err(MeshTransportError::CleanupFailed)
        );
        assert_eq!(
            runtime.stop_ingress(),
            Err(MeshTransportError::CleanupFailed)
        );
        assert_eq!(runtime.ingress_healthy(), Ok(false));
    }

    #[test]
    fn stale_observation_is_rejected_without_replacing_current_admission() {
        let runtime = coordinator();
        let current = runtime
            .observe_vpn(2, unique([Ipv4Addr::new(100, 96, 2, 4)]))
            .expect("current");
        assert_eq!(
            runtime.observe_vpn(1, MeshVpnObservation::Absent),
            Err(MeshTransportError::Owner(MeshOwnerError::StaleObservation))
        );
        assert_eq!(runtime.snapshot().expect("snapshot"), current);
    }

    #[test]
    fn loss_stops_listener_before_same_endpoint_can_receive_fresh_epoch() {
        let runtime = MeshTransportCoordinator::new(Ipv4Addr::new(127, 0, 0, 0), 8)
            .expect("loopback test coordinator");
        let reserve = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("reserve");
        let port = reserve.local_addr().expect("address").port();
        drop(reserve);

        let first = runtime
            .observe_vpn(1, unique([Ipv4Addr::LOCALHOST]))
            .expect("first");
        let first_epoch = first.admission().admission_epoch().expect("epoch");
        assert!(runtime
            .start_ingress(first_epoch, &[MeshPortForward::same(port)])
            .expect("start ingress"));
        assert!(runtime.ingress_healthy().expect("healthy"));

        let lost = runtime
            .observe_vpn(2, MeshVpnObservation::Absent)
            .expect("loss");
        assert!(!lost.ingress_running());
        assert_eq!(lost.active_sessions(), 0);

        let returned = runtime
            .observe_vpn(3, unique([Ipv4Addr::LOCALHOST]))
            .expect("return");
        assert_ne!(returned.admission().admission_epoch(), Some(first_epoch));
        assert!(!returned.ingress_running());
    }
}
