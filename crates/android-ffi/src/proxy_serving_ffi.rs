use crate::runtime_boundary::CellularController;
use crate::runtime_lifecycle_ffi::{
    ProxyServingFailure, ProxyServingSnapshotView, map_proxy_failure_out, map_proxy_snapshot,
};
use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
use mish_runtime::{
    ProxyServingFailure as OwnerProxyServingFailure, ProxyServingRuntime,
    ProxyServingTerminalObserver,
};
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::Duration;

const MAX_OUTBOUND_OPERATION_TIMEOUT_MS: u64 = 15_000;

#[uniffi::export(foreign)]
pub trait NativeProxyRuntimeObserver: Send + Sync {
    fn on_terminal_failure(&self, failure: ProxyServingFailure);
}

#[derive(uniffi::Object)]
pub struct NativeProxyRuntime {
    inner: Arc<ProxyServingRuntime>,
}

impl NativeProxyRuntime {
    /// Rust-only composition handle. Android receives the opaque UniFFI object but cannot execute
    /// arbitrary Tokio work or acquire a second runtime/control-plane surface.
    pub(crate) fn runtime_handle(&self) -> Arc<ProxyServingRuntime> {
        Arc::clone(&self.inner)
    }
}

#[uniffi::export]
impl NativeProxyRuntime {
    /// Immutable owner snapshot. Android projects this value; it never drives transitions.
    pub fn snapshot(&self) -> ProxyServingSnapshotView {
        map_proxy_snapshot(self.inner.snapshot())
    }

    /// Read-only diagnostic observation. PRODUCT lifecycle decisions do not poll this method.
    pub fn is_healthy(&self) -> bool {
        self.inner.is_healthy()
    }

    pub fn active_sessions(&self) -> u32 {
        self.inner.active_sessions().min(u32::MAX as usize) as u32
    }

    pub fn terminal_failure(&self) -> Option<ProxyServingFailure> {
        self.inner.terminal_failure().map(map_proxy_failure_out)
    }

    pub fn observe_terminal_failure(&self, observer: Arc<dyn NativeProxyRuntimeObserver>) {
        let terminal_observer: ProxyServingTerminalObserver = Arc::new(move |failure| {
            observer.on_terminal_failure(map_proxy_failure_out(failure));
        });
        self.inner.set_terminal_observer(terminal_observer);
    }

    /// Expected shutdown failures remain typed owner data; Kotlin does not classify Rust errors.
    pub fn stop(&self) -> Option<ProxyServingFailure> {
        self.inner
            .stop()
            .err()
            .map(|error| map_proxy_failure_out(error.lifecycle_failure()))
    }
}

/// Non-throwing startup outcome. Expected PRODUCT startup failures stay typed in Rust and cross
/// UniFFI as data; Kotlin only executes the requested platform/composition effect.
#[derive(uniffi::Object)]
pub struct NativeProxyStartAttempt {
    runtime: Option<Arc<NativeProxyRuntime>>,
    failure: Option<ProxyServingFailure>,
}

#[uniffi::export]
impl NativeProxyStartAttempt {
    pub fn runtime(&self) -> Option<Arc<NativeProxyRuntime>> {
        self.runtime.clone()
    }

    pub fn failure(&self) -> Option<ProxyServingFailure> {
        self.failure
    }
}

impl NativeProxyStartAttempt {
    fn started(inner: Arc<ProxyServingRuntime>) -> Arc<Self> {
        Arc::new(Self {
            runtime: Some(Arc::new(NativeProxyRuntime { inner })),
            failure: None,
        })
    }

    fn failed(failure: OwnerProxyServingFailure) -> Arc<Self> {
        Arc::new(Self {
            runtime: None,
            failure: Some(map_proxy_failure_out(failure)),
        })
    }
}

/// Starts Proxy Serving directly against the exact Cellular Egress owner held by `cellular`.
#[uniffi::export]
pub fn start_native_proxy_runtime(
    cellular: Arc<CellularController>,
    public_username: String,
    public_password: String,
    operation_timeout_ms: u64,
) -> Arc<NativeProxyStartAttempt> {
    if operation_timeout_ms == 0 || operation_timeout_ms > MAX_OUTBOUND_OPERATION_TIMEOUT_MS {
        return NativeProxyStartAttempt::failed(
            OwnerProxyServingFailure::ProxyConfigurationRejected,
        );
    }

    let public_credentials = match ProxyCredentialMaterial::new(public_username, public_password) {
        Ok(credentials) => credentials,
        Err(_) => {
            return NativeProxyStartAttempt::failed(
                OwnerProxyServingFailure::ProxyConfigurationRejected,
            );
        }
    };
    let plan =
        match ProxyServingPlan::canonical(IpAddr::V4(Ipv4Addr::LOCALHOST), public_credentials) {
            Ok(plan) => plan,
            Err(_) => {
                return NativeProxyStartAttempt::failed(
                    OwnerProxyServingFailure::ProxyConfigurationRejected,
                );
            }
        };
    let connector = match cellular
        .runtime_handle()
        .outbound_connector(Duration::from_millis(operation_timeout_ms))
    {
        Ok(connector) => connector,
        Err(_) => {
            return NativeProxyStartAttempt::failed(
                OwnerProxyServingFailure::CellularConnectorUnavailable,
            );
        }
    };
    match ProxyServingRuntime::start(plan, connector) {
        Ok(inner) => NativeProxyStartAttempt::started(inner),
        Err(error) => NativeProxyStartAttempt::failed(error.lifecycle_failure()),
    }
}

#[uniffi::export]
pub fn proxy_listener_ports() -> Vec<u16> {
    vec![
        mish_proxy::MIXED_PORT,
        mish_proxy::SOCKS5_PORT,
        mish_proxy::HTTP_CONNECT_PORT,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn invalid_start_configuration_is_returned_as_typed_data() {
        let attempt = start_native_proxy_runtime(
            CellularController::new(),
            "user".to_string(),
            "password".to_string(),
            0,
        );
        assert!(attempt.runtime().is_none());
        assert_eq!(
            attempt.failure(),
            Some(ProxyServingFailure::ProxyConfigurationRejected)
        );
    }
}
