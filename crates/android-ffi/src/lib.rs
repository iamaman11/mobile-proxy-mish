//! Narrow Rust <-> Kotlin / Android platform boundary.
//!
//! This crate exposes a small UniFFI surface over the Cellular Egress natural owner.
//! It does not own cellular policy; it validates foreign inputs, delegates all state
//! transitions to `mish-cellular`, and maps the owner's read-only projection to FFI DTOs.

use mish_cellular::{
    CellularAdmissionReason as OwnerAdmissionReason,
    CellularAdmissionSnapshot as OwnerAdmissionSnapshot,
    CellularAdmissionState as OwnerAdmissionState, CellularEgress, NetworkHandle,
    NetworkObservation, ObservationSequence,
};
use std::fmt;
use std::sync::{Arc, Mutex, MutexGuard};

uniffi::setup_scaffolding!();

/// Stable foreign representation of cellular network-admission state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellularAdmissionState {
    Unknown,
    NotAdmitted,
    Admitted,
}

/// Stable foreign representation of why no cellular network is admitted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellularAdmissionReason {
    NoObservation,
    NotCellular,
    MissingInternetCapability,
    NotValidated,
    NetworkLost,
}

/// Read-only FFI projection of the Cellular Egress owner's admission fact.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellularAdmissionView {
    pub state: CellularAdmissionState,
    pub reason: Option<CellularAdmissionReason>,
    pub admitted_network_handle: Option<u64>,
    pub last_sequence: Option<u64>,
}

/// Fail-closed errors at the foreign-input/owner boundary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum CellularBridgeError {
    InvalidObservationSequence,
    InvalidNetworkHandle,
    OwnerUnavailable,
}

impl fmt::Display for CellularBridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::InvalidObservationSequence => "observation sequence must be non-zero",
            Self::InvalidNetworkHandle => "Android network handle must be non-zero",
            Self::OwnerUnavailable => "Cellular Egress owner state is unavailable",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for CellularBridgeError {}

/// One runtime-scoped foreign handle to the Cellular Egress natural owner.
///
/// There is intentionally no global singleton. A later Runtime Lifecycle composition
/// step will own the lifetime of this object and the Android observer as one generation.
#[derive(uniffi::Object)]
pub struct CellularController {
    owner: Mutex<CellularEgress>,
}

#[uniffi::export]
impl CellularController {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            owner: Mutex::new(CellularEgress::new()),
        })
    }

    /// Returns the owner's current admission projection without inventing readiness.
    pub fn admission_snapshot(&self) -> Result<CellularAdmissionView, CellularBridgeError> {
        Ok(map_snapshot(self.owner()?.admission()))
    }

    /// Applies one typed Android capabilities observation to the natural owner.
    pub fn observe_network(
        &self,
        sequence: u64,
        network_handle: u64,
        is_cellular: bool,
        has_internet: bool,
        is_validated: bool,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        let sequence = ObservationSequence::new(sequence)
            .ok_or(CellularBridgeError::InvalidObservationSequence)?;
        let network_handle =
            NetworkHandle::new(network_handle).ok_or(CellularBridgeError::InvalidNetworkHandle)?;

        let observation = NetworkObservation::new(
            sequence,
            network_handle,
            is_cellular,
            has_internet,
            is_validated,
        );

        let mut owner = self.owner()?;
        owner.observe(observation);
        Ok(map_snapshot(owner.admission()))
    }

    /// Applies one typed Android `NetworkCallback.onLost` event to the natural owner.
    pub fn network_lost(
        &self,
        sequence: u64,
        network_handle: u64,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        let sequence = ObservationSequence::new(sequence)
            .ok_or(CellularBridgeError::InvalidObservationSequence)?;
        let network_handle =
            NetworkHandle::new(network_handle).ok_or(CellularBridgeError::InvalidNetworkHandle)?;

        let mut owner = self.owner()?;
        owner.lost(sequence, network_handle);
        Ok(map_snapshot(owner.admission()))
    }
}

impl CellularController {
    fn owner(&self) -> Result<MutexGuard<'_, CellularEgress>, CellularBridgeError> {
        self.owner
            .lock()
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }
}

fn map_snapshot(snapshot: OwnerAdmissionSnapshot) -> CellularAdmissionView {
    CellularAdmissionView {
        state: match snapshot.state() {
            OwnerAdmissionState::Unknown => CellularAdmissionState::Unknown,
            OwnerAdmissionState::NotAdmitted => CellularAdmissionState::NotAdmitted,
            OwnerAdmissionState::Admitted => CellularAdmissionState::Admitted,
        },
        reason: snapshot.reason().map(|reason| match reason {
            OwnerAdmissionReason::NoObservation => CellularAdmissionReason::NoObservation,
            OwnerAdmissionReason::NotCellular => CellularAdmissionReason::NotCellular,
            OwnerAdmissionReason::MissingInternetCapability => {
                CellularAdmissionReason::MissingInternetCapability
            }
            OwnerAdmissionReason::NotValidated => CellularAdmissionReason::NotValidated,
            OwnerAdmissionReason::NetworkLost => CellularAdmissionReason::NetworkLost,
        }),
        admitted_network_handle: snapshot.admitted_network().map(NetworkHandle::raw),
        last_sequence: snapshot.last_sequence().map(ObservationSequence::raw),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foreign_controller_starts_unknown() {
        let controller = CellularController::new();

        assert_eq!(
            controller.admission_snapshot().expect("snapshot"),
            CellularAdmissionView {
                state: CellularAdmissionState::Unknown,
                reason: Some(CellularAdmissionReason::NoObservation),
                admitted_network_handle: None,
                last_sequence: None,
            }
        );
    }

    #[test]
    fn foreign_observation_delegates_admission_to_natural_owner() {
        let controller = CellularController::new();

        let view = controller
            .observe_network(1, 42, true, true, true)
            .expect("valid observation");

        assert_eq!(view.state, CellularAdmissionState::Admitted);
        assert_eq!(view.reason, None);
        assert_eq!(view.admitted_network_handle, Some(42));
        assert_eq!(view.last_sequence, Some(1));
    }

    #[test]
    fn foreign_loss_fails_closed_through_natural_owner() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true)
            .expect("valid observation");

        let view = controller.network_lost(2, 42).expect("valid loss event");

        assert_eq!(view.state, CellularAdmissionState::NotAdmitted);
        assert_eq!(view.reason, Some(CellularAdmissionReason::NetworkLost));
        assert_eq!(view.admitted_network_handle, None);
        assert_eq!(view.last_sequence, Some(2));
    }

    #[test]
    fn zero_foreign_values_are_rejected_before_owner_mutation() {
        let controller = CellularController::new();

        assert_eq!(
            controller.observe_network(0, 42, true, true, true),
            Err(CellularBridgeError::InvalidObservationSequence)
        );
        assert_eq!(
            controller.observe_network(1, 0, true, true, true),
            Err(CellularBridgeError::InvalidNetworkHandle)
        );
        assert_eq!(
            controller.admission_snapshot().expect("snapshot").state,
            CellularAdmissionState::Unknown
        );
    }
}
