//! Narrow Rust <-> Kotlin / Android composition boundary.
//!
//! This module contains only typed FFI projection/mapping plus the concrete Android DNS effect
//! adapter. Cellular admission, root-policy effect coordination and private-bridge runtime state
//! live behind public `mish-cellular` / `mish-runtime` APIs rather than inside the FFI seam.

use mish_android_network::AndroidNetworkError;
use mish_cellular::{
    CellularAdmissionReason as OwnerAdmissionReason,
    CellularAdmissionSnapshot as OwnerAdmissionSnapshot,
    CellularAdmissionState as OwnerAdmissionState, CellularNetworkAuthority, NetworkHandle,
    NetworkObservation, ObservationSequence,
};
use mish_cellular_egress_bridge::OutboundConnectError;
use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
use mish_runtime::{
    CellularDnsResolver, CellularPrivateBridgeRuntime, CellularRuntimeCoordinator,
    CellularRuntimeError,
};
use mish_sing_box_adapter::{PrivateSocks5Endpoint, render_product_config};
use std::fmt;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::Duration;

uniffi::setup_scaffolding!();

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellularAdmissionState {
    Unknown,
    NotAdmitted,
    Admitted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellularAdmissionReason {
    NoObservation,
    NotCellular,
    MissingInternetCapability,
    VpnDerivedNetwork,
    NotValidated,
    NetworkLost,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellularAdmissionView {
    pub state: CellularAdmissionState,
    pub reason: Option<CellularAdmissionReason>,
    pub admitted_network_handle: Option<u64>,
    pub last_sequence: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum CellularBridgeError {
    InvalidObservationSequence,
    InvalidNetworkHandle,
    OwnerUnavailable,
}

impl fmt::Display for CellularBridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidObservationSequence => "observation sequence must be non-zero",
            Self::InvalidNetworkHandle => "Android network handle must be non-zero",
            Self::OwnerUnavailable => "Cellular Egress owner state is unavailable",
        })
    }
}

impl std::error::Error for CellularBridgeError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum AndroidRuntimeError {
    InvalidOperationTimeout,
    BridgeAlreadyRunning,
    BridgeConfigurationRejected,
    BridgeBindFailed,
    ConnectorUnavailable,
    ThreadUnavailable,
    BridgeStateUnavailable,
    ShutdownTimedOut,
    InvalidListenAddress,
    ProxyConfigurationRejected,
}

impl fmt::Display for AndroidRuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidOperationTimeout => {
                "bridge operation timeout is outside the accepted range"
            }
            Self::BridgeAlreadyRunning => {
                "a private bridge already belongs to this owner generation"
            }
            Self::BridgeConfigurationRejected => "private bridge configuration was rejected",
            Self::BridgeBindFailed => "private bridge could not bind loopback",
            Self::ConnectorUnavailable => "cellular outbound connector could not start",
            Self::ThreadUnavailable => "bounded bridge worker thread could not start",
            Self::BridgeStateUnavailable => "private bridge state is unavailable",
            Self::ShutdownTimedOut => {
                "private bridge sessions did not stop within the bounded timeout"
            }
            Self::InvalidListenAddress => "public proxy listen address is invalid",
            Self::ProxyConfigurationRejected => "proxy runtime configuration was rejected",
        })
    }
}

impl std::error::Error for AndroidRuntimeError {}

#[derive(Debug, Clone, Copy)]
struct AndroidDnsResolver;

impl CellularDnsResolver for AndroidDnsResolver {
    fn resolve(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
    ) -> Result<Vec<IpAddr>, OutboundConnectError> {
        mish_android_network::resolve_host(authority, hostname)
            .map_err(map_android_network_error)?
            .into_iter()
            .map(|raw| {
                raw.parse::<IpAddr>()
                    .map_err(|_| OutboundConnectError::Failed)
            })
            .collect()
    }
}

/// Typed FFI wrapper over one vendor-neutral Rust runtime coordinator.
#[derive(uniffi::Object)]
pub struct CellularController {
    runtime: Arc<CellularRuntimeCoordinator>,
}

#[uniffi::export]
impl CellularController {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            runtime: CellularRuntimeCoordinator::new(Arc::new(AndroidDnsResolver)),
        })
    }

    pub fn admission_snapshot(&self) -> Result<CellularAdmissionView, CellularBridgeError> {
        self.runtime
            .admission_snapshot()
            .map(map_snapshot)
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }

    pub fn close_root_policy_gate(&self) -> Result<(), AndroidRuntimeError> {
        self.runtime.close_root_policy_gate().map_err(Into::into)
    }

    pub fn await_root_policy_quiesced(&self, timeout_ms: u64) -> Result<bool, AndroidRuntimeError> {
        self.runtime
            .await_root_policy_quiesced(Duration::from_millis(timeout_ms))
            .map_err(Into::into)
    }

    pub fn authorize_root_policy(
        &self,
        sequence: u64,
        network_handle: u64,
    ) -> Result<bool, AndroidRuntimeError> {
        let Some(sequence) = ObservationSequence::new(sequence) else {
            return Ok(false);
        };
        let Some(network_handle) = NetworkHandle::new(network_handle) else {
            return Ok(false);
        };
        self.runtime
            .authorize_root_policy(sequence, network_handle)
            .map_err(Into::into)
    }

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
        self.runtime
            .observe_network(observation)
            .map(map_snapshot)
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }

    pub fn network_lost(
        &self,
        sequence: u64,
        network_handle: u64,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        let sequence = ObservationSequence::new(sequence)
            .ok_or(CellularBridgeError::InvalidObservationSequence)?;
        let network_handle =
            NetworkHandle::new(network_handle).ok_or(CellularBridgeError::InvalidNetworkHandle)?;
        self.runtime
            .network_lost(sequence, network_handle)
            .map(map_snapshot)
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }

    pub fn start_bridge(
        &self,
        username: String,
        password: String,
        operation_timeout_ms: u64,
    ) -> Result<Arc<CellularBridgeRuntime>, AndroidRuntimeError> {
        let inner = self
            .runtime
            .start_private_bridge(
                username,
                password,
                Duration::from_millis(operation_timeout_ms),
            )
            .map_err(AndroidRuntimeError::from)?;
        Ok(Arc::new(CellularBridgeRuntime { inner }))
    }
}

