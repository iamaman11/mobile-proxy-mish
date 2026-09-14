use mish_transport::{
    AuthorizedUdpDatagram, MeshUdpIngressRuntime, UdpAssociationCredential, UdpAssociationId,
    UdpAssociationRegistry, UdpDatagramAuthorizer, UdpIngressBudget,
};
use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::sync::Arc;
use std::time::Duration;

struct Authorizer {
    backend_port: u16,
}

impl UdpDatagramAuthorizer for Authorizer {
    fn authorize(&self, _peer: SocketAddr, packet: &[u8]) -> Option<AuthorizedUdpDatagram> {
        (packet == b"authenticated").then(|| {
            AuthorizedUdpDatagram::new(
                UdpAssociationId::new(1).expect("non-zero id"),
                self.backend_port,
            )
            .expect("non-zero port")
        })
    }
}

#[test]
fn exact_ingress_relays_only_authorized_datagrams_and_returns_backend_response() {
    let backend = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("backend bind");
    backend
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("backend timeout");
    let backend_port = backend.local_addr().expect("backend address").port();
    let backend_worker = std::thread::spawn(move || {
        let mut buffer = [0_u8; 64];
        let (count, peer) = backend.recv_from(&mut buffer).expect("authorized datagram");
        assert_eq!(&buffer[..count], b"authenticated");
        backend.send_to(b"response", peer).expect("response");
    });

    let reservation = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("ingress reservation");
    let ingress_port = reservation.local_addr().expect("ingress address").port();
    drop(reservation);
    let mut runtime = MeshUdpIngressRuntime::start(
        Ipv4Addr::LOCALHOST,
        ingress_port,
        UdpIngressBudget::new(1, 10, 1024).expect("budget"),
        Arc::new(Authorizer { backend_port }),
    )
    .expect("exact ingress");

    let client = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("client bind");
    client
        .set_read_timeout(Some(Duration::from_millis(200)))
        .expect("client timeout");
    client
        .send_to(b"rejected", (Ipv4Addr::LOCALHOST, ingress_port))
        .expect("rejected send");
    let mut response = [0_u8; 64];
    assert!(
        client.recv_from(&mut response).is_err(),
        "unauthorized datagram must be dropped"
    );

    client
        .send_to(b"authenticated", (Ipv4Addr::LOCALHOST, ingress_port))
        .expect("authorized send");
    let (count, _) = client.recv_from(&mut response).expect("backend response");
    assert_eq!(&response[..count], b"response");
    assert_eq!(runtime.active_associations(), 1);
    backend_worker.join().expect("backend worker");
    runtime.stop();
    assert_eq!(runtime.active_associations(), 0);
}

fn envelope(id: [u8; 16], secret: [u8; 32], payload: &[u8]) -> Vec<u8> {
    let mut packet = Vec::with_capacity(52 + payload.len());
    packet.extend_from_slice(b"MUDP");
    packet.extend_from_slice(&id);
    packet.extend_from_slice(&secret);
    packet.extend_from_slice(payload);
    packet
}

#[test]
fn association_registry_relays_only_epoch_bound_authenticated_payloads() {
    let backend = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("backend bind");
    backend
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("backend timeout");
    let backend_port = backend.local_addr().expect("backend address").port();
    let backend_worker = std::thread::spawn(move || {
        let mut buffer = [0_u8; 64];
        let (count, peer) = backend.recv_from(&mut buffer).expect("authorized payload");
        assert_eq!(&buffer[..count], b"quic-like-payload");
        backend.send_to(b"response", peer).expect("response");
    });

    let registry = Arc::new(UdpAssociationRegistry::new());
    assert!(registry.replace_epoch(7));
    let id = [7_u8; 16];
    let secret = [9_u8; 32];
    let credential = UdpAssociationCredential::new(id, secret).expect("credential");
    assert!(registry.issue(
        7,
        credential.clone(),
        UdpAssociationId::new(77).expect("id"),
        backend_port,
        Duration::from_secs(2),
    ));
    assert_eq!(
        format!("{credential:?}"),
        "UdpAssociationCredential(<redacted>)"
    );

    let reservation = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("ingress reservation");
    let ingress_port = reservation.local_addr().expect("ingress address").port();
    drop(reservation);
    let mut runtime = MeshUdpIngressRuntime::start(
        Ipv4Addr::LOCALHOST,
        ingress_port,
        UdpIngressBudget::new(2, 10, 1024).expect("budget"),
        registry.clone(),
    )
    .expect("exact ingress");

    let client = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("client bind");
    client
        .set_read_timeout(Some(Duration::from_millis(300)))
        .expect("client timeout");
    let mut response = [0_u8; 64];
    client
        .send_to(
            &envelope(id, [3_u8; 32], b"quic-like-payload"),
            (Ipv4Addr::LOCALHOST, ingress_port),
        )
        .expect("wrong secret send");
    assert!(
        client.recv_from(&mut response).is_err(),
        "wrong secret must drop"
    );

    client
        .send_to(
            &envelope(id, secret, b"quic-like-payload"),
            (Ipv4Addr::LOCALHOST, ingress_port),
        )
        .expect("authenticated send");
    let (count, _) = client.recv_from(&mut response).expect("response");
    assert_eq!(&response[..count], b"response");
    assert_eq!(runtime.active_associations(), 1);

    let second_peer = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("second peer bind");
    second_peer
        .set_read_timeout(Some(Duration::from_millis(300)))
        .expect("second timeout");
    second_peer
        .send_to(
            &envelope(id, secret, b"quic-like-payload"),
            (Ipv4Addr::LOCALHOST, ingress_port),
        )
        .expect("second peer send");
    assert!(
        second_peer.recv_from(&mut response).is_err(),
        "association must pin its first UDP peer"
    );

    registry.replace_epoch(8);
    client
        .send_to(
            &envelope(id, secret, b"quic-like-payload"),
            (Ipv4Addr::LOCALHOST, ingress_port),
        )
        .expect("stale epoch send");
    assert!(
        client.recv_from(&mut response).is_err(),
        "epoch replacement must revoke the association"
    );
    backend_worker.join().expect("backend worker");
    runtime.stop();
}
