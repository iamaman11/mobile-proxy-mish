//! Cellular Egress natural-owner capability.
//!
//! Owns validated cellular selection policy, cellular-scoped DNS semantics, socket
//! binding policy, and public-egress observations. Android platform objects do not
//! cross this boundary; the owner receives only typed ephemeral observations.

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

/// Platform observation presented to the Cellular Egress owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NetworkObservation {
    sequence: ObservationSequence,
    handle: NetworkHandle,
    is_cellular: bool,
    has_internet: bool,
    is_validated: bool,
}

impl NetworkObservation {
    /// Constructs one immutable platform observation.
    pub const fn new(
        sequence: ObservationSequence,
        handle: NetworkHandle,
        is_cellular: bool,
        has_internet: bool,
        is_validated: bool,
    ) -> Self {
        Self {
            sequence,
            handle,
            is_cellular,
            has_internet,
            is_validated,
        }
    }

    const fn rejection_reason(self) -> Option<CellularReason> {
        if !self.is_cellular {
            Some(CellularReason::NotCellular)
        } else if !self.has_internet {
            Some(CellularReason::MissingInternetCapability)
        } else if !self.is_validated {
            Some(CellularReason::NotValidated)
        } else {
            None
        }
    }
}

/// Owner-level readiness for the cellular egress capability only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularState {
    /// No fresh owner observation exists yet.
    Unknown,
    /// A fresh observation proves that cellular egress is not currently admissible.
    NotReady,
    /// A fresh validated cellular network is admitted.
    Ready,
}

/// Stable reason codes emitted by the Cellular Egress owner.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularReason {
    /// Startup/restart has not produced a fresh network observation yet.
    NoObservation,
    /// The observed candidate was not a cellular transport.
    NotCellular,
    /// The observed candidate lacked Android's INTERNET capability.
    MissingInternetCapability,
    /// The observed candidate lacked Android's VALIDATED capability.
    NotValidated,
    /// The currently admitted network was reported lost.
    NetworkLost,
}

/// Read-only projection of facts owned by Cellular Egress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularSnapshot {
    state: CellularState,
    reason: Option<CellularReason>,
    admitted_network: Option<NetworkHandle>,
    last_sequence: Option<ObservationSequence>,
}

impl CellularSnapshot {
    /// Current capability state.
    pub const fn state(self) -> CellularState {
        self.state
    }

    /// Typed reason when state is not ready/known.
    pub const fn reason(self) -> Option<CellularReason> {
        self.reason
    }

    /// Current admitted ephemeral network, when ready.
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
    Applied(CellularSnapshot),
    /// The event was stale/reordered and therefore could not mutate owner state.
    IgnoredStale(CellularSnapshot),
}

