use std::fmt;
use std::io::{self, Write};
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpStream};
use std::thread;

use crate::{
    HttpConnectError, HttpConnectStreamError, MixedConnectError, ProxyConnectTarget,
    ProxyCredentialMaterial, ProxyProtocol, Socks5Reply, Socks5SessionError,
    accept_http_connect_stream, accept_mixed_connect, accept_socks5_connect, write_socks5_reply,
};

/// Consumer-owned outbound effect port. Proxy Serving supplies one authenticated unresolved
/// target; the implementation owns network admission, DNS, socket creation and routing effects.
pub trait ProxyOutboundConnector: Send + Sync {
    fn connect(
        &self,
        target: &ProxyConnectTarget,
    ) -> Result<TcpStream, ProxyOutboundConnectError>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyOutboundConnectError {
    Unavailable,
    Rejected,
    Failed,
}

impl fmt::Display for ProxyOutboundConnectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unavailable => "proxy outbound is unavailable",
            Self::Rejected => "proxy outbound target was rejected",
            Self::Failed => "proxy outbound connect failed",
        })
    }
}

impl std::error::Error for ProxyOutboundConnectError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProxyRelayStats {
    pub client_to_upstream: u64,
    pub upstream_to_client: u64,
}

#[derive(Debug)]
pub enum ProxySessionError {
    Io(io::Error),
    Http(HttpConnectStreamError),
    Mixed(MixedConnectError),
    Socks5(Socks5SessionError),
    Outbound(ProxyOutboundConnectError),
}

impl fmt::Display for ProxySessionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "proxy session I/O failed: {error}"),
            Self::Http(error) => write!(formatter, "proxy HTTP CONNECT session failed: {error}"),
            Self::Mixed(error) => write!(formatter, "proxy mixed session failed: {error}"),
            Self::Socks5(error) => write!(formatter, "proxy SOCKS5 session failed: {error}"),
            Self::Outbound(error) => write!(formatter, "proxy outbound failed: {error}"),
        }
    }
}

impl std::error::Error for ProxySessionError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            Self::Http(error) => Some(error),
            Self::Mixed(error) => Some(error),
            Self::Socks5(error) => Some(error),
            Self::Outbound(error) => Some(error),
        }
    }
}

impl From<io::Error> for ProxySessionError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Serves one already-accepted TCP stream using the canonical Proxy Serving protocol/auth owner,
/// one injected outbound effect port and one bounded bidirectional relay.
///
/// This function owns no listener, DNS, network selection, routing, root effect or lifecycle.
pub fn serve_proxy_session<C: ProxyOutboundConnector + ?Sized>(
    protocol: ProxyProtocol,
    client: TcpStream,
    credentials: &ProxyCredentialMaterial,
    connector: &C,
) -> Result<ProxyRelayStats, ProxySessionError> {
    let mut client = client;
    let result = serve_proxy_session_inner(protocol, &mut client, credentials, connector);
    if result.is_err() {
        let _ = client.shutdown(Shutdown::Write);
    }
    result
}

fn serve_proxy_session_inner<C: ProxyOutboundConnector + ?Sized>(
    protocol: ProxyProtocol,
    client: &mut TcpStream,
    credentials: &ProxyCredentialMaterial,
    connector: &C,
) -> Result<ProxyRelayStats, ProxySessionError> {
    let (wire_protocol, target) = accept_target(protocol, client, credentials)?;
    let upstream = match connector.connect(&target) {
        Ok(stream) => stream,
        Err(error) => {
            write_outbound_failure(client, wire_protocol, error)?;
            return Err(ProxySessionError::Outbound(error));
        }
    };

    write_connect_success(client, wire_protocol, &upstream)?;
    relay_bidirectional(client.try_clone()?, upstream).map_err(ProxySessionError::Io)
}

fn accept_target(
    protocol: ProxyProtocol,
    client: &mut TcpStream,
    credentials: &ProxyCredentialMaterial,
) -> Result<(ProxyProtocol, ProxyConnectTarget), ProxySessionError> {
    match protocol {
        ProxyProtocol::Mixed => match accept_mixed_connect(client, credentials) {
            Ok(result) => Ok(result),
            Err(error) => {
                if let MixedConnectError::Http(http) = &error {
                    write_http_protocol_failure(client, http)?;
                }
                Err(ProxySessionError::Mixed(error))
            }
        },
        ProxyProtocol::Socks5 => accept_socks5_connect(client, credentials)
            .map(|target| (ProxyProtocol::Socks5, target))
            .map_err(ProxySessionError::Socks5),
        ProxyProtocol::Http => match accept_http_connect_stream(client, credentials) {
            Ok(target) => Ok((ProxyProtocol::Http, target)),
            Err(error) => {
                write_http_protocol_failure(client, &error)?;
                Err(ProxySessionError::Http(error))
            }
        },
    }
}

