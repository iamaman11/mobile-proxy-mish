use mish_transport::{MeshPortForward, MeshTransportCoordinator, MeshVpnObservation};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::thread;
use std::time::{Duration, Instant};

#[test]
fn vpn_loss_closes_active_session_before_same_endpoint_gets_fresh_epoch() {
    let endpoint = Ipv4Addr::new(127, 0, 0, 2);
    let runtime = MeshTransportCoordinator::new(Ipv4Addr::new(127, 0, 0, 0), 8)
        .expect("loopback test coordinator");

    let backend = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("backend bind");
    let backend_port = backend.local_addr().expect("backend address").port();
    let ingress_reservation = TcpListener::bind((endpoint, 0)).expect("ingress reserve");
    let ingress_port = ingress_reservation
        .local_addr()
        .expect("ingress address")
        .port();
    drop(ingress_reservation);

    let backend_worker = thread::spawn(move || {
        let (mut stream, _) = backend.accept().expect("backend accept");
        let mut first = [0_u8; 1];
        stream.read_exact(&mut first).expect("initial backend read");
        assert_eq!(first, [0x41]);

        let mut drain = [0_u8; 1];
        loop {
            match stream.read(&mut drain) {
                Ok(0) => return,
                Ok(_) => continue,
                Err(_) => return,
            }
        }
    });

    let admitted = runtime
        .observe_vpn(
            1,
            MeshVpnObservation::UniqueVpn {
                local_ipv4: vec![endpoint],
            },
        )
        .expect("initial VPN observation");
    let first_epoch = admitted
        .admission()
        .admission_epoch()
        .expect("initial admission epoch");
    assert!(runtime
        .start_ingress(
            first_epoch,
            &[MeshPortForward::new(ingress_port, backend_port)],
        )
        .expect("start ingress"));

    let mut client = TcpStream::connect((endpoint, ingress_port)).expect("connect ingress");
    client.write_all(&[0x41]).expect("write through ingress");

    let deadline = Instant::now() + Duration::from_secs(2);
    while runtime.snapshot().expect("snapshot").active_sessions() == 0 {
        assert!(Instant::now() < deadline, "session did not become active");
        thread::sleep(Duration::from_millis(10));
    }

    let lost = runtime
        .observe_vpn(2, MeshVpnObservation::Absent)
        .expect("VPN loss");
    assert!(!lost.ingress_running());
    assert_eq!(lost.active_sessions(), 0);
    backend_worker.join().expect("backend worker");

    let returned = runtime
        .observe_vpn(
            3,
            MeshVpnObservation::UniqueVpn {
                local_ipv4: vec![endpoint],
            },
        )
        .expect("same endpoint returns");
    assert_ne!(returned.admission().admission_epoch(), Some(first_epoch));
    assert!(!returned.ingress_running());

    drop(client);
}
