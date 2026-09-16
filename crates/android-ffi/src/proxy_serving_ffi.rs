use crate::runtime_boundary::{AndroidRuntimeError, CellularController};
use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
use mish_runtime::{ProxyServingRuntime, ProxyServingRuntimeError};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::Duration;

const MAX_OUTBOUND_OPERATION_TIMEOUT_MS: u64 = 15_000;

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

/// Starts Proxy Serving directly against the exact Cellular Egress owner held by `cellular`.
#[uniffi::export]
pub fn start_native_proxy_runtime(
    cellular: Arc<CellularController>,
    public_username: String,
    public_password: String,
    operation_timeout_ms: u64,
) -> Result<Arc<NativeProxyRuntime>, AndroidRuntimeError> {
    if operation_timeout_ms == 0 || operation_timeout_ms > MAX_OUTBOUND_OPERATION_TIMEOUT_MS {
        return Err(AndroidRuntimeError::InvalidOperationTimeout);
    }
    let public_credentials = ProxyCredentialMaterial::new(public_username, public_password)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let plan = ProxyServingPlan::canonical(IpAddr::V4(Ipv4Addr::LOCALHOST), public_credentials)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let connector = cellular
        .runtime_handle()
        .outbound_connector(Duration::from_millis(operation_timeout_ms))
        .map_err(AndroidRuntimeError::from)?;
    let inner = ProxyServingRuntime::start(plan, connector).map_err(map_proxy_runtime_error)?;
    Ok(Arc::new(NativeProxyRuntime { inner }))
}

#[uniffi::export]
pub fn proxy_listener_ports() -> Vec<u16> {
    vec![mish_proxy::MIXED_PORT, mish_proxy::SOCKS5_PORT, mish_proxy::HTTP_CONNECT_PORT]
}

fn map_proxy_runtime_error(error: ProxyServingRuntimeError) -> AndroidRuntimeError {
    match error {
        ProxyServingRuntimeError::NonLoopbackListen => AndroidRuntimeError::InvalidListenAddress,
        ProxyServingRuntimeError::BindFailed => AndroidRuntimeError::ProxyConfigurationRejected,
        ProxyServingRuntimeError::ThreadUnavailable => AndroidRuntimeError::ThreadUnavailable,
        ProxyServingRuntimeError::StateUnavailable => AndroidRuntimeError::RuntimeStateUnavailable,
        ProxyServingRuntimeError::ShutdownTimedOut => AndroidRuntimeError::ShutdownTimedOut,
    }
}