/// Stateless UniFFI handle for a runtime-owned private bridge generation.
#[derive(uniffi::Object)]
pub struct CellularBridgeRuntime {
    inner: Arc<CellularPrivateBridgeRuntime>,
}

#[uniffi::export]
impl CellularBridgeRuntime {
    pub fn port(&self) -> u16 {
        self.inner.port()
    }

    pub fn is_healthy(&self) -> bool {
        self.inner.is_healthy()
    }

    pub fn active_sessions(&self) -> u32 {
        self.inner.active_sessions().min(u32::MAX as usize) as u32
    }

    pub fn stop(&self) -> Result<(), AndroidRuntimeError> {
        self.inner.stop().map_err(Into::into)
    }
}

#[uniffi::export]
pub fn render_proxy_runtime_config(
    listen_address: String,
    public_username: String,
    public_password: String,
    bridge_port: u16,
    bridge_username: String,
    bridge_password: String,
) -> Result<String, AndroidRuntimeError> {
    let listen_address = listen_address
        .parse::<IpAddr>()
        .map_err(|_| AndroidRuntimeError::InvalidListenAddress)?;
    let public_credentials = ProxyCredentialMaterial::new(public_username, public_password)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let plan = ProxyServingPlan::canonical(listen_address, public_credentials)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let egress = PrivateSocks5Endpoint::new(
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        bridge_port,
        bridge_username,
        bridge_password,
    )
    .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    render_product_config(&plan, &egress)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)
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

fn map_android_network_error(error: AndroidNetworkError) -> OutboundConnectError {
    match error {
        AndroidNetworkError::InvalidHostname => OutboundConnectError::Rejected,
        AndroidNetworkError::UnsupportedPlatform => OutboundConnectError::Unavailable,
        AndroidNetworkError::NativeDnsLookupFailed
        | AndroidNetworkError::NativeDnsNoResults
        | AndroidNetworkError::NativeAddressConversionFailed => OutboundConnectError::Failed,
    }
}

impl From<CellularRuntimeError> for AndroidRuntimeError {
    fn from(error: CellularRuntimeError) -> Self {
        match error {
            CellularRuntimeError::InvalidOperationTimeout => Self::InvalidOperationTimeout,
            CellularRuntimeError::BridgeAlreadyRunning => Self::BridgeAlreadyRunning,
            CellularRuntimeError::BridgeConfigurationRejected => Self::BridgeConfigurationRejected,
            CellularRuntimeError::BridgeBindFailed => Self::BridgeBindFailed,
            CellularRuntimeError::ConnectorUnavailable => Self::ConnectorUnavailable,
            CellularRuntimeError::ThreadUnavailable => Self::ThreadUnavailable,
            CellularRuntimeError::StateUnavailable => Self::BridgeStateUnavailable,
            CellularRuntimeError::ShutdownTimedOut => Self::ShutdownTimedOut,
        }
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
            .observe_network(1, 42, true, true, true, true)
            .expect("valid observation");
        assert_eq!(view.state, CellularAdmissionState::Admitted);
        assert_eq!(view.admitted_network_handle, Some(42));
    }

    #[test]
    fn stale_generation_cannot_reopen_root_policy_effect_gate() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true, true)
            .expect("first observation");
        assert!(controller.authorize_root_policy(1, 42).expect("authorize"));
        controller
            .observe_network(2, 43, true, true, true, true)
            .expect("newer observation");
        assert!(!controller.authorize_root_policy(1, 42).expect("stale"));
    }

    #[test]
    fn rendered_proxy_runtime_is_loopback_only_and_has_no_direct_fallback() {
        let rendered = render_proxy_runtime_config(
            "127.0.0.1".into(),
            "public-user".into(),
            "public-secret".into(),
            19080,
            "private-user".into(),
            "private-secret".into(),
        )
        .expect("render proxy runtime");
        for port in [1080, 1081, 3128] {
            assert!(rendered.contains(&format!("\"listen_port\": {port}")));
        }
        assert!(rendered.contains("\"listen\": \"127.0.0.1\""));
        assert!(!rendered.contains("\"type\": \"direct\""));
    }
}