/// Single natural owner of admitted cellular-network state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularEgress {
    snapshot: CellularSnapshot,
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
            snapshot: CellularSnapshot {
                state: CellularState::Unknown,
                reason: Some(CellularReason::NoObservation),
                admitted_network: None,
                last_sequence: None,
            },
        }
    }

    /// Returns the current read-only owner projection.
    pub const fn snapshot(&self) -> CellularSnapshot {
        self.snapshot
    }

    /// Applies a fresh capabilities observation.
    ///
    /// An invalid observation for the *currently admitted* handle invalidates it
    /// immediately. An unrelated invalid candidate cannot evict an already-admitted
    /// validated cellular network.
    pub fn observe(&mut self, observation: NetworkObservation) -> ApplyResult {
        if self.is_stale(observation.sequence) {
            return ApplyResult::IgnoredStale(self.snapshot);
        }

        self.snapshot.last_sequence = Some(observation.sequence);

        if let Some(reason) = observation.rejection_reason() {
            let invalidates_current = self.snapshot.admitted_network.is_none()
                || self.snapshot.admitted_network == Some(observation.handle);

            if invalidates_current {
                self.snapshot.state = CellularState::NotReady;
                self.snapshot.reason = Some(reason);
                self.snapshot.admitted_network = None;
            }
        } else {
            self.snapshot.state = CellularState::Ready;
            self.snapshot.reason = None;
            self.snapshot.admitted_network = Some(observation.handle);
        }

        ApplyResult::Applied(self.snapshot)
    }

    /// Applies a platform `onLost`-equivalent event.
    ///
    /// Losing an old superseded handle cannot evict a newer admitted cellular network.
    pub fn lost(
        &mut self,
        sequence: ObservationSequence,
        handle: NetworkHandle,
    ) -> ApplyResult {
        if self.is_stale(sequence) {
            return ApplyResult::IgnoredStale(self.snapshot);
        }

        self.snapshot.last_sequence = Some(sequence);

        if self.snapshot.admitted_network == Some(handle) {
            self.snapshot.state = CellularState::NotReady;
            self.snapshot.reason = Some(CellularReason::NetworkLost);
            self.snapshot.admitted_network = None;
        } else if self.snapshot.state == CellularState::Unknown {
            self.snapshot.state = CellularState::NotReady;
            self.snapshot.reason = Some(CellularReason::NetworkLost);
        }

        ApplyResult::Applied(self.snapshot)
    }

    fn is_stale(&self, sequence: ObservationSequence) -> bool {
        matches!(self.snapshot.last_sequence, Some(last) if sequence <= last)
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
    ) -> NetworkObservation {
        NetworkObservation::new(
            sequence(seq),
            handle(network),
            is_cellular,
            has_internet,
            is_validated,
        )
    }

    #[test]
    fn starts_unknown_without_a_fresh_observation() {
        let owner = CellularEgress::new();

        assert_eq!(owner.snapshot().state(), CellularState::Unknown);
        assert_eq!(
            owner.snapshot().reason(),
            Some(CellularReason::NoObservation)
        );
        assert_eq!(owner.snapshot().admitted_network(), None);
    }

    #[test]
    fn admits_only_validated_cellular_with_internet() {
        let mut owner = CellularEgress::new();

        owner.observe(observation(1, 11, true, true, true));

        assert_eq!(owner.snapshot().state(), CellularState::Ready);
        assert_eq!(owner.snapshot().reason(), None);
        assert_eq!(owner.snapshot().admitted_network(), Some(handle(11)));
    }

    #[test]
    fn rejects_cellular_without_validation() {
        let mut owner = CellularEgress::new();

        owner.observe(observation(1, 11, true, true, false));

        assert_eq!(owner.snapshot().state(), CellularState::NotReady);
        assert_eq!(
            owner.snapshot().reason(),
            Some(CellularReason::NotValidated)
        );
        assert_eq!(owner.snapshot().admitted_network(), None);
    }

    #[test]
    fn rejects_validated_wifi() {
        let mut owner = CellularEgress::new();

        owner.observe(observation(1, 11, false, true, true));

        assert_eq!(owner.snapshot().state(), CellularState::NotReady);
        assert_eq!(owner.snapshot().reason(), Some(CellularReason::NotCellular));
        assert_eq!(owner.snapshot().admitted_network(), None);
    }

    #[test]
    fn losing_current_network_fails_closed() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true));

        owner.lost(sequence(2), handle(11));

        assert_eq!(owner.snapshot().state(), CellularState::NotReady);
        assert_eq!(
            owner.snapshot().reason(),
            Some(CellularReason::NetworkLost)
        );
        assert_eq!(owner.snapshot().admitted_network(), None);
    }

    #[test]
    fn loss_of_superseded_network_cannot_evict_newer_network() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true));
        owner.observe(observation(2, 22, true, true, true));

        owner.lost(sequence(3), handle(11));

        assert_eq!(owner.snapshot().state(), CellularState::Ready);
        assert_eq!(owner.snapshot().admitted_network(), Some(handle(22)));
    }

    #[test]
    fn stale_observation_after_loss_is_ignored() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true));
        owner.lost(sequence(3), handle(11));

        let result = owner.observe(observation(2, 11, true, true, true));

        assert!(matches!(result, ApplyResult::IgnoredStale(_)));
        assert_eq!(owner.snapshot().state(), CellularState::NotReady);
        assert_eq!(owner.snapshot().admitted_network(), None);
    }

    #[test]
    fn capability_loss_on_current_handle_invalidates_it() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true));

        owner.observe(observation(2, 11, true, true, false));

        assert_eq!(owner.snapshot().state(), CellularState::NotReady);
        assert_eq!(
            owner.snapshot().reason(),
            Some(CellularReason::NotValidated)
        );
        assert_eq!(owner.snapshot().admitted_network(), None);
    }

    #[test]
    fn unrelated_invalid_candidate_does_not_evict_current_network() {
        let mut owner = CellularEgress::new();
        owner.observe(observation(1, 11, true, true, true));

        owner.observe(observation(2, 22, false, true, true));

        assert_eq!(owner.snapshot().state(), CellularState::Ready);
        assert_eq!(owner.snapshot().admitted_network(), Some(handle(11)));
        assert_eq!(owner.snapshot().last_sequence(), Some(sequence(2)));
    }
}
