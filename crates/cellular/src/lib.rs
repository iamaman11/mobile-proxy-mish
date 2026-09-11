//! Cellular Egress natural-owner capability.
//!
//! Owns validated cellular selection policy, cellular-scoped DNS semantics, socket
//! binding policy, and public-egress observations. Android platform objects do not
//! cross this boundary; the owner receives only typed ephemeral observations.
//!
//! This B2a slice models **network admission only**. A validated Android `Network`
//! is not yet proof that socket binding, DNS, or public Internet egress are working.

/// Opaque Android network identity for the lifetime of a runtime observation.
///
/// This is deliberately not a durable device or network identity.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct NetworkHandle(u64);

impl NetworkHandle {
    /// Creates a network handle when Android supplied a non-zero native handle.
    pub const fn new(raw: u64) -> Option<Self> {
        if raw == 0 { None } else { Some(Self(raw)) }
    }

    /// Returns the opaque platform value for a bounded adapter operation.
    pub const fn raw(self) -> u64 {
        self.0
    }
}

/// Monotonic event ordering within one runtime generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ObservationSequence(u64);

impl ObservationSequence {
    /// Creates a sequence value. Zero is reserved for "no observation yet".
    pub const fn new(raw: u64) -> Option<Self> {
        if raw == 0 { None } else { Some(Self(raw)) }
    }

    /// Returns the runtime-local sequence number.
    pub const fn raw(self) -> u64 {
        self.0
    }
}

/// Opaque token for one exact owner-admitted cellular authority generation.
///
/// Callers cannot construct this token or choose its network. Platform adapters may
/// inspect the captured handle only after a natural-owner validation step.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularNetworkAuthority {
    network: NetworkHandle,
    sequence: ObservationSequence,
}

impl CellularNetworkAuthority {
    /// Returns the exact ephemeral Android Network captured when the owner issued this
    /// authority. This does not prove that the authority is still current; consumers
    /// must validate against the owner immediately before and after bounded effects.
    pub const fn network_handle(self) -> NetworkHandle {
        self.network
    }
}

/// Fail-closed authority issuance/currentness errors owned by Cellular Egress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularNetworkAuthorityError {
    /// No exact cellular network generation is currently admitted.
    NoAdmittedNetwork,
    /// The captured authority is no longer the owner's current admitted generation.
    NetworkChanged,
}

/// Platform observation presented to the Cellular Egress owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NetworkObservation {
    sequence: ObservationSequence,
    handle: NetworkHandle,
    is_cellular: bool,
    has_internet: bool,
    is_validated: bool,
    is_not_vpn: bool,
}

impl NetworkObservation {
    /// Constructs one immutable platform observation.
    pub const fn new(
        sequence: ObservationSequence,
        handle: NetworkHandle,
        is_cellular: bool,
        has_internet: bool,
        is_validated: bool,
        is_not_vpn: bool,
    ) -> Self {
        Self {
            sequence,
            handle,
            is_cellular,
            has_internet,
            is_validated,
            is_not_vpn,
        }
    }

    const fn rejection_reason(self) -> Option<CellularAdmissionReason> {
        if !self.is_cellular {
            Some(CellularAdmissionReason::NotCellular)
        } else if !self.has_internet {
            Some(CellularAdmissionReason::MissingInternetCapability)
        } else if !self.is_not_vpn {
            Some(CellularAdmissionReason::VpnDerivedNetwork)
        } else if !self.is_validated {
            Some(CellularAdmissionReason::NotValidated)
        } else {
            None
        }
    }
}

/// Admission state for the currently observed Android network candidate.
///
/// `Admitted` means only that Android currently reports a direct cellular network with
/// `INTERNET + VALIDATED + NOT_VPN`. It does not claim complete Cellular Egress readiness.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularAdmissionState {
    /// No fresh owner observation exists yet.
    Unknown,
    /// A fresh observation proves that no network is currently admissible.
    NotAdmitted,
    /// A fresh Android observation satisfies the cellular admission predicate.
    Admitted,
}

