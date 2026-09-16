//! Transport Reachability natural-owner capability.
//!
//! Owns exact admitted Mesh endpoint facts, admission epochs, the external session budget and the
//! active external-session fact. Long-lived listener/session/relay execution is deliberately not
//! implemented here: `mish-runtime` consumes the typed execution seam below on its one Tokio
//! runtime. Transport does not own proxy protocols, authentication, DNS or public egress.

use mish_configuration::EXTERNAL_TCP_SESSION_BUDGET;
use std::collections::BTreeSet;
use std::net::Ipv4Addr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

/// One external Mesh generation admits exactly the repository-owned external session budget.
/// Capacity remains a Transport Reachability fact even though admitted work executes in
/// `mish-runtime`.
pub const MAX_MESH_SESSIONS: usize = EXTERNAL_TCP_SESSION_BUDGET;

const MIN_ACCEPTED_PREFIX: u8 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshAdmissionState {
    NotAdmitted,
    Admitted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshAdmissionReason {
    NoObservation,
    NoAcceptedAddress,
    MultipleAcceptedAddresses,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeshAdmissionSnapshot {
    state: MeshAdmissionState,
    reason: Option<MeshAdmissionReason>,
    admitted_endpoint: Option<Ipv4Addr>,
    admission_epoch: Option<u64>,
    last_sequence: Option<u64>,
}

impl MeshAdmissionSnapshot {
    pub fn state(self) -> MeshAdmissionState {
        self.state
    }

    pub fn reason(self) -> Option<MeshAdmissionReason> {
        self.reason
    }

    pub fn admitted_endpoint(self) -> Option<Ipv4Addr> {
        self.admitted_endpoint
    }

    pub fn admission_epoch(self) -> Option<u64> {
        self.admission_epoch
    }

    pub fn last_sequence(self) -> Option<u64> {
        self.last_sequence
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshOwnerError {
    InvalidAcceptedCidr,
    InvalidObservationSequence,
    StaleObservation,
    AdmissionEpochExhausted,
}

#[derive(Debug, Clone, Copy)]
struct Ipv4Cidr {
    network: u32,
    mask: u32,
}

impl Ipv4Cidr {
    fn new(network: Ipv4Addr, prefix: u8) -> Result<Self, MeshOwnerError> {
        if !(MIN_ACCEPTED_PREFIX..=32).contains(&prefix) {
            return Err(MeshOwnerError::InvalidAcceptedCidr);
        }
        let mask = u32::MAX << (32 - prefix);
        let network = u32::from(network);
        if network & mask != network {
            return Err(MeshOwnerError::InvalidAcceptedCidr);
        }
        Ok(Self { network, mask })
    }

    fn contains(self, address: Ipv4Addr) -> bool {
        !address.is_unspecified()
            && !address.is_multicast()
            && address != Ipv4Addr::BROADCAST
            && (u32::from(address) & self.mask) == self.network
    }
}

/// Process-generation owner of the exact currently admitted Mesh endpoint.
///
/// The caller supplies local IPv4 observations. This owner admits only when exactly one distinct
/// local IPv4 lies inside the deployment-approved Mesh CIDR. The exact address is not persisted.
/// Loss removes admission immediately; observing the same address after loss creates a fresh
/// admission epoch, and an address change can never inherit the previous epoch.
pub struct MeshEndpointOwner {
    accepted: Ipv4Cidr,
    snapshot: MeshAdmissionSnapshot,
    next_epoch: u64,
}

impl MeshEndpointOwner {
    pub fn new(accepted_network: Ipv4Addr, accepted_prefix: u8) -> Result<Self, MeshOwnerError> {
        Ok(Self {
            accepted: Ipv4Cidr::new(accepted_network, accepted_prefix)?,
            snapshot: MeshAdmissionSnapshot {
                state: MeshAdmissionState::NotAdmitted,
                reason: Some(MeshAdmissionReason::NoObservation),
                admitted_endpoint: None,
                admission_epoch: None,
                last_sequence: None,
            },
            next_epoch: 0,
        })
    }

    pub fn snapshot(&self) -> MeshAdmissionSnapshot {
        self.snapshot
    }

    pub fn observe_local_ipv4<I>(
        &mut self,
        sequence: u64,
        addresses: I,
    ) -> Result<MeshAdmissionSnapshot, MeshOwnerError>
    where
        I: IntoIterator<Item = Ipv4Addr>,
    {
        if sequence == 0 {
            return Err(MeshOwnerError::InvalidObservationSequence);
        }
        if self
            .snapshot
            .last_sequence
            .is_some_and(|last| sequence <= last)
        {
            return Err(MeshOwnerError::StaleObservation);
        }

        let candidates: BTreeSet<Ipv4Addr> = addresses
            .into_iter()
            .filter(|address| self.accepted.contains(*address))
            .collect();

        let (state, reason, admitted_endpoint) = match candidates.len() {
            0 => (
                MeshAdmissionState::NotAdmitted,
                Some(MeshAdmissionReason::NoAcceptedAddress),
                None,
            ),
            1 => (
                MeshAdmissionState::Admitted,
                None,
                candidates.first().copied(),
            ),
            _ => (
                MeshAdmissionState::NotAdmitted,
                Some(MeshAdmissionReason::MultipleAcceptedAddresses),
                None,
            ),
        };

        let admission_epoch = match admitted_endpoint {
            None => None,
            Some(endpoint) if self.snapshot.admitted_endpoint == Some(endpoint) => {
                self.snapshot.admission_epoch
            }
            Some(_) => {
                self.next_epoch = self
                    .next_epoch
                    .checked_add(1)
                    .ok_or(MeshOwnerError::AdmissionEpochExhausted)?;
                Some(self.next_epoch)
            }
        };

        self.snapshot = MeshAdmissionSnapshot {
            state,
            reason,
            admitted_endpoint,
            admission_epoch,
            last_sequence: Some(sequence),
        };
        Ok(self.snapshot)
    }
}

/// Runtime-mechanism failures crossing the typed Transport -> Runtime execution seam.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshIngressError {
    InvalidEndpoint,
    InvalidPortMapping,
    BindFailed,
    ListenerConfigurationFailed,
    ExecutorUnavailable,
    ShutdownTimedOut,
}

/// One explicit transport-only ingress/backend mapping supplied by the composition adapter.
/// Transport does not know which proxy protocol owns the port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeshPortForward {
    ingress_port: u16,
    backend_port: u16,
}

impl MeshPortForward {
    pub const fn new(ingress_port: u16, backend_port: u16) -> Self {
        Self {
            ingress_port,
            backend_port,
        }
    }

    pub const fn same(port: u16) -> Self {
        Self::new(port, port)
    }

    pub const fn ingress_port(self) -> u16 {
        self.ingress_port
    }

    pub const fn backend_port(self) -> u16 {
        self.backend_port
    }
}

/// Canonical owner of the admitted external-session fact for one Mesh ingress generation.
///
/// The runtime may execute a lease but cannot mint capacity independently. Revocation prevents
/// fresh leases immediately; dropping a lease decrements the owner fact exactly once.
pub struct MeshSessionOwner {
    accepting: AtomicBool,
    active: AtomicUsize,
}

impl MeshSessionOwner {
    pub fn product_generation() -> Arc<Self> {
        Arc::new(Self {
            accepting: AtomicBool::new(true),
            active: AtomicUsize::new(0),
        })
    }

    pub fn try_admit(self: &Arc<Self>) -> Option<MeshSessionLease> {
        if !self.accepting.load(Ordering::Acquire) {
            return None;
        }

        let mut current = self.active.load(Ordering::Acquire);
        loop {
            if current >= MAX_MESH_SESSIONS {
                return None;
            }
            match self.active.compare_exchange_weak(
                current,
                current + 1,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => break,
                Err(observed) => current = observed,
            }
        }

        if !self.accepting.load(Ordering::Acquire) {
            self.active.fetch_sub(1, Ordering::AcqRel);
            return None;
        }

        Some(MeshSessionLease {
            owner: Arc::clone(self),
        })
    }

    pub fn revoke(&self) {
        self.accepting.store(false, Ordering::Release);
    }

    pub fn is_accepting(&self) -> bool {
        self.accepting.load(Ordering::Acquire)
    }

    pub fn active_sessions(&self) -> usize {
        self.active.load(Ordering::Acquire)
    }
}

/// One admitted external Mesh session. Runtime task ownership may move this value freely; its Drop
/// is the single decrement path for `mesh.active_sessions`.
pub struct MeshSessionLease {
    owner: Arc<MeshSessionOwner>,
}

impl MeshSessionLease {
    pub fn is_current(&self) -> bool {
        self.owner.is_accepting()
    }
}

impl Drop for MeshSessionLease {
    fn drop(&mut self) {
        let previous = self.owner.active.fetch_sub(1, Ordering::AcqRel);
        debug_assert!(previous > 0, "Mesh session owner underflow");
    }
}

/// Minimal typed seam: Transport owns whether work is admitted; Runtime owns how it executes.
/// Implementations must retain every listener/session task and stop them deterministically.
pub trait MeshIngressExecutor: Send + Sync {
    fn start_ingress(
        &self,
        endpoint: Ipv4Addr,
        mappings: &[MeshPortForward],
        sessions: Arc<MeshSessionOwner>,
    ) -> Result<(), MeshIngressError>;

    fn stop_ingress(&self) -> Result<(), MeshIngressError>;

    fn ingress_healthy(&self) -> bool;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn owner() -> MeshEndpointOwner {
        MeshEndpointOwner::new(Ipv4Addr::new(100, 96, 0, 0), 12).expect("valid Mesh range")
    }

    #[test]
    fn admission_requires_exactly_one_address_inside_accepted_range() {
        let mut owner = owner();
        let snapshot = owner
            .observe_local_ipv4(
                1,
                [
                    Ipv4Addr::new(127, 0, 0, 1),
                    Ipv4Addr::new(192, 168, 1, 2),
                    Ipv4Addr::new(100, 96, 4, 8),
                ],
            )
            .expect("observe");
        assert_eq!(snapshot.state(), MeshAdmissionState::Admitted);
        assert_eq!(
            snapshot.admitted_endpoint(),
            Some(Ipv4Addr::new(100, 96, 4, 8))
        );
        assert_eq!(snapshot.admission_epoch(), Some(1));

        let ambiguous = owner
            .observe_local_ipv4(
                2,
                [Ipv4Addr::new(100, 96, 4, 8), Ipv4Addr::new(100, 97, 4, 9)],
            )
            .expect("observe ambiguous");
        assert_eq!(ambiguous.state(), MeshAdmissionState::NotAdmitted);
        assert_eq!(
            ambiguous.reason(),
            Some(MeshAdmissionReason::MultipleAcceptedAddresses)
        );
        assert_eq!(ambiguous.admission_epoch(), None);
    }

    #[test]
    fn loss_and_reappearance_create_a_fresh_epoch_without_caching() {
        let mut owner = owner();
        let first = owner
            .observe_local_ipv4(1, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("first admission");
        let stable = owner
            .observe_local_ipv4(2, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("stable observation");
        assert_eq!(first.admission_epoch(), stable.admission_epoch());

        let lost = owner
            .observe_local_ipv4(3, [Ipv4Addr::new(192, 168, 1, 1)])
            .expect("loss");
        assert_eq!(lost.state(), MeshAdmissionState::NotAdmitted);
        assert_eq!(lost.admission_epoch(), None);

        let returned = owner
            .observe_local_ipv4(4, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("re-admission");
        assert_eq!(returned.state(), MeshAdmissionState::Admitted);
        assert_ne!(returned.admission_epoch(), first.admission_epoch());
    }

    #[test]
    fn address_change_never_inherits_old_epoch() {
        let mut owner = owner();
        let first = owner
            .observe_local_ipv4(1, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("first");
        let changed = owner
            .observe_local_ipv4(2, [Ipv4Addr::new(100, 96, 0, 8)])
            .expect("changed");
        assert_ne!(changed.admitted_endpoint(), first.admitted_endpoint());
        assert_ne!(changed.admission_epoch(), first.admission_epoch());
    }

    #[test]
    fn stale_observation_cannot_replace_current_admission() {
        let mut owner = owner();
        let current = owner
            .observe_local_ipv4(2, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("current");
        assert_eq!(
            owner.observe_local_ipv4(1, [Ipv4Addr::new(100, 96, 0, 8)]),
            Err(MeshOwnerError::StaleObservation)
        );
        assert_eq!(owner.snapshot(), current);
    }

    #[test]
    fn broad_or_noncanonical_cidr_is_rejected() {
        assert!(matches!(
            MeshEndpointOwner::new(Ipv4Addr::UNSPECIFIED, 0),
            Err(MeshOwnerError::InvalidAcceptedCidr)
        ));
        assert!(matches!(
            MeshEndpointOwner::new(Ipv4Addr::new(100, 96, 1, 0), 12),
            Err(MeshOwnerError::InvalidAcceptedCidr)
        ));
    }

    #[test]
    fn transport_budget_is_exact_and_lease_drop_is_the_only_decrement() {
        let sessions = MeshSessionOwner::product_generation();
        let mut leases = Vec::with_capacity(MAX_MESH_SESSIONS);
        for _ in 0..MAX_MESH_SESSIONS {
            leases.push(sessions.try_admit().expect("within Mesh budget"));
        }
        assert_eq!(sessions.active_sessions(), MAX_MESH_SESSIONS);
        assert!(sessions.try_admit().is_none(), "65th session must be rejected");

        drop(leases.pop());
        assert_eq!(sessions.active_sessions(), MAX_MESH_SESSIONS - 1);
        leases.push(sessions.try_admit().expect("released capacity is reusable"));
        assert_eq!(sessions.active_sessions(), MAX_MESH_SESSIONS);

        sessions.revoke();
        assert!(!sessions.is_accepting());
        assert!(sessions.try_admit().is_none());
        drop(leases);
        assert_eq!(sessions.active_sessions(), 0);
    }

    #[test]
    fn product_ports_are_not_owned_by_transport() {
        let mappings = [MeshPortForward::same(40001), MeshPortForward::same(40002)];
        assert_eq!(mappings[0].ingress_port(), 40001);
        assert_eq!(mappings[0].backend_port(), 40001);
        assert_eq!(mappings[1].ingress_port(), 40002);
    }
}
