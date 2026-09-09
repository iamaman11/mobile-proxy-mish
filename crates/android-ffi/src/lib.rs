//! Narrow Rust <-> Kotlin / Android platform boundary.
//!
//! This crate exposes a small UniFFI surface over the Cellular Egress natural owner.
//! It does not own cellular policy; it validates foreign inputs, delegates all state
//! transitions to `mish-cellular`, and maps the owner's read-only projection to FFI DTOs.

#[cfg(target_os = "android")]
#[allow(unsafe_code)]
mod android_explicit_network;

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

/// Fail-closed errors for explicit-network socket/DNS operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum CellularNetworkOperationError {
    NoAdmittedNetwork,
    InvalidSocketFd,
    InvalidHostname,
    NativeSocketBindFailed,
    NativeDnsLookupFailed,
    NativeDnsNoResults,
    NativeAddressConversionFailed,
    NetworkChangedDuringOperation,
    UnsupportedPlatform,
    OwnerUnavailable,
}

impl fmt::Display for CellularNetworkOperationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::NoAdmittedNetwork => "no cellular network is currently admitted",
            Self::InvalidSocketFd => "socket file descriptor must be non-negative",
            Self::InvalidHostname => "hostname must be non-empty and contain no NUL byte",
            Self::NativeSocketBindFailed => "Android explicit-network socket binding failed",
            Self::NativeDnsLookupFailed => "Android explicit-network DNS lookup failed",
            Self::NativeDnsNoResults => "Android explicit-network DNS lookup returned no addresses",
            Self::NativeAddressConversionFailed => {
                "Android explicit-network DNS address conversion failed"
            }
            Self::NetworkChangedDuringOperation => {
                "cellular network authority changed during the operation"
            }
            Self::UnsupportedPlatform => "explicit-network operation requires Android",
            Self::OwnerUnavailable => "Cellular Egress owner state is unavailable",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for CellularNetworkOperationError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct AdmissionLease {
    network: NetworkHandle,
    sequence: ObservationSequence,
}

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

    /// Binds an existing socket to the exact network currently admitted by the owner.
    ///
    /// The caller supplies only the socket fd. It cannot choose or override the Android
    /// network handle, preventing a second network-selection path outside `mish-cellular`.
    pub fn bind_socket_to_admitted_network(
        &self,
        socket_fd: i32,
    ) -> Result<(), CellularNetworkOperationError> {
        if socket_fd < 0 {
            return Err(CellularNetworkOperationError::InvalidSocketFd);
        }

        self.execute_admitted_network_operation(|network| {
            bind_socket_on_platform(network, socket_fd)
        })
    }

    /// Resolves a hostname using DNS associated with the exact admitted cellular Network.
    ///
    /// Returned values are numeric IP strings; the native adapter explicitly suppresses
    /// any second reverse-DNS lookup while converting the NDK result list.
    pub fn resolve_host_on_admitted_network(
        &self,
        hostname: String,
    ) -> Result<Vec<String>, CellularNetworkOperationError> {
        if hostname.is_empty() || hostname.as_bytes().contains(&0) {
            return Err(CellularNetworkOperationError::InvalidHostname);
        }

        self.execute_admitted_network_operation(|network| {
            resolve_host_on_platform(network, &hostname)
        })
    }
}

impl CellularController {
    fn owner(&self) -> Result<MutexGuard<'_, CellularEgress>, CellularBridgeError> {
        self.owner
            .lock()
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }

    fn owner_for_operation(
        &self,
    ) -> Result<MutexGuard<'_, CellularEgress>, CellularNetworkOperationError> {
        self.owner
            .lock()
            .map_err(|_| CellularNetworkOperationError::OwnerUnavailable)
    }

    fn current_admission_lease(&self) -> Result<AdmissionLease, CellularNetworkOperationError> {
        let snapshot = self.owner_for_operation()?.admission();
        if snapshot.state() != OwnerAdmissionState::Admitted {
            return Err(CellularNetworkOperationError::NoAdmittedNetwork);
        }

        let network = snapshot
            .admitted_network()
            .ok_or(CellularNetworkOperationError::NoAdmittedNetwork)?;
        let sequence = snapshot
            .last_sequence()
            .ok_or(CellularNetworkOperationError::NoAdmittedNetwork)?;

        Ok(AdmissionLease { network, sequence })
    }

    fn ensure_admission_lease_current(
        &self,
        lease: AdmissionLease,
    ) -> Result<(), CellularNetworkOperationError> {
        let snapshot = self.owner_for_operation()?.admission();
        let unchanged = snapshot.state() == OwnerAdmissionState::Admitted
            && snapshot.admitted_network() == Some(lease.network)
            && snapshot.last_sequence() == Some(lease.sequence);

        if unchanged {
            Ok(())
        } else {
            Err(CellularNetworkOperationError::NetworkChangedDuringOperation)
        }
    }

    fn execute_admitted_network_operation<T>(
        &self,
        operation: impl FnOnce(NetworkHandle) -> Result<T, CellularNetworkOperationError>,
    ) -> Result<T, CellularNetworkOperationError> {
        let lease = self.current_admission_lease()?;
        let result = operation(lease.network)?;
        self.ensure_admission_lease_current(lease)?;
        Ok(result)
    }
}

