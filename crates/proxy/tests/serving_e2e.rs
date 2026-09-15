use mish_proxy::{
    ProxyConnectTarget, ProxyCredentialMaterial, ProxyOutboundConnectError, ProxyOutboundConnector,
    ProxyProtocol, ProxyTargetHost, serve_proxy_session,
};
use std::io::{Read, Write};
use std::net::{Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const ACCEPTED_PARALLEL_SESSIONS: usize = 64;
const TEST_TIMEOUT: Duration = Duration::from_secs(5);
const TARGET_DOMAIN: &str = "example.invalid";
const TARGET_PORT: u16 = 443;

#[derive(Debug)]
struct LoopbackConnector {
    upstream: SocketAddr,
    calls: AtomicUsize,
    targets: Mutex<Vec<ProxyConnectTarget>>,
}

impl ProxyOutboundConnector for LoopbackConnector {
    fn connect(
        &self,
        target: &ProxyConnectTarget,
    ) -> Result<TcpStream, ProxyOutboundConnectError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        self.targets
            .lock()
            .expect("target lock")
            .push(target.clone());
        TcpStream::connect_timeout(&self.upstream, TEST_TIMEOUT)
            .map_err(|_| ProxyOutboundConnectError::Failed)
    }
}

#[derive(Debug, Default)]
struct CountingUnavailableConnector {
    calls: AtomicUsize,
}

impl ProxyOutboundConnector for CountingUnavailableConnector {
    fn connect(
        &self,
        _target: &ProxyConnectTarget,
    ) -> Result<TcpStream, ProxyOutboundConnectError> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Err(ProxyOutboundConnectError::Unavailable)
    }
}

fn credentials() -> ProxyCredentialMaterial {
    ProxyCredentialMaterial::new("user", "password").expect("valid hosted credentials")
}

fn configure(stream: &TcpStream) {
    stream
        .set_read_timeout(Some(TEST_TIMEOUT))
        .expect("read timeout");
    stream
        .set_write_timeout(Some(TEST_TIMEOUT))
        .expect("write timeout");
}