/// Stable reason codes for cellular network admission.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularAdmissionReason {
    /// Startup/restart has not produced a fresh network observation yet.
    NoObservation,
    /// The observed candidate was not a cellular transport.
    NotCellular,
    /// The observed candidate lacked Android's INTERNET capability.
    MissingInternetCapability,
    /// The observed candidate was VPN-derived rather than a direct non-VPN network.
    VpnDerivedNetwork,
    /// The observed candidate lacked Android's VALIDATED capability.
    NotValidated,
    /// The currently admitted network was reported lost.
    NetworkLost,
}

/// Read-only projection of the Cellular Egress owner's network-admission fact.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularAdmissionSnapshot {
    state: CellularAdmissionState,
    reason: Option<CellularAdmissionReason>,
    admitted_network: Option<NetworkHandle>,
    last_sequence: Option<ObservationSequence>,
}

impl CellularAdmissionSnapshot {
    /// Current network-admission state.
    pub const fn state(self) -> CellularAdmissionState {
        self.state
    }

    /// Typed reason when no network is admitted or no fresh observation exists.
    pub const fn reason(self) -> Option<CellularAdmissionReason> {
        self.reason
    }

    /// Current admitted ephemeral network, when one exists.
    pub const fn admitted_network(self) -> Option<NetworkHandle> {
        self.admitted_network
    }

    /// Last accepted runtime-local observation sequence.
    pub const fn last_sequence(self) -> Option<ObservationSequence> {
        self.last_sequence
    }
}

/// Result of applying an Android observation to the natural owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApplyResult {
    /// The event was newer than the current owner state and was applied.
    Applied(CellularAdmissionSnapshot),
    /// The event was stale/reordered and therefore could not mutate owner state.
    IgnoredStale(CellularAdmissionSnapshot),
}

/// Single natural owner of admitted cellular-network state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularEgress {
    admission: CellularAdmissionSnapshot,
}

impl Default for CellularEgress {
    fn default() -> Self {
        Self::new()
    }
}

impl CellularEgress {
    /// Creates an owner with no fresh runtime observation.
    pub const fn new() -> Self {
        Self {
            admission: CellularAdmissionSnapshot {
                state: CellularAdmissionState::Unknown,
                reason: Some(CellularAdmissionReason::NoObservation),
                admitted_network: None,
                last_sequence: None,
            },
        }
    }

    /// Returns the current read-only network-admission projection.
    pub const fn admission(&self) -> CellularAdmissionSnapshot {
        self.admission
    }

    /// Issues an opaque token for the exact cellular authority currently admitted.
    ///
    /// No authority is produced for UNKNOWN/NOT_ADMITTED state. The token captures
    /// both the network handle and the observation generation so re-observing the same
    /// raw handle still invalidates older tokens.
    pub fn admitted_network_authority(
        &self,
    ) -> Result<CellularNetworkAuthority, CellularNetworkAuthorityError> {
        if self.admission.state != CellularAdmissionState::Admitted {
            return Err(CellularNetworkAuthorityError::NoAdmittedNetwork);
        }

        let network = self
            .admission
            .admitted_network
            .ok_or(CellularNetworkAuthorityError::NoAdmittedNetwork)?;
        let sequence = self
            .admission
            .last_sequence
            .ok_or(CellularNetworkAuthorityError::NoAdmittedNetwork)?;

        Ok(CellularNetworkAuthority { network, sequence })
    }

    /// Verifies that an owner-issued authority is still this owner's exact current
    /// admitted generation.
    pub fn validate_network_authority(
        &self,
        authority: CellularNetworkAuthority,
    ) -> Result<(), CellularNetworkAuthorityError> {
        let unchanged = self.admission.state == CellularAdmissionState::Admitted
            && self.admission.admitted_network == Some(authority.network)
            && self.admission.last_sequence == Some(authority.sequence);

        if unchanged {
            Ok(())
        } else {
            Err(CellularNetworkAuthorityError::NetworkChanged)
        }
    }

