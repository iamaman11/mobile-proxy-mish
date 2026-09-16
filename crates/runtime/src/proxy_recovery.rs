use crate::ProxyServingFailure;

/// Runtime-owned classification of failures for which one bounded whole-generation restart may
/// restore service. Android executes the timer/restart effect but owns no recovery policy.
pub const fn proxy_serving_failure_recoverable(failure: ProxyServingFailure) -> bool {
    matches!(
        failure,
        ProxyServingFailure::MixedListenerUnavailable
            | ProxyServingFailure::Socks5ListenerUnavailable
            | ProxyServingFailure::HttpConnectListenerUnavailable
            | ProxyServingFailure::ExecutorUnavailable
            | ProxyServingFailure::ServingUnhealthy
    )
}

/// Runtime-owned bounded retry delay. The adapter supplies only the monotonic attempt count.
pub const fn proxy_recovery_delay_ms(attempt: u32) -> u64 {
    match attempt {
        0 => 1_000,
        1 => 5_000,
        2 => 15_000,
        3 => 30_000,
        _ => 60_000,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_transient_native_serving_failures_auto_recover() {
        for recoverable in [
            ProxyServingFailure::MixedListenerUnavailable,
            ProxyServingFailure::Socks5ListenerUnavailable,
            ProxyServingFailure::HttpConnectListenerUnavailable,
            ProxyServingFailure::ExecutorUnavailable,
            ProxyServingFailure::ServingUnhealthy,
        ] {
            assert!(proxy_serving_failure_recoverable(recoverable));
        }
        for terminal in [
            ProxyServingFailure::NativeRuntimeMissing,
            ProxyServingFailure::ExternalCredentialUnavailable,
            ProxyServingFailure::CellularConnectorUnavailable,
            ProxyServingFailure::ProxyConfigurationRejected,
            ProxyServingFailure::RuntimeStateUnavailable,
            ProxyServingFailure::ShutdownFailed,
        ] {
            assert!(!proxy_serving_failure_recoverable(terminal));
        }
    }

    #[test]
    fn recovery_backoff_is_bounded() {
        assert_eq!(proxy_recovery_delay_ms(0), 1_000);
        assert_eq!(proxy_recovery_delay_ms(1), 5_000);
        assert_eq!(proxy_recovery_delay_ms(2), 15_000);
        assert_eq!(proxy_recovery_delay_ms(3), 30_000);
        assert_eq!(proxy_recovery_delay_ms(4), 60_000);
        assert_eq!(proxy_recovery_delay_ms(u32::MAX), 60_000);
    }
}
