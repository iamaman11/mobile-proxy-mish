use crate::runtime_boundary::{AndroidRuntimeError, CellularController};
use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
use mish_runtime::{ProxyServingRuntime, ProxyServingRuntimeError};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::Duration;

#[derive(uniffi::Object)]
pub struct NativeProxyRuntime {
    inner: Arc<ProxyServingRuntime>,
}

#[uniffi::export]
impl NativeProxyRuntime {
    pub fn is_healthy(&self) -> bool {
        self.inner.is_healthy()
    }

    pub fn active_sessions(&self) -> u32 {
        self.inner.active_sessions().min(u32::MAX as usize) as u32
    }

    pub fn stop(&self) -> Result<(), AndroidRuntimeError> {
        self.inner.stop().map_err(map_proxy_runtime_error)
    }
}

/// Starts the canonical native Proxy Serving runtime against the exact same Cellular Egress owner
/// exposed through `cellular`. No private loopback hop or migration credential exists in L8.
#[uniffi::export]
pub fn start_native_proxy_runtime(
    cellular: Arc<CellularController>,
    public_username: String,
    public_password: String,
    operation_timeout_ms: u64,
) -> Result<Arc<NativeProxyRuntime>, AndroidRuntimeError> {
    let operation_timeout = Duration::from_millis(operation_timeout_ms);
    let connector = cellular
        .runtime_handle()
        .outbound_connector(operation_timeout)
        .map_err(AndroidRuntimeError::from)?;
    let public_credentials = ProxyCredentialMaterial::new(public_username, public_password)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let plan = ProxyServingPlan::canonical(IpAddr::V4(Ipv4Addr::LOCALHOST), public_credentials)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let inner =
        ProxyServingRuntime::start(plan, connector).map_err(map_proxy_runtime_error)?;
    Ok(Arc::new(NativeProxyRuntime { inner }))
}

#[uniffi::export]
pub fn proxy_listener_ports() -> Vec<u16> {
    vec![
        mish_proxy::MIXED_PROXY_PORT,
        mish_proxy::SOCKS5_PORT,
        mish_proxy::HTTP_CONNECT_PORT,
    ]
}

fn map_proxy_runtime_error(error: ProxyServingRuntimeError) -> AndroidRuntimeError {
    match error {
        ProxyServingRuntimeError::NonLoopbackListen => AndroidRuntimeError::InvalidListenAddress,
        ProxyServingRuntimeError::BindFailed => AndroidRuntimeError::ProxyConfigurationRejected,
        ProxyServingRuntimeError::ThreadUnavailable => AndroidRuntimeError::ThreadUnavailable,
        ProxyServingRuntimeError::StateUnavailable => AndroidRuntimeError::BridgeStateUnavailable,
        ProxyServingRuntimeError::ShutdownTimedOut => AndroidRuntimeError::ShutdownTimedOut,
    }
}
