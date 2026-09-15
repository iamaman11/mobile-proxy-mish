use crate::runtime_boundary::{AndroidRuntimeError, CellularBridgeRuntime};
use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
use mish_runtime::{
    PrivateBridgeOutboundConnector, ProxyServingRuntime, ProxyServingRuntimeError,
};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::Duration;

/// Stateless Android handle over one in-process native proxy serving generation.
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

/// Starts the Rust public listener runtime against the already-created private Cellular bridge.
///
/// The bridge remains a temporary migration adapter only. Target domains are encoded into the
/// private SOCKS hop without resolution, so Android exact-network DNS remains the sole DNS effect.
#[uniffi::export]
pub fn start_native_proxy_runtime(
    bridge: Arc<CellularBridgeRuntime>,
    public_username: String,
    public_password: String,
    private_username: String,
    private_password: String,
    operation_timeout_ms: u64,
) -> Result<Arc<NativeProxyRuntime>, AndroidRuntimeError> {
    if operation_timeout_ms == 0 {
        return Err(AndroidRuntimeError::InvalidOperationTimeout);
    }
    let public_credentials = ProxyCredentialMaterial::new(public_username, public_password)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let plan = ProxyServingPlan::canonical(
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        public_credentials,
    )
    .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let connector = PrivateBridgeOutboundConnector::new(
        bridge.port(),
        private_username,
        private_password,
        Duration::from_millis(operation_timeout_ms),
    )
    .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let inner = ProxyServingRuntime::start(plan, Arc::new(connector))
        .map_err(map_proxy_runtime_error)?;
    Ok(Arc::new(NativeProxyRuntime { inner }))
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