fn write_connect_success(
    client: &mut TcpStream,
    protocol: ProxyProtocol,
    upstream: &TcpStream,
) -> io::Result<()> {
    match protocol {
        ProxyProtocol::Socks5 => {
            let bound = upstream
                .local_addr()
                .unwrap_or_else(|_| unspecified_bind_addr());
            write_socks5_reply(client, Socks5Reply::Succeeded, bound)
        }
        ProxyProtocol::Http => client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n"),
        ProxyProtocol::Mixed => Err(io::Error::other(
            "mixed protocol must resolve before connect response",
        )),
    }
}

fn write_outbound_failure(
    client: &mut TcpStream,
    protocol: ProxyProtocol,
    error: ProxyOutboundConnectError,
) -> io::Result<()> {
    match protocol {
        ProxyProtocol::Socks5 => write_socks5_reply(client, outbound_reply(error), unspecified_bind_addr()),
        ProxyProtocol::Http => client.write_all(match error {
            ProxyOutboundConnectError::Unavailable => {
                b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\n\r\n"
            }
            ProxyOutboundConnectError::Rejected => {
                b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n"
            }
            ProxyOutboundConnectError::Failed => {
                b"HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n"
            }
        }),
        ProxyProtocol::Mixed => Err(io::Error::other(
            "mixed protocol must resolve before outbound failure response",
        )),
    }
}

fn write_http_protocol_failure(
    client: &mut TcpStream,
    error: &HttpConnectStreamError,
) -> io::Result<()> {
    let HttpConnectStreamError::Protocol(error) = error else {
        return Ok(());
    };
    let response: &[u8] = match error {
        HttpConnectError::ProxyAuthenticationRequired | HttpConnectError::ProxyAuthenticationFailed => {
            b"HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"Mish\"\r\nConnection: close\r\n\r\n"
        }
        HttpConnectError::MethodNotAllowed => {
            b"HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n"
        }
        HttpConnectError::UnsupportedHttpVersion => {
            b"HTTP/1.1 505 HTTP Version Not Supported\r\nConnection: close\r\n\r\n"
        }
        HttpConnectError::HeaderTooLarge => {
            b"HTTP/1.1 431 Request Header Fields Too Large\r\nConnection: close\r\n\r\n"
        }
        HttpConnectError::IncompleteHeader
        | HttpConnectError::MalformedHeader
        | HttpConnectError::MalformedRequestLine
        | HttpConnectError::DuplicateProxyAuthorization
        | HttpConnectError::InvalidTarget
        | HttpConnectError::Target(_) => {
            b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n"
        }
    };
    client.write_all(response)
}

fn outbound_reply(error: ProxyOutboundConnectError) -> Socks5Reply {
    match error {
        ProxyOutboundConnectError::Unavailable => Socks5Reply::HostUnreachable,
        ProxyOutboundConnectError::Rejected => Socks5Reply::ConnectionNotAllowed,
        ProxyOutboundConnectError::Failed => Socks5Reply::GeneralFailure,
    }
}

fn unspecified_bind_addr() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)
}