#[cfg(target_os = "android")]
fn bind_socket_on_platform(
    network: NetworkHandle,
    socket_fd: i32,
) -> Result<(), CellularNetworkOperationError> {
    android_explicit_network::bind_socket(network, socket_fd)
}

#[cfg(not(target_os = "android"))]
fn bind_socket_on_platform(
    network: NetworkHandle,
    socket_fd: i32,
) -> Result<(), CellularNetworkOperationError> {
    let _ = (network, socket_fd);
    Err(CellularNetworkOperationError::UnsupportedPlatform)
}

#[cfg(target_os = "android")]
fn resolve_host_on_platform(
    network: NetworkHandle,
    hostname: &str,
) -> Result<Vec<String>, CellularNetworkOperationError> {
    android_explicit_network::resolve_host(network, hostname)
}

#[cfg(not(target_os = "android"))]
fn resolve_host_on_platform(
    network: NetworkHandle,
    hostname: &str,
) -> Result<Vec<String>, CellularNetworkOperationError> {
    let _ = (network, hostname);
    Err(CellularNetworkOperationError::UnsupportedPlatform)
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
    use std::cell::Cell;

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

    #[test]
    fn explicit_network_operation_is_not_invoked_without_owner_admission() {
        let controller = CellularController::new();
        let invoked = Cell::new(false);

        let result = controller.execute_admitted_network_operation(|_| {
            invoked.set(true);
            Ok(())
        });

        assert_eq!(
            result,
            Err(CellularNetworkOperationError::NoAdmittedNetwork)
        );
        assert!(!invoked.get());
    }

    #[test]
    fn explicit_network_operation_receives_only_the_owner_admitted_handle() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true)
            .expect("valid observation");

        let result = controller.execute_admitted_network_operation(|network| {
            assert_eq!(network.raw(), 42);
            Ok("bound")
        });

        assert_eq!(result, Ok("bound"));
    }

    #[test]
    fn explicit_network_operation_rejects_success_after_owner_change() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true)
            .expect("valid observation");
        let controller_for_operation = Arc::clone(&controller);

        let result = controller.execute_admitted_network_operation(|network| {
            assert_eq!(network.raw(), 42);
            controller_for_operation
                .network_lost(2, 42)
                .expect("loss observation");
            Ok(())
        });

        assert_eq!(
            result,
            Err(CellularNetworkOperationError::NetworkChangedDuringOperation)
        );
    }

    #[test]
    fn explicit_network_operation_rejects_reobserved_same_handle_as_new_authority() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true)
            .expect("valid observation");
        let controller_for_operation = Arc::clone(&controller);

        let result = controller.execute_admitted_network_operation(|network| {
            assert_eq!(network.raw(), 42);
            controller_for_operation
                .observe_network(2, 42, true, true, true)
                .expect("fresh observation");
            Ok(())
        });

        assert_eq!(
            result,
            Err(CellularNetworkOperationError::NetworkChangedDuringOperation)
        );
    }

    #[test]
    fn invalid_public_operation_inputs_fail_before_platform_access() {
        let controller = CellularController::new();

        assert_eq!(
            controller.bind_socket_to_admitted_network(-1),
            Err(CellularNetworkOperationError::InvalidSocketFd)
        );
        assert_eq!(
            controller.resolve_host_on_admitted_network(String::new()),
            Err(CellularNetworkOperationError::InvalidHostname)
        );
        assert_eq!(
            controller.resolve_host_on_admitted_network("bad\0host".to_owned()),
            Err(CellularNetworkOperationError::InvalidHostname)
        );
    }
}
