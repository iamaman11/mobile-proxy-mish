//! Narrow Rust <-> Kotlin / Android platform boundary.
//!
//! This crate exposes a small UniFFI surface over the Cellular Egress natural owner.
//! It does not own cellular policy; it validates foreign inputs, delegates all state
//! transitions to `mish-cellular`, and maps the owner's read-only projection to FFI DTOs.

use mish_android_network::AndroidNetworkError;
use mish_cellular::{
    CellularAdmissionReason as OwnerAdmissionReason,
    CellularAdmissionSnapshot as OwnerAdmissionSnapshot,
    CellularAdmissionState as OwnerAdmissionState, CellularEgress, CellularNetworkAuthority,
    CellularNetworkAuthorityError, NetworkHandle, NetworkObservation, ObservationSequence,
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
    VpnDerivedNetwork,
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
                "cellular network authority changed since this lease was issued"
            }
            Self::UnsupportedPlatform => "explicit-network operation requires Android",
            Self::OwnerUnavailable => "Cellular Egress owner state is unavailable",
        };
        formatter.write_str(message)
    }
}

impl std::error::Error for CellularNetworkOperationError {}

/// One runtime-scoped foreign handle to the Cellular Egress natural owner.
///
/// There is intentionally no global singleton. A later Runtime Lifecycle composition
/// step will own the lifetime of this object and the Android observer as one generation.
#[derive(uniffi::Object)]
pub struct CellularController {
    owner: Arc<Mutex<CellularEgress>>,
}

/// Opaque capability token for one exact owner-admitted cellular authority generation.
///
/// The network handle is deliberately not exposed. DNS and socket binding performed
/// through the same lease are therefore coupled to the same `(NetworkHandle, sequence)`.
/// A fresh owner observation invalidates the lease, even when Android reuses the same
/// raw handle value.
#[derive(uniffi::Object)]
pub struct CellularNetworkLease {
    owner: Arc<Mutex<CellularEgress>>,
    authority: CellularNetworkAuthority,
}

#[uniffi::export]
impl CellularController {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            owner: Arc::new(Mutex::new(CellularEgress::new())),
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
        is_not_vpn: bool,
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
            is_not_vpn,
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

    /// Issues an opaque lease for the exact cellular authority currently admitted.
    ///
    /// No lease is produced for UNKNOWN/NOT_ADMITTED state, and callers cannot choose
    /// or override the Android network handle carried by the lease.
    pub fn admitted_network_lease(
        &self,
    ) -> Result<Arc<CellularNetworkLease>, CellularNetworkOperationError> {
        let authority = self
            .owner_for_operation()?
            .admitted_network_authority()
            .map_err(map_authority_error)?;
        Ok(Arc::new(CellularNetworkLease {
            owner: Arc::clone(&self.owner),
            authority,
        }))
    }
}

#[uniffi::export]
impl CellularNetworkLease {
    /// Binds an existing socket to this lease's exact owner-admitted Android Network.
    pub fn bind_socket(&self, socket_fd: i32) -> Result<(), CellularNetworkOperationError> {
        if socket_fd < 0 {
            return Err(CellularNetworkOperationError::InvalidSocketFd);
        }

        self.execute_operation(|authority| {
            mish_android_network::bind_socket(authority, socket_fd)
                .map_err(map_android_network_error)
        })
    }

