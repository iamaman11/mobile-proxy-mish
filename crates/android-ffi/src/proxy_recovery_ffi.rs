use crate::ProxyServingFailure;
use mish_runtime::{
    ProxyServingFailure as OwnerProxyServingFailure,
    proxy_recovery_delay_ms as owner_proxy_recovery_delay_ms,
    proxy_serving_failure_recoverable as owner_proxy_serving_failure_recoverable,
};

#[uniffi::export]
pub fn proxy_serving_failure_recoverable(failure: ProxyServingFailure) -> bool {
    owner_proxy_serving_failure_recoverable(map_failure(failure))
}

#[uniffi::export]
pub fn proxy_recovery_delay_ms(attempt: u32) -> u64 {
    owner_proxy_recovery_delay_ms(attempt)
}

fn map_failure(failure: ProxyServingFailure) -> OwnerProxyServingFailure {
    match failure {
        ProxyServingFailure::NativeRuntimeMissing => OwnerProxyServingFailure::NativeRuntimeMissing,
        ProxyServingFailure::ExternalCredentialUnavailable => {
            OwnerProxyServingFailure::ExternalCredentialUnavailable
        }
        ProxyServingFailure::CellularConnectorUnavailable => {
            OwnerProxyServingFailure::CellularConnectorUnavailable
        }
        ProxyServingFailure::ProxyConfigurationRejected => {
            OwnerProxyServingFailure::ProxyConfigurationRejected
        }
        ProxyServingFailure::MixedListenerUnavailable => {
            OwnerProxyServingFailure::MixedListenerUnavailable
        }
        ProxyServingFailure::Socks5ListenerUnavailable => {
            OwnerProxyServingFailure::Socks5ListenerUnavailable
        }
        ProxyServingFailure::HttpConnectListenerUnavailable => {
            OwnerProxyServingFailure::HttpConnectListenerUnavailable
        }
        ProxyServingFailure::ExecutorUnavailable => OwnerProxyServingFailure::ExecutorUnavailable,
        ProxyServingFailure::RuntimeStateUnavailable => {
            OwnerProxyServingFailure::RuntimeStateUnavailable
        }
        ProxyServingFailure::ServingUnhealthy => OwnerProxyServingFailure::ServingUnhealthy,
        ProxyServingFailure::ShutdownFailed => OwnerProxyServingFailure::ShutdownFailed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_delegates_recovery_policy_to_runtime() {
        assert!(proxy_serving_failure_recoverable(
            ProxyServingFailure::ServingUnhealthy
        ));
        assert!(proxy_serving_failure_recoverable(
            ProxyServingFailure::MixedListenerUnavailable
        ));
        assert!(!proxy_serving_failure_recoverable(
            ProxyServingFailure::ShutdownFailed
        ));
        assert!(!proxy_serving_failure_recoverable(
            ProxyServingFailure::ProxyConfigurationRejected
        ));
        assert_eq!(proxy_recovery_delay_ms(0), 1_000);
        assert_eq!(proxy_recovery_delay_ms(99), 60_000);
    }
}
