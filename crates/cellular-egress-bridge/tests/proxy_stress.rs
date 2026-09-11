use mish_cellular_egress_bridge::{
    BridgeCredentials, BridgeListener, CellularOutboundConnector, ConnectTarget,
    OutboundConnectError,
};
use std::io::{Read, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

const SOCKS_VERSION: u8 = 0x05;
const USERNAME_PASSWORD_METHOD: u8 = 0x02;
const USERNAME_PASSWORD_VERSION: u8 = 0x01;
const CONNECT_COMMAND: u8 = 0x01;
const IPV4_ADDRESS_TYPE: u8 = 0x01;
const TEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug)]
struct LoopbackConnector {
    upstream: SocketAddr,
    calls: AtomicUsize,
}

impl LoopbackConnector {
    fn new(upstream: SocketAddr) -> Self {
        Self {
            upstream,
            calls: AtomicUsize::new(0),
        }
    }
}

impl CellularOutboundConnector for LoopbackConnector {
    fn connect(&self, _target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        TcpStream::connect_timeout(&self.upstream, TEST_TIMEOUT)
            .map_err(|_| OutboundConnectError::Failed)
    }
}

fn credentials() -> BridgeCredentials {
    BridgeCredentials::new("stress-user".to_owned(), "stress-password".to_owned())
        .expect("valid stress credentials")
}

fn configure_stream(stream: &TcpStream) {
    stream
        .set_read_timeout(Some(TEST_TIMEOUT))
        .expect("set read timeout");
    stream
        .set_write_timeout(Some(TEST_TIMEOUT))
        .expect("set write timeout");
}

fn spawn_echo_server(session_count: usize) -> (SocketAddr, thread::JoinHandle<()>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("echo bind");
    let address = listener.local_addr().expect("echo address");
    let handle = thread::spawn(move || {
        let mut sessions = Vec::with_capacity(session_count);
        for _ in 0..session_count {
            let (mut stream, _) = listener.accept().expect("echo accept");
            configure_stream(&stream);
            sessions.push(thread::spawn(move || {
                let mut buffer = [0_u8; 128];
                loop {
                    let read = stream.read(&mut buffer).expect("echo read");
                    if read == 0 {
                        break;
                    }
                    stream.write_all(&buffer[..read]).expect("echo write");
                }
            }));
        }
        for session in sessions {
            session.join().expect("echo session");
        }
    });
    (address, handle)
}

fn spawn_bridge(
    connector: Arc<LoopbackConnector>,
    session_count: usize,
) -> (SocketAddr, thread::JoinHandle<usize>) {
    let bridge = Arc::new(
        BridgeListener::bind(IpAddr::V4(Ipv4Addr::LOCALHOST), 0, credentials())
            .expect("bridge bind"),
    );
    let address = bridge.local_addr().expect("bridge address");
    let handle = thread::spawn(move || {
        let mut sessions = Vec::with_capacity(session_count);
        for _ in 0..session_count {
            let (stream, peer) = bridge.accept().expect("bridge accept");
            assert!(peer.ip().is_loopback());
            configure_stream(&stream);
            let bridge = Arc::clone(&bridge);
            let connector = Arc::clone(&connector);
            sessions.push(thread::spawn(move || {
                bridge.serve_session(stream, connector.as_ref())
            }));
        }

        let mut successes = 0;
        for session in sessions {
            if session.join().expect("bridge session thread").is_ok() {
                successes += 1;
            }
        }
        successes
    });
    (address, handle)
}

fn authenticate(stream: &mut TcpStream, valid: bool) -> bool {
    stream
        .write_all(&[SOCKS_VERSION, 1, USERNAME_PASSWORD_METHOD])
        .expect("write greeting");
    let mut method = [0_u8; 2];
    stream.read_exact(&mut method).expect("read method");
    assert_eq!(method, [SOCKS_VERSION, USERNAME_PASSWORD_METHOD]);

    let username = b"stress-user";
    let password: &[u8] = if valid {
        b"stress-password"
    } else {
        b"wrong-password"
    };
    let mut auth = vec![USERNAME_PASSWORD_VERSION, username.len() as u8];
    auth.extend_from_slice(username);
    auth.push(password.len() as u8);
    auth.extend_from_slice(password);
    stream.write_all(&auth).expect("write auth");

    let mut reply = [0_u8; 2];
    stream.read_exact(&mut reply).expect("read auth reply");
    assert_eq!(reply[0], USERNAME_PASSWORD_VERSION);
    reply[1] == 0
}

