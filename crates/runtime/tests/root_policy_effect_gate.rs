use mish_cellular::{
    CellularNetworkAuthority, NetworkHandle, NetworkObservation, ObservationSequence,
};
use mish_cellular_egress_bridge::OutboundConnectError;
use mish_runtime::{CellularDnsResolver, CellularRuntimeCoordinator};
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

const SOCKS_VERSION: u8 = 0x05;
const USERNAME_PASSWORD: u8 = 0x02;
const USERNAME_PASSWORD_VERSION: u8 = 0x01;
const CONNECT: u8 = 0x01;
const DOMAIN: u8 = 0x03;
const HOST_UNREACHABLE: u8 = 0x04;
const IO_TIMEOUT: Duration = Duration::from_secs(2);

fn sequence(raw: u64) -> ObservationSequence {
    ObservationSequence::new(raw).expect("sequence")
}

fn handle(raw: u64) -> NetworkHandle {
    NetworkHandle::new(raw).expect("network handle")
}

fn expect_fail_closed_domain_connect(port: u16) -> u8 {
    let mut stream = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).expect("connect private bridge");
    stream
        .set_read_timeout(Some(IO_TIMEOUT))
        .expect("read timeout");
    stream
        .set_write_timeout(Some(IO_TIMEOUT))
        .expect("write timeout");

    stream
        .write_all(&[SOCKS_VERSION, 1, USERNAME_PASSWORD])
        .expect("write greeting");
    let mut method = [0_u8; 2];
    stream.read_exact(&mut method).expect("read method");
    assert_eq!(method, [SOCKS_VERSION, USERNAME_PASSWORD]);

    let username = b"gate-user";
    let password = b"gate-password";
    let mut auth = vec![USERNAME_PASSWORD_VERSION, username.len() as u8];
    auth.extend_from_slice(username);
    auth.push(password.len() as u8);
    auth.extend_from_slice(password);
    stream.write_all(&auth).expect("write auth");
    let mut auth_reply = [0_u8; 2];
    stream.read_exact(&mut auth_reply).expect("read auth reply");
    assert_eq!(auth_reply, [USERNAME_PASSWORD_VERSION, 0]);

    let domain = b"gate.example.invalid";
    let mut request = vec![SOCKS_VERSION, CONNECT, 0, DOMAIN, domain.len() as u8];
    request.extend_from_slice(domain);
    request.extend_from_slice(&443_u16.to_be_bytes());
    stream.write_all(&request).expect("write CONNECT");

    let mut header = [0_u8; 4];
    stream.read_exact(&mut header).expect("read CONNECT reply");
    assert_eq!(header[0], SOCKS_VERSION);
    assert_eq!(header[2], 0);
    let remainder = match header[3] {
        0x01 => 6,
        0x04 => 18,
        other => panic!("unexpected SOCKS reply address type {other}"),
    };
    let mut tail = vec![0_u8; remainder];
    stream.read_exact(&mut tail).expect("read CONNECT reply tail");
    header[1]
}

#[test]
fn private_bridge_cannot_escape_before_root_authorization_or_after_cellular_loss() {
    let resolver_calls = Arc::new(AtomicUsize::new(0));
    let calls = Arc::clone(&resolver_calls);
    let resolver: Arc<dyn CellularDnsResolver> = Arc::new(
        move |_authority: CellularNetworkAuthority,
              _hostname: &str|
              -> Result<Vec<IpAddr>, OutboundConnectError> {
            calls.fetch_add(1, Ordering::SeqCst);
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        },
    );
    let runtime = CellularRuntimeCoordinator::new(resolver);
    let bridge = runtime
        .start_private_bridge(
            "gate-user".to_owned(),
            "gate-password".to_owned(),
            Duration::from_secs(2),
        )
        .expect("start private bridge");

    // A listening private bridge is not authority. Before any admitted network/root-policy
    // authorization, the effect gate must reject the CONNECT before DNS or a public socket.
    assert_eq!(expect_fail_closed_domain_connect(bridge.port()), HOST_UNREACHABLE);
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

    // Semantic cellular admission alone is deliberately insufficient. Android must reconcile
    // and explicitly authorize the exact root-policy generation first.
    assert_eq!(expect_fail_closed_domain_connect(bridge.port()), HOST_UNREACHABLE);
    assert_eq!(resolver_calls.load(Ordering::SeqCst), 0);

    assert!(
        runtime
            .authorize_root_policy(sequence(1), handle(42))
            .expect("authorize exact root policy")
    );
    runtime
        .network_lost(sequence(2), handle(42))
        .expect("observe cellular loss");

    // Loss closes the gate synchronously with the owner transition. A stale previously-authorized
    // generation cannot reach DNS or fall back to a default/Wi-Fi/VPN path.
    assert_eq!(expect_fail_closed_domain_connect(bridge.port()), HOST_UNREACHABLE);
    assert_eq!(resolver_calls.load(Ordering::SeqCst), 0);

    bridge.stop().expect("stop private bridge");
}
