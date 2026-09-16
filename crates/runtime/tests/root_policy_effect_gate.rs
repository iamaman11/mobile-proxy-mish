use mish_cellular::{
    CellularNetworkAuthority, NetworkHandle, NetworkObservation, ObservationSequence,
};
use mish_proxy::{ProxyConnectTarget, ProxyOutboundConnectError, ProxyOutboundConnector};
use mish_runtime::{CellularDnsResolver, CellularRuntimeCoordinator};
use std::net::IpAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

fn sequence(raw: u64) -> ObservationSequence {
    ObservationSequence::new(raw).expect("sequence")
}

fn handle(raw: u64) -> NetworkHandle {
    NetworkHandle::new(raw).expect("network handle")
}

#[test]
fn direct_proxy_connector_cannot_escape_before_root_authorization_or_after_cellular_loss() {
    let resolver_calls = Arc::new(AtomicUsize::new(0));
    let calls = Arc::clone(&resolver_calls);
    let resolver: Arc<dyn CellularDnsResolver> = Arc::new(
        move |_authority: CellularNetworkAuthority,
              _hostname: &str|
              -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
            calls.fetch_add(1, Ordering::SeqCst);
            Err(ProxyOutboundConnectError::Failed)
        },
    );
    let runtime = CellularRuntimeCoordinator::new(resolver);
    let connector = runtime
        .outbound_connector(Duration::from_secs(2))
        .expect("direct connector");
    let target = ProxyConnectTarget::domain("gate.example.invalid", 443).expect("target");

    // No cellular authority exists yet. The direct PRODUCT path fails before DNS.
    assert_eq!(
        connector.connect(&target),
        Err(ProxyOutboundConnectError::Unavailable)
    );
    assert_eq!(resolver_calls.load(Ordering::SeqCst), 0);

    let admitted = runtime
        .observe_network(NetworkObservation::new(
            sequence(1),
            handle(42),
            true,
            true,
            true,
            true,
        ))
        .expect("observe admitted cellular");
    assert!(admitted.admitted_network().is_some());

    // Semantic cellular admission alone is insufficient: exact root-policy authorization is the
    // sole gate that permits the blocking setup seam to reach exact-network DNS.
    assert_eq!(
        connector.connect(&target),
        Err(ProxyOutboundConnectError::Unavailable)
    );
    assert_eq!(resolver_calls.load(Ordering::SeqCst), 0);

    assert!(
        runtime
            .authorize_root_policy(sequence(1), handle(42))
            .expect("authorize exact root policy")
    );
    assert_eq!(
        connector.connect(&target),
        Err(ProxyOutboundConnectError::Failed)
    );
    assert_eq!(resolver_calls.load(Ordering::SeqCst), 1);

    runtime
        .network_lost(sequence(2), handle(42))
        .expect("observe cellular loss");

    // Loss closes the same gate synchronously. A stale connector cannot reach DNS and therefore
    // cannot escape through default/Wi-Fi/VPN routing.
    assert_eq!(
        connector.connect(&target),
        Err(ProxyOutboundConnectError::Unavailable)
    );
    assert_eq!(resolver_calls.load(Ordering::SeqCst), 1);
}
