use crate::{
    MeshAdmissionSnapshot, MeshAdmissionState, MeshEndpointOwner, MeshIngressError,
    MeshIngressRuntime, MeshOwnerError, MeshPortForward,
};
use std::net::Ipv4Addr;
use std::sync::{Arc, Mutex, MutexGuard};

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
/// Platform/FFI adapters may supply fresh local-address observations and an owner-approved port
/// mapping, but they do not own independent lifecycle state.
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

    pub fn observe_local_ipv4<I>(
        &self,
        sequence: u64,
        addresses: I,
    ) -> Result<MeshTransportSnapshot, MeshTransportError>
    where
        I: IntoIterator<Item = Ipv4Addr>,
    {
        let mut state = self.state()?;
        let admission = state.owner.observe_local_ipv4(sequence, addresses)?;
        if state.ingress_epoch.is_some() && state.ingress_epoch != admission.admission_epoch() {
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

    fn coordinator() -> Arc<MeshTransportCoordinator> {
        MeshTransportCoordinator::new(Ipv4Addr::new(100, 96, 0, 0), 12)
            .expect("valid Mesh coordinator")
    }

    #[test]
    fn coordinator_owns_admission_projection() {
        let runtime = coordinator();
        let view = runtime
            .observe_local_ipv4(
                1,
                [
                    Ipv4Addr::new(127, 0, 0, 1),
                    Ipv4Addr::new(100, 96, 2, 4),
                ],
            )
            .expect("observation");
        assert_eq!(view.admission().state(), MeshAdmissionState::Admitted);
        assert_eq!(view.admission().admission_epoch(), Some(1));
        assert!(!view.ingress_running());
        assert_eq!(view.active_sessions(), 0);
    }

    #[test]
    fn cleanup_failure_taint_blocks_fresh_ingress_in_same_generation() {
        let runtime = coordinator();
        let admitted = runtime
            .observe_local_ipv4(1, [Ipv4Addr::new(100, 96, 2, 4)])
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
    fn stale_observation_is_still_rejected_by_endpoint_owner() {
        let runtime = coordinator();
        runtime
            .observe_local_ipv4(2, [Ipv4Addr::new(100, 96, 2, 4)])
            .expect("current");
        assert_eq!(
            runtime.observe_local_ipv4(1, [Ipv4Addr::new(100, 96, 2, 5)]),
            Err(MeshTransportError::Owner(MeshOwnerError::StaleObservation))
        );
    }
}