    /// Resolves a hostname using DNS associated with this lease's exact Android Network.
    ///
    /// Returned values are numeric IP strings; the native adapter explicitly suppresses
    /// any second reverse-DNS lookup while converting the NDK result list.
    pub fn resolve_host(
        &self,
        hostname: String,
    ) -> Result<Vec<String>, CellularNetworkOperationError> {
        if hostname.is_empty() || hostname.as_bytes().contains(&0) {
            return Err(CellularNetworkOperationError::InvalidHostname);
        }

        self.execute_operation(|authority| {
            mish_android_network::resolve_host(authority, &hostname)
                .map_err(map_android_network_error)
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
}

impl CellularNetworkLease {
    fn owner_for_operation(
        &self,
    ) -> Result<MutexGuard<'_, CellularEgress>, CellularNetworkOperationError> {
        self.owner
            .lock()
            .map_err(|_| CellularNetworkOperationError::OwnerUnavailable)
    }

    fn ensure_current(&self) -> Result<(), CellularNetworkOperationError> {
        self.owner_for_operation()?
            .validate_network_authority(self.authority)
            .map_err(map_authority_error)
    }

    fn execute_operation<T>(
        &self,
        operation: impl FnOnce(CellularNetworkAuthority) -> Result<T, CellularNetworkOperationError>,
    ) -> Result<T, CellularNetworkOperationError> {
        self.ensure_current()?;
        let result = operation(self.authority)?;
        self.ensure_current()?;
        Ok(result)
    }
}

fn map_authority_error(error: CellularNetworkAuthorityError) -> CellularNetworkOperationError {
    match error {
        CellularNetworkAuthorityError::NoAdmittedNetwork => {
            CellularNetworkOperationError::NoAdmittedNetwork
        }
        CellularNetworkAuthorityError::NetworkChanged => {
            CellularNetworkOperationError::NetworkChangedDuringOperation
        }
    }
}

fn map_android_network_error(error: AndroidNetworkError) -> CellularNetworkOperationError {
    match error {
        AndroidNetworkError::InvalidSocketFd => CellularNetworkOperationError::InvalidSocketFd,
        AndroidNetworkError::InvalidHostname => CellularNetworkOperationError::InvalidHostname,
        AndroidNetworkError::NativeSocketBindFailed => {
            CellularNetworkOperationError::NativeSocketBindFailed
        }
        AndroidNetworkError::NativeDnsLookupFailed => {
            CellularNetworkOperationError::NativeDnsLookupFailed
        }
        AndroidNetworkError::NativeDnsNoResults => {
            CellularNetworkOperationError::NativeDnsNoResults
        }
        AndroidNetworkError::NativeAddressConversionFailed => {
            CellularNetworkOperationError::NativeAddressConversionFailed
        }
        AndroidNetworkError::UnsupportedPlatform => {
            CellularNetworkOperationError::UnsupportedPlatform
        }
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
            OwnerAdmissionReason::VpnDerivedNetwork => CellularAdmissionReason::VpnDerivedNetwork,
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
            .observe_network(1, 42, true, true, true, true)
            .expect("valid observation");

        assert_eq!(view.state, CellularAdmissionState::Admitted);
        assert_eq!(view.reason, None);
        assert_eq!(view.admitted_network_handle, Some(42));
        assert_eq!(view.last_sequence, Some(1));
    }

    #[test]
    fn vpn_derived_observation_is_rejected_by_natural_owner() {
        let controller = CellularController::new();

        let view = controller
            .observe_network(1, 42, true, true, true, false)
            .expect("valid observation");

        assert_eq!(view.state, CellularAdmissionState::NotAdmitted);
        assert_eq!(
            view.reason,
            Some(CellularAdmissionReason::VpnDerivedNetwork)
        );
        assert_eq!(view.admitted_network_handle, None);
    }

    #[test]
    fn foreign_loss_fails_closed_through_natural_owner() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true, true)
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
            controller.observe_network(0, 42, true, true, true, true),
            Err(CellularBridgeError::InvalidObservationSequence)
        );
        assert_eq!(
            controller.observe_network(1, 0, true, true, true, true),
            Err(CellularBridgeError::InvalidNetworkHandle)
        );
        assert_eq!(
            controller.admission_snapshot().expect("snapshot").state,
            CellularAdmissionState::Unknown
        );
    }

    #[test]
    fn lease_is_not_issued_without_owner_admission() {
        let controller = CellularController::new();

        assert!(matches!(
            controller.admitted_network_lease(),
            Err(CellularNetworkOperationError::NoAdmittedNetwork)
        ));
    }

    #[test]
    fn lease_operation_receives_only_the_captured_owner_handle() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true, true)
            .expect("valid observation");
        let lease = controller.admitted_network_lease().expect("admitted lease");

        let result = lease.execute_operation(|authority| {
            assert_eq!(authority.network_handle().raw(), 42);
            Ok("bound")
        });

        assert_eq!(result, Ok("bound"));
    }

    #[test]
    fn stale_lease_refuses_operation_before_platform_invocation() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true, true)
            .expect("valid observation");
        let lease = controller.admitted_network_lease().expect("admitted lease");
        controller
            .observe_network(2, 42, true, true, true, true)
            .expect("fresh observation");
        let invoked = Cell::new(false);

        let result = lease.execute_operation(|_| {
            invoked.set(true);
            Ok(())
        });

        assert_eq!(
            result,
            Err(CellularNetworkOperationError::NetworkChangedDuringOperation)
        );
        assert!(!invoked.get());
    }

    #[test]
    fn lease_rejects_success_when_owner_changes_during_operation() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true, true)
            .expect("valid observation");
        let lease = controller.admitted_network_lease().expect("admitted lease");
        let controller_for_operation = Arc::clone(&controller);

        let result = lease.execute_operation(|authority| {
            assert_eq!(authority.network_handle().raw(), 42);
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
    fn invalid_lease_operation_inputs_fail_before_platform_access() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true, true)
            .expect("valid observation");
        let lease = controller.admitted_network_lease().expect("admitted lease");

        assert_eq!(
            lease.bind_socket(-1),
            Err(CellularNetworkOperationError::InvalidSocketFd)
        );
        assert_eq!(
            lease.resolve_host(String::new()),
            Err(CellularNetworkOperationError::InvalidHostname)
        );
        assert_eq!(
            lease.resolve_host("bad\0host".to_owned()),
            Err(CellularNetworkOperationError::InvalidHostname)
        );
    }
}