    /// Applies a fresh capabilities observation.
    ///
    /// An invalid observation for the *currently admitted* handle invalidates it
    /// immediately. An unrelated invalid candidate cannot evict an already-admitted
    /// validated direct cellular network.
    pub fn observe(&mut self, observation: NetworkObservation) -> ApplyResult {
        if self.is_stale(observation.sequence) {
            return ApplyResult::IgnoredStale(self.admission);
        }

        self.admission.last_sequence = Some(observation.sequence);

        if let Some(reason) = observation.rejection_reason() {
            let invalidates_current = self.admission.admitted_network.is_none()
                || self.admission.admitted_network == Some(observation.handle);

            if invalidates_current {
                self.admission.state = CellularAdmissionState::NotAdmitted;
                self.admission.reason = Some(reason);
                self.admission.admitted_network = None;
            }
        } else {
            self.admission.state = CellularAdmissionState::Admitted;
            self.admission.reason = None;
            self.admission.admitted_network = Some(observation.handle);
        }

        ApplyResult::Applied(self.admission)
    }

    /// Applies a platform `onLost`-equivalent event.
    ///
    /// Losing an old superseded handle cannot evict a newer admitted cellular network.
    pub fn lost(&mut self, sequence: ObservationSequence, handle: NetworkHandle) -> ApplyResult {
        if self.is_stale(sequence) {
            return ApplyResult::IgnoredStale(self.admission);
        }

        self.admission.last_sequence = Some(sequence);

        if self.admission.admitted_network == Some(handle) {
            self.admission.state = CellularAdmissionState::NotAdmitted;
            self.admission.reason = Some(CellularAdmissionReason::NetworkLost);
            self.admission.admitted_network = None;
        } else if self.admission.state == CellularAdmissionState::Unknown {
            self.admission.state = CellularAdmissionState::NotAdmitted;
            self.admission.reason = Some(CellularAdmissionReason::NetworkLost);
        }

        ApplyResult::Applied(self.admission)
    }