fn request_connect(stream: &mut TcpStream) {
    stream
        .write_all(&[
            SOCKS_VERSION,
            CONNECT_COMMAND,
            0,
            IPV4_ADDRESS_TYPE,
            203,
            0,
            113,
            10,
            0x01,
            0xbb,
        ])
        .expect("write CONNECT");
    let mut reply = [0_u8; 10];
    stream.read_exact(&mut reply).expect("read CONNECT reply");
    assert_eq!(reply[0], SOCKS_VERSION);
    assert_eq!(reply[1], 0, "CONNECT failed");
    assert_eq!(reply[3], IPV4_ADDRESS_TYPE);
}

fn run_client(address: SocketAddr, client_id: usize, valid_auth: bool) -> bool {
    let mut stream = TcpStream::connect_timeout(&address, TEST_TIMEOUT).expect("connect bridge");
    configure_stream(&stream);
    let authenticated = authenticate(&mut stream, valid_auth);
    if !valid_auth {
        assert!(!authenticated, "invalid credentials were accepted");
        return false;
    }
    assert!(authenticated, "valid credentials were rejected");
    request_connect(&mut stream);

    let mut payload = [0_u8; 32];
    payload[..8].copy_from_slice(&(client_id as u64).to_be_bytes());
    payload[8..].fill((client_id % 251) as u8);
    stream.write_all(&payload).expect("write payload");
    let mut echoed = [0_u8; 32];
    stream.read_exact(&mut echoed).expect("read echoed payload");
    assert_eq!(echoed, payload);
    stream.shutdown(Shutdown::Both).expect("client shutdown");
    true
}

#[cfg(target_os = "linux")]
fn open_fd_count() -> usize {
    std::fs::read_dir("/proc/self/fd")
        .expect("read /proc/self/fd")
        .count()
}

#[cfg(not(target_os = "linux"))]
fn open_fd_count() -> usize {
    0
}

fn run_parallel_level(parallelism: usize) {
    let fd_before = open_fd_count();
    let started = Instant::now();
    let (upstream, echo_thread) = spawn_echo_server(parallelism);
    let connector = Arc::new(LoopbackConnector::new(upstream));
    let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector), parallelism);
    let barrier = Arc::new(Barrier::new(parallelism + 1));
    let mut clients = Vec::with_capacity(parallelism);

    for client_id in 0..parallelism {
        let barrier = Arc::clone(&barrier);
        clients.push(thread::spawn(move || {
            barrier.wait();
            run_client(bridge_address, client_id, true)
        }));
    }
    barrier.wait();

    for client in clients {
        assert!(client.join().expect("client thread"));
    }
    assert_eq!(bridge_thread.join().expect("bridge acceptor"), parallelism);
    echo_thread.join().expect("echo server");
    assert_eq!(connector.calls.load(Ordering::SeqCst), parallelism);
    assert!(
        started.elapsed() < Duration::from_secs(15),
        "parallel proxy level exceeded bounded acceptance window"
    );

    #[cfg(target_os = "linux")]
    {
        let fd_after = open_fd_count();
        assert!(
            fd_after <= fd_before + 2,
            "proxy stress leaked file descriptors: before={fd_before}, after={fd_after}"
        );
    }
}

fn run_auth_isolation_level(total: usize, invalid_every: usize) {
    let valid_count = (0..total)
        .filter(|client_id| client_id % invalid_every != 0)
        .count();
    let (upstream, echo_thread) = spawn_echo_server(valid_count);
    let connector = Arc::new(LoopbackConnector::new(upstream));
    let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector), total);
    let barrier = Arc::new(Barrier::new(total + 1));
    let mut clients = Vec::with_capacity(total);

    for client_id in 0..total {
        let barrier = Arc::clone(&barrier);
        clients.push(thread::spawn(move || {
            barrier.wait();
            let valid_auth = client_id % invalid_every != 0;
            run_client(bridge_address, client_id, valid_auth)
        }));
    }
    barrier.wait();

    let mut valid_successes = 0;
    for client in clients {
        if client.join().expect("auth-isolation client") {
            valid_successes += 1;
        }
    }
    assert_eq!(valid_successes, valid_count);
    assert_eq!(bridge_thread.join().expect("bridge acceptor"), valid_count);
    echo_thread.join().expect("echo server");
    assert_eq!(connector.calls.load(Ordering::SeqCst), valid_count);
}

#[test]
fn proxy_parallel_10_50_100_and_auth_isolation_are_deterministic() {
    for parallelism in [10_usize, 50, 100] {
        run_parallel_level(parallelism);
    }
    run_auth_isolation_level(50, 5);
}