fn spawn_echo_server(session_count: usize) -> (SocketAddr, thread::JoinHandle<()>) {
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("echo bind");
    let address = listener.local_addr().expect("echo address");
    let handle = thread::spawn(move || {
        let mut sessions = Vec::with_capacity(session_count);
        for _ in 0..session_count {
            let (mut stream, _) = listener.accept().expect("echo accept");
            configure(&stream);
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

fn spawn_proxy_server<C>(
    protocol: ProxyProtocol,
    connector: Arc<C>,
    session_count: usize,
) -> (SocketAddr, thread::JoinHandle<usize>)
where
    C: ProxyOutboundConnector + 'static,
{
    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("proxy bind");
    let address = listener.local_addr().expect("proxy address");
    let handle = thread::spawn(move || {
        let mut sessions = Vec::with_capacity(session_count);
        for _ in 0..session_count {
            let (stream, _) = listener.accept().expect("proxy accept");
            configure(&stream);
            let connector = Arc::clone(&connector);
            sessions.push(thread::spawn(move || {
                serve_proxy_session(protocol, stream, &credentials(), connector.as_ref()).is_ok()
            }));
        }
        sessions
            .into_iter()
            .filter(|session| session.join().expect("proxy session"))
            .count()
    });
    (address, handle)
}

fn payload(client_id: usize) -> [u8; 32] {
    let mut bytes = [0_u8; 32];
    bytes[..8].copy_from_slice(&(client_id as u64).to_be_bytes());
    bytes[8..].fill((client_id % 251) as u8);
    bytes
}

fn read_http_header(stream: &mut TcpStream) -> Vec<u8> {
    let mut response = Vec::new();
    while !response.ends_with(b"\r\n\r\n") {
        let mut byte = [0_u8; 1];
        stream.read_exact(&mut byte).expect("HTTP response byte");
        response.push(byte[0]);
    }
    response
}

fn run_http_client(address: SocketAddr, client_id: usize, valid_auth: bool) -> bool {
    let mut stream = TcpStream::connect_timeout(&address, TEST_TIMEOUT).expect("HTTP connect");
    configure(&stream);

    if !valid_auth {
        stream
            .write_all(
                b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\n\r\n",
            )
            .expect("unauthenticated HTTP request");
        let response = read_http_header(&mut stream);
        assert!(response.starts_with(b"HTTP/1.1 407 Proxy Authentication Required\r\n"));
        return false;
    }

    let payload = payload(client_id);
    let mut request = b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\nProxy-Authorization: Basic dXNlcjpwYXNzd29yZA==\r\n\r\n".to_vec();
    request.extend_from_slice(&payload);
    stream.write_all(&request).expect("HTTP request and payload");
    let response = read_http_header(&mut stream);
    assert!(response.starts_with(b"HTTP/1.1 200 Connection Established\r\n"));
    let mut echoed = [0_u8; 32];
    stream.read_exact(&mut echoed).expect("HTTP echoed payload");
    assert_eq!(echoed, payload);
    stream.shutdown(Shutdown::Write).expect("HTTP half-close");
    true
}

fn run_socks5_client(address: SocketAddr, client_id: usize, valid_auth: bool) -> bool {
    let mut stream = TcpStream::connect_timeout(&address, TEST_TIMEOUT).expect("SOCKS5 connect");
    configure(&stream);
    stream
        .write_all(&[0x05, 0x01, 0x02])
        .expect("SOCKS5 greeting");
    let mut method = [0_u8; 2];
    stream.read_exact(&mut method).expect("SOCKS5 method");
    assert_eq!(method, [0x05, 0x02]);

    let password: &[u8] = if valid_auth { b"password" } else { b"wrong" };
    let mut auth = vec![0x01, 4];
    auth.extend_from_slice(b"user");
    auth.push(password.len() as u8);
    auth.extend_from_slice(password);
    stream.write_all(&auth).expect("SOCKS5 auth");
    let mut auth_reply = [0_u8; 2];
    stream.read_exact(&mut auth_reply).expect("SOCKS5 auth reply");
    assert_eq!(auth_reply[0], 0x01);
    if !valid_auth {
        assert_ne!(auth_reply[1], 0x00);
        return false;
    }
    assert_eq!(auth_reply[1], 0x00);

    let payload = payload(client_id);
    let mut request = vec![0x05, 0x01, 0x00, 0x03, TARGET_DOMAIN.len() as u8];
    request.extend_from_slice(TARGET_DOMAIN.as_bytes());
    request.extend_from_slice(&TARGET_PORT.to_be_bytes());
    request.extend_from_slice(&payload);
    stream.write_all(&request).expect("SOCKS5 request and payload");
    let mut reply = [0_u8; 10];
    stream.read_exact(&mut reply).expect("SOCKS5 connect reply");
    assert_eq!(reply[0], 0x05);
    assert_eq!(reply[1], 0x00);
    assert_eq!(reply[3], 0x01);
    let mut echoed = [0_u8; 32];
    stream.read_exact(&mut echoed).expect("SOCKS5 echoed payload");
    assert_eq!(echoed, payload);
    stream
        .shutdown(Shutdown::Write)
        .expect("SOCKS5 half-close");
    true
}

#[cfg(target_os = "linux")]
fn open_fd_count() -> usize {
    std::fs::read_dir("/proc/self/fd")
        .expect("read /proc/self/fd")
        .count()
}

#[test]
fn mixed_path_holds_64_parallel_sessions_and_cleans_up() {
    #[cfg(target_os = "linux")]
    let fd_before = open_fd_count();
    let started = Instant::now();
    let (upstream, echo_server) = spawn_echo_server(ACCEPTED_PARALLEL_SESSIONS);
    let connector = Arc::new(LoopbackConnector {
        upstream,
        calls: AtomicUsize::new(0),
        targets: Mutex::new(Vec::new()),
    });
    let (proxy_address, proxy_server) = spawn_proxy_server(
        ProxyProtocol::Mixed,
        Arc::clone(&connector),
        ACCEPTED_PARALLEL_SESSIONS,
    );
    let barrier = Arc::new(Barrier::new(ACCEPTED_PARALLEL_SESSIONS + 1));
    let mut clients = Vec::with_capacity(ACCEPTED_PARALLEL_SESSIONS);

    for client_id in 0..ACCEPTED_PARALLEL_SESSIONS {
        let barrier = Arc::clone(&barrier);
        clients.push(thread::spawn(move || {
            barrier.wait();
            if client_id % 2 == 0 {
                run_http_client(proxy_address, client_id, true)
            } else {
                run_socks5_client(proxy_address, client_id, true)
            }
        }));
    }
    barrier.wait();
    for client in clients {
        assert!(client.join().expect("hosted client"));
    }

    assert_eq!(
        proxy_server.join().expect("proxy server"),
        ACCEPTED_PARALLEL_SESSIONS
    );
    echo_server.join().expect("echo server");
    assert_eq!(
        connector.calls.load(Ordering::SeqCst),
        ACCEPTED_PARALLEL_SESSIONS
    );
    let targets = connector.targets.lock().expect("targets lock");
    assert_eq!(targets.len(), ACCEPTED_PARALLEL_SESSIONS);
    for target in targets.iter() {
        assert_eq!(target.port(), TARGET_PORT);
        assert_eq!(
            target.host(),
            &ProxyTargetHost::Domain(TARGET_DOMAIN.into())
        );
        assert_eq!(target.host().numeric(), None);
    }
    drop(targets);
    assert!(
        started.elapsed() < Duration::from_secs(15),
        "64-session hosted proxy evidence exceeded the bounded window"
    );

    #[cfg(target_os = "linux")]
    {
        let fd_after = open_fd_count();
        assert!(
            fd_after <= fd_before + 2,
            "in-process proxy leaked file descriptors: before={fd_before}, after={fd_after}"
        );
    }
}

#[test]
fn dedicated_protocols_match_and_invalid_auth_never_reaches_outbound() {
    let (upstream, echo_server) = spawn_echo_server(2);
    let connector = Arc::new(LoopbackConnector {
        upstream,
        calls: AtomicUsize::new(0),
        targets: Mutex::new(Vec::new()),
    });
    let (http_address, http_server) =
        spawn_proxy_server(ProxyProtocol::Http, Arc::clone(&connector), 1);
    let (socks_address, socks_server) =
        spawn_proxy_server(ProxyProtocol::Socks5, Arc::clone(&connector), 1);
    assert!(run_http_client(http_address, 100, true));
    assert!(run_socks5_client(socks_address, 101, true));
    assert_eq!(http_server.join().expect("HTTP server"), 1);
    assert_eq!(socks_server.join().expect("SOCKS5 server"), 1);
    echo_server.join().expect("echo server");
    assert_eq!(connector.calls.load(Ordering::SeqCst), 2);

    let blocked = Arc::new(CountingUnavailableConnector::default());
    let (bad_http, bad_http_server) =
        spawn_proxy_server(ProxyProtocol::Http, Arc::clone(&blocked), 1);
    let (bad_socks, bad_socks_server) =
        spawn_proxy_server(ProxyProtocol::Socks5, Arc::clone(&blocked), 1);
    let (bad_mixed, bad_mixed_server) =
        spawn_proxy_server(ProxyProtocol::Mixed, Arc::clone(&blocked), 2);
    assert!(!run_http_client(bad_http, 200, false));
    assert!(!run_socks5_client(bad_socks, 201, false));
    assert!(!run_http_client(bad_mixed, 202, false));
    assert!(!run_socks5_client(bad_mixed, 203, false));
    assert_eq!(bad_http_server.join().expect("bad HTTP server"), 0);
    assert_eq!(bad_socks_server.join().expect("bad SOCKS5 server"), 0);
    assert_eq!(bad_mixed_server.join().expect("bad mixed server"), 0);
    assert_eq!(blocked.calls.load(Ordering::SeqCst), 0);
}