    fn is_stale(&self, sequence: ObservationSequence) -> bool {
        matches!(self.admission.last_sequence, Some(last) if sequence <= last)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn handle(raw: u64) -> NetworkHandle {
        NetworkHandle::new(raw).expect("test network handle must be non-zero")
    }

    fn sequence(raw: u64) -> ObservationSequence {
        ObservationSequence::new(raw).expect("test sequence must be non-zero")
    }

    fn observation(
        seq: u64,
        network: u64,
        is_cellular: bool,
        has_internet: bool,
        is_validated: bool,
        is_not_vpn: bool,
    ) -> NetworkObservation {
        NetworkObservation::new(
            sequence(seq),
            handle(network),
            is_cellular,
            has_internet,
            is_validated,
            is_not_vpn,
        )
    }

    #[test]
    fn starts_unknown_without_a_fresh_observation() {
        let owner = CellularEgress::new();

        assert_eq!(owner.admission().state(), CellularAdmissionState::Unknown);
        assert_eq!(
            owner.admission().reason(),
            Some(CellularAdmissionReason::NoObservation)
        );
        assert_eq!(owner.admission().admitted_network(), None);
    }

    #[test]
    fn admits_only_validated_direct_cellular_with_internet() {
        let mut owner = CellularEgress::new();

        owner.observe(observation(1, 11, true, true, true, true));

        assert_eq!(owner.admission().state(), CellularAdmissionState::Admitted);
        assert_eq!(owner.admission().reason(), None);
        assert_eq!(owner.admission().admitted_network(), Some(handle(11)));
    }

    #[test]
    fn rejects_cellular_without_validation() {
        let mut owner = CellularEgress::new();

        owner.observe(observation(1, 11, true, true, false, true));

        assert_eq!(
            owner.admission().state(),
            CellularAdmissionState::NotAdmitted
        );
        assert_eq!(
            owner.admission().reason(),
            Some(CellularAdmissionReason::NotValidated)
        );
        assert_eq!(owner.admission().admitted_network(), None);
    }

    #[test]
    fn rejects_vpn_derived_cellular_network() {
        let mut owner = CellularEgress::new();

        owner.observe(observation(1, 11, true, true, true, false));

        assert_eq!(
            owner.admission().state(),
            CellularAdmissionState::NotAdmitted
        );
        assert_eq!(
            owner.admission().reason(),
            Some(CellularAdmissionReason::VpnDerivedNetwork)
        );
        assert_eq!(owner.admission().admitted_network(), None);
    }

    #[test]
    fn rejects_validated_wifi() {
        let mut owner = CellularEgress::new();

        owner.observe(observation(1, 11, false, true, true, true));

        assert_eq!(
            owner.admission().state(),
            CellularAdmissionState::NotAdmitted
        );
        assert_eq!(
            owner.admission().reason(),
            Some(CellularAdmissionReason::NotCellular)
        );
        assert_eq!(owner.admission().admitted_network(), None);
    }

    #[test]
    fn losing_current_network_fails_closed() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true, true));

        owner.lost(sequence(2), handle(11));

        assert_eq!(
            owner.admission().state(),
            CellularAdmissionState::NotAdmitted
        );
        assert_eq!(
            owner.admission().reason(),
            Some(CellularAdmissionReason::NetworkLost)
        );
        assert_eq!(owner.admission().admitted_network(), None);
    }

    #[test]
    fn loss_of_superseded_network_cannot_evict_newer_network() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true, true));
        owner.observe(observation(2, 22, true, true, true, true));

        owner.lost(sequence(3), handle(11));

        assert_eq!(owner.admission().state(), CellularAdmissionState::Admitted);
        assert_eq!(owner.admission().admitted_network(), Some(handle(22)));
    }

    #[test]
    fn stale_observation_after_loss_is_ignored() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true, true));
        owner.lost(sequence(3), handle(11));

        let result = owner.observe(observation(2, 11, true, true, true, true));

        assert!(matches!(result, ApplyResult::IgnoredStale(_)));
        assert_eq!(
            owner.admission().state(),
            CellularAdmissionState::NotAdmitted
        );
        assert_eq!(owner.admission().admitted_network(), None);
    }

    #[test]
    fn validation_loss_on_current_handle_invalidates_it() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true, true));

        owner.observe(observation(2, 11, true, true, false, true));

        assert_eq!(
            owner.admission().state(),
            CellularAdmissionState::NotAdmitted
        );
        assert_eq!(
            owner.admission().reason(),
            Some(CellularAdmissionReason::NotValidated)
        );
        assert_eq!(owner.admission().admitted_network(), None);
    }

    #[test]
    fn vpn_provenance_change_on_current_handle_invalidates_it() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true, true));

        owner.observe(observation(2, 11, true, true, true, false));

        assert_eq!(
            owner.admission().state(),
            CellularAdmissionState::NotAdmitted
        );
        assert_eq!(
            owner.admission().reason(),
            Some(CellularAdmissionReason::VpnDerivedNetwork)
        );
        assert_eq!(owner.admission().admitted_network(), None);
    }

    #[test]
    fn unrelated_invalid_candidate_does_not_evict_current_network() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true, true));

        owner.observe(observation(2, 22, false, true, true, true));

        assert_eq!(owner.admission().state(), CellularAdmissionState::Admitted);
        assert_eq!(owner.admission().admitted_network(), Some(handle(11)));
        assert_eq!(owner.admission().last_sequence(), Some(sequence(2)));
    }

    #[test]
    fn authority_is_not_issued_without_admission() {
        let owner = CellularEgress::new();

        assert_eq!(
            owner.admitted_network_authority(),
            Err(CellularNetworkAuthorityError::NoAdmittedNetwork)
        );
    }

    #[test]
    fn authority_captures_exact_owner_generation() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 42, true, true, true, true));

        let authority = owner
            .admitted_network_authority()
            .expect("admitted authority");

        assert_eq!(authority.network_handle(), handle(42));
        assert_eq!(owner.validate_network_authority(authority), Ok(()));
    }

    #[test]
    fn reobservation_of_same_raw_handle_invalidates_old_authority() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 42, true, true, true, true));
        let authority = owner
            .admitted_network_authority()
            .expect("admitted authority");

        owner.observe(observation(2, 42, true, true, true, true));

        assert_eq!(
            owner.validate_network_authority(authority),
            Err(CellularNetworkAuthorityError::NetworkChanged)
        );
    }

    #[test]
    fn loss_invalidates_existing_authority() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 42, true, true, true, true));
        let authority = owner
            .admitted_network_authority()
            .expect("admitted authority");

        owner.lost(sequence(2), handle(42));

        assert_eq!(
            owner.validate_network_authority(authority),
            Err(CellularNetworkAuthorityError::NetworkChanged)
        );
    }
}