fn relay_bidirectional(
    mut client: TcpStream,
    mut upstream: TcpStream,
) -> io::Result<ProxyRelayStats> {
    let mut client_reader = client.try_clone()?;
    let mut upstream_writer = upstream.try_clone()?;

    let client_to_upstream = thread::Builder::new()
        .name("mish-proxy-relay-upstream".to_owned())
        .spawn(move || -> io::Result<u64> {
            let copied = io::copy(&mut client_reader, &mut upstream_writer)?;
            upstream_writer.shutdown(Shutdown::Write)?;
            Ok(copied)
        })
        .map_err(|error| io::Error::other(format!("proxy relay worker unavailable: {error}")))?;

    let upstream_to_client = io::copy(&mut upstream, &mut client)?;
    client.shutdown(Shutdown::Write)?;

    let client_to_upstream = client_to_upstream
        .join()
        .map_err(|_| io::Error::other("proxy relay worker panicked"))??;

    Ok(ProxyRelayStats {
        client_to_upstream,
        upstream_to_client,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ProxyTargetHost;
    use std::io::{Read, Write};
    use std::net::{Ipv4Addr, TcpListener};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    const TEST_TIMEOUT: Duration = Duration::from_secs(5);

    #[derive(Debug)]
    struct LoopbackConnector {
        upstream: SocketAddr,
        calls: AtomicUsize,
        target: Mutex<Option<ProxyConnectTarget>>,
    }

    impl ProxyOutboundConnector for LoopbackConnector {
        fn connect(
            &self,
            target: &ProxyConnectTarget,
        ) -> Result<TcpStream, ProxyOutboundConnectError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            *self.target.lock().expect("target lock") = Some(target.clone());
            TcpStream::connect_timeout(&self.upstream, TEST_TIMEOUT)
                .map_err(|_| ProxyOutboundConnectError::Failed)
        }
    }

    #[derive(Debug)]
    struct UnavailableConnector {
        calls: AtomicUsize,
    }

    impl ProxyOutboundConnector for UnavailableConnector {
        fn connect(
            &self,
            _target: &ProxyConnectTarget,
        ) -> Result<TcpStream, ProxyOutboundConnectError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Err(ProxyOutboundConnectError::Unavailable)
        }
    }

    fn credentials() -> ProxyCredentialMaterial {
        ProxyCredentialMaterial::new("user", "password").expect("valid credentials")
    }

    fn configure(stream: &TcpStream) {
        stream
            .set_read_timeout(Some(TEST_TIMEOUT))
            .expect("read timeout");
        stream
            .set_write_timeout(Some(TEST_TIMEOUT))
            .expect("write timeout");
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

    #[test]
    fn http_session_composes_unresolved_target_outbound_and_relay() {
        let upstream_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("upstream bind");
        let upstream_address = upstream_listener.local_addr().expect("upstream address");
        let upstream = thread::spawn(move || {
            let (mut stream, _) = upstream_listener.accept().expect("upstream accept");
            configure(&stream);
            let mut payload = [0_u8; 12];
            stream.read_exact(&mut payload).expect("upstream payload");
            stream.write_all(&payload).expect("upstream echo");
        });

        let connector = Arc::new(LoopbackConnector {
            upstream: upstream_address,
            calls: AtomicUsize::new(0),
            target: Mutex::new(None),
        });
        let session_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("session bind");
        let session_address = session_listener.local_addr().expect("session address");
        let session_connector = Arc::clone(&connector);
        let session = thread::spawn(move || {
            let (stream, _) = session_listener.accept().expect("session accept");
            configure(&stream);
            serve_proxy_session(
                ProxyProtocol::Http,
                stream,
                &credentials(),
                session_connector.as_ref(),
            )
        });

        let mut client = TcpStream::connect_timeout(&session_address, TEST_TIMEOUT).expect("client");
        configure(&client);
        client
            .write_all(b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\nProxy-Authorization: Basic dXNlcjpwYXNzd29yZA==\r\n\r\ntunnel-bytes")
            .expect("request and tunnel bytes");
        let response = read_http_header(&mut client);
        assert!(response.starts_with(b"HTTP/1.1 200 Connection Established\r\n"));
        let mut echoed = [0_u8; 12];
        client.read_exact(&mut echoed).expect("echoed payload");
        assert_eq!(&echoed, b"tunnel-bytes");
        client.shutdown(Shutdown::Write).expect("client shutdown");

        let stats = session.join().expect("session thread").expect("session result");
        upstream.join().expect("upstream thread");
        assert_eq!(stats.client_to_upstream, 12);
        assert_eq!(stats.upstream_to_client, 12);
        assert_eq!(connector.calls.load(Ordering::SeqCst), 1);
        let target = connector
            .target
            .lock()
            .expect("target lock")
            .clone()
            .expect("captured target");
        assert_eq!(target.port(), 443);
        assert_eq!(
            target.host(),
            &ProxyTargetHost::Domain("example.invalid".into())
        );
        assert_eq!(target.host().numeric(), None);
    }

    #[test]
    fn http_auth_failure_never_reaches_outbound_connector() {
        let connector = Arc::new(UnavailableConnector {
            calls: AtomicUsize::new(0),
        });
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("session bind");
        let address = listener.local_addr().expect("session address");
        let session_connector = Arc::clone(&connector);
        let session = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("session accept");
            configure(&stream);
            serve_proxy_session(
                ProxyProtocol::Http,
                stream,
                &credentials(),
                session_connector.as_ref(),
            )
        });

        let mut client = TcpStream::connect_timeout(&address, TEST_TIMEOUT).expect("client");
        configure(&client);
        client
            .write_all(b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\n\r\n")
            .expect("unauthenticated request");
        let response = read_http_header(&mut client);
        assert!(response.starts_with(b"HTTP/1.1 407 Proxy Authentication Required\r\n"));
        assert!(session.join().expect("session thread").is_err());
        assert_eq!(connector.calls.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn http_outbound_unavailable_is_fail_closed_before_relay() {
        let connector = Arc::new(UnavailableConnector {
            calls: AtomicUsize::new(0),
        });
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("session bind");
        let address = listener.local_addr().expect("session address");
        let session_connector = Arc::clone(&connector);
        let session = thread::spawn(move || {
            let (stream, _) = listener.accept().expect("session accept");
            configure(&stream);
            serve_proxy_session(
                ProxyProtocol::Http,
                stream,
                &credentials(),
                session_connector.as_ref(),
            )
        });

        let mut client = TcpStream::connect_timeout(&address, TEST_TIMEOUT).expect("client");
        configure(&client);
        client
            .write_all(b"CONNECT example.invalid:443 HTTP/1.1\r\nHost: example.invalid:443\r\nProxy-Authorization: Basic dXNlcjpwYXNzd29yZA==\r\n\r\n")
            .expect("authenticated request");
        let response = read_http_header(&mut client);
        assert!(response.starts_with(b"HTTP/1.1 503 Service Unavailable\r\n"));
        assert!(session.join().expect("session thread").is_err());
        assert_eq!(connector.calls.load(Ordering::SeqCst), 1);
    }
}
