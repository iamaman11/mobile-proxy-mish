use mish_transport::{MAX_MESH_SESSIONS, MeshIngressRuntime, MeshPortForward};
use std::io::Read;
use std::net::{Ipv4Addr, TcpListener, TcpStream};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const IO_TIMEOUT: Duration = Duration::from_secs(2);

fn wait_until(deadline: Instant, mut predicate: impl FnMut() -> bool) {
    while Instant::now() < deadline {
        if predicate() {
            return;
        }
        thread::sleep(Duration::from_millis(10));
    }
    assert!(predicate(), "condition did not become true before deadline");
}

#[test]
fn sixty_fifth_mesh_session_is_rejected_before_loopback_backend() {
    assert_eq!(
        MAX_MESH_SESSIONS, 64,
        "DEVICE-1 capacity candidate changed unexpectedly"
    );

    let backend = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("bind backend");
    let backend_port = backend.local_addr().expect("backend address").port();
    let reserve = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("reserve ingress");
    let ingress_port = reserve.local_addr().expect("ingress address").port();
    drop(reserve);

    let (accepted_tx, accepted_rx) = mpsc::channel();
    let (verify_tx, verify_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let backend_thread = thread::spawn(move || {
        let mut sockets = Vec::with_capacity(MAX_MESH_SESSIONS);
        for _ in 0..MAX_MESH_SESSIONS {
            let (stream, _) = backend.accept().expect("accept supported backend session");
            sockets.push(stream);
        }
        accepted_tx
            .send(sockets.len())
            .expect("publish accepted count");

        verify_rx.recv().expect("wait for overflow probe");
        backend
            .set_nonblocking(true)
            .expect("make backend nonblocking");
        let deadline = Instant::now() + Duration::from_millis(500);
        let mut overflow_reached_backend = false;
        while Instant::now() < deadline {
            match backend.accept() {
                Ok((_stream, _)) => {
                    overflow_reached_backend = true;
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("backend overflow observation failed: {error}"),
            }
        }
        release_rx
            .recv()
            .expect("wait until overflow assertion completed");
        drop(sockets);
        overflow_reached_backend
    });

    let mappings = [MeshPortForward::new(ingress_port, backend_port)];
    let mut runtime = MeshIngressRuntime::start(Ipv4Addr::LOCALHOST, &mappings)
        .expect("start bounded Mesh ingress");

    let mut supported_clients = Vec::with_capacity(MAX_MESH_SESSIONS);
    for _ in 0..MAX_MESH_SESSIONS {
        let stream = TcpStream::connect((Ipv4Addr::LOCALHOST, ingress_port))
            .expect("connect supported Mesh client");
        stream
            .set_read_timeout(Some(IO_TIMEOUT))
            .expect("supported read timeout");
        supported_clients.push(stream);
    }

    assert_eq!(
        accepted_rx
            .recv_timeout(IO_TIMEOUT)
            .expect("backend should receive supported sessions"),
        MAX_MESH_SESSIONS,
    );
    wait_until(Instant::now() + IO_TIMEOUT, || {
        runtime.active_sessions() == MAX_MESH_SESSIONS
    });

    let mut overflow = TcpStream::connect((Ipv4Addr::LOCALHOST, ingress_port))
        .expect("TCP handshake for overflow probe");
    overflow
        .set_read_timeout(Some(IO_TIMEOUT))
        .expect("overflow read timeout");

    // The edge may complete the kernel TCP handshake before its userspace accept loop observes
    // capacity. It must then close the 65th client without connecting the private loopback
    // backend and without displacing any of the 64 admitted sessions.
    let mut byte = [0_u8; 1];
    let closed = match overflow.read(&mut byte) {
        Ok(0) => true,
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionReset
                    | std::io::ErrorKind::ConnectionAborted
                    | std::io::ErrorKind::BrokenPipe
            ) =>
        {
            true
        }
        Ok(_) => false,
        Err(error) => panic!("overflow session did not fail closed: {error}"),
    };
    assert!(closed, "65th Mesh session remained usable");
    assert_eq!(runtime.active_sessions(), MAX_MESH_SESSIONS);

    verify_tx.send(()).expect("ask backend to check overflow");
    release_tx.send(()).expect("release backend sessions");
    let overflow_reached_backend = backend_thread.join().expect("backend thread");
    assert!(
        !overflow_reached_backend,
        "65th Mesh session reached the private backend instead of being rejected at the edge"
    );

    drop(overflow);
    drop(supported_clients);
    wait_until(Instant::now() + IO_TIMEOUT, || {
        runtime.active_sessions() == 0
    });
    runtime.stop().expect("bounded ingress clean stop");
}
