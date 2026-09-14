use mish_transport::{
    AuthorizedUdpDatagram, MeshUdpIngressRuntime, UdpAssociationId, UdpDatagramAuthorizer,
    UdpIngressBudget,
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
