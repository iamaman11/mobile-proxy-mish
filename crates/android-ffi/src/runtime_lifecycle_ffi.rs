//! Projection-only Android FFI vocabulary for Rust-owned runtime/Proxy state.
//!
//! Lifecycle decisions and start/stop actions stay internal to mish-runtime. Android may observe
//! immutable state/failure values but cannot steer the native state machine through this module.

use mish_runtime::{
    ProxyServingFailure as OwnerProxyServingFailure,
    RuntimeLifecycleState as OwnerRuntimeLifecycleState,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RuntimeLifecycleState {
    Stopped,
    Starting,
    Running,
    Stopping,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProxyServingState {
    Stopped,
    Starting,
    Running,
    Failed,
}

/// Exact projection of the Rust Runtime Lifecycle failure vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProxyServingFailure {
    NativeRuntimeMissing,
    ExternalCredentialUnavailable,
    CellularConnectorUnavailable,
    ProxyConfigurationRejected,
    MixedListenerUnavailable,
    Socks5ListenerUnavailable,
    HttpConnectListenerUnavailable,
    ExecutorUnavailable,
    RuntimeStateUnavailable,
    ServingUnhealthy,
    ShutdownFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProxyServingSnapshotView {
    pub state: ProxyServingState,
    pub failure: Option<ProxyServingFailure>,
}

pub(crate) fn map_lifecycle_state(state: OwnerRuntimeLifecycleState) -> RuntimeLifecycleState {
    match state {
        OwnerRuntimeLifecycleState::Stopped => RuntimeLifecycleState::Stopped,
        OwnerRuntimeLifecycleState::Starting => RuntimeLifecycleState::Starting,
        OwnerRuntimeLifecycleState::Running => RuntimeLifecycleState::Running,
        OwnerRuntimeLifecycleState::Stopping => RuntimeLifecycleState::Stopping,
    }
}

pub(crate) const fn map_proxy_failure_out(
    failure: OwnerProxyServingFailure,
) -> ProxyServingFailure {
    match failure {
        OwnerProxyServingFailure::NativeRuntimeMissing => ProxyServingFailure::NativeRuntimeMissing,
        OwnerProxyServingFailure::ExternalCredentialUnavailable => {
            ProxyServingFailure::ExternalCredentialUnavailable
        }
        OwnerProxyServingFailure::CellularConnectorUnavailable => {
            ProxyServingFailure::CellularConnectorUnavailable
        }
        OwnerProxyServingFailure::ProxyConfigurationRejected => {
            ProxyServingFailure::ProxyConfigurationRejected
        }
        OwnerProxyServingFailure::MixedListenerUnavailable => {
            ProxyServingFailure::MixedListenerUnavailable
        }
        OwnerProxyServingFailure::Socks5ListenerUnavailable => {
            ProxyServingFailure::Socks5ListenerUnavailable
        }
        OwnerProxyServingFailure::HttpConnectListenerUnavailable => {
            ProxyServingFailure::HttpConnectListenerUnavailable
        }
        OwnerProxyServingFailure::ExecutorUnavailable => ProxyServingFailure::ExecutorUnavailable,
        OwnerProxyServingFailure::RuntimeStateUnavailable => {
            ProxyServingFailure::RuntimeStateUnavailable
        }
        OwnerProxyServingFailure::ServingUnhealthy => ProxyServingFailure::ServingUnhealthy,
        OwnerProxyServingFailure::ShutdownFailed => ProxyServingFailure::ShutdownFailed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_proxy_failure_projection_preserves_every_native_failure_reason() {
        for (owner, projected) in [
            (
                OwnerProxyServingFailure::NativeRuntimeMissing,
                ProxyServingFailure::NativeRuntimeMissing,
            ),
            (
                OwnerProxyServingFailure::ExternalCredentialUnavailable,
                ProxyServingFailure::ExternalCredentialUnavailable,
            ),
            (
                OwnerProxyServingFailure::CellularConnectorUnavailable,
                ProxyServingFailure::CellularConnectorUnavailable,
            ),
            (
                OwnerProxyServingFailure::ProxyConfigurationRejected,
                ProxyServingFailure::ProxyConfigurationRejected,
            ),
            (
                OwnerProxyServingFailure::MixedListenerUnavailable,
                ProxyServingFailure::MixedListenerUnavailable,
            ),
            (
                OwnerProxyServingFailure::Socks5ListenerUnavailable,
                ProxyServingFailure::Socks5ListenerUnavailable,
            ),
            (
                OwnerProxyServingFailure::HttpConnectListenerUnavailable,
                ProxyServingFailure::HttpConnectListenerUnavailable,
            ),
            (
                OwnerProxyServingFailure::ExecutorUnavailable,
                ProxyServingFailure::ExecutorUnavailable,
            ),
            (
                OwnerProxyServingFailure::RuntimeStateUnavailable,
                ProxyServingFailure::RuntimeStateUnavailable,
            ),
            (
                OwnerProxyServingFailure::ServingUnhealthy,
                ProxyServingFailure::ServingUnhealthy,
            ),
            (
                OwnerProxyServingFailure::ShutdownFailed,
                ProxyServingFailure::ShutdownFailed,
            ),
        ] {
            assert_eq!(map_proxy_failure_out(owner), projected);
        }
    }
}
