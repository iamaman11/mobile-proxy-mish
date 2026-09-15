//! Loopback-only TCP/relay adapter into the Cellular Egress capability.
//!
//! SOCKS5 framing, authentication, request decoding and reply encoding belong to
//! `mish-proxy`. This crate owns only the temporary loopback listener/relay mechanics
//! required while PRODUCT is still migrating away from the external sing-box child.

use mish_proxy::{
    ProxyConnectTarget, ProxyCredentialMaterial, ProxyTargetHost, Socks5ProtocolError,
    Socks5Reply, Socks5SessionError, accept_socks5_connect, write_socks5_reply,
};
use std::fmt;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::thread;

const MAX_AUTH_FIELD_LEN: usize = u8::MAX as usize;

pub use mish_proxy::{
    ProxyConnectTarget as ConnectTarget, ProxyTargetHost as TargetHost,
    Socks5ProtocolError as ProtocolError,
};

/// Runtime-generation credentials retained only as a compatibility façade for the
/// temporary loopback bridge. Authentication semantics are owned by `mish-proxy`.
#[derive(Clone, PartialEq, Eq)]
pub struct BridgeCredentials {
    material: ProxyCredentialMaterial,
}

impl BridgeCredentials {
    pub fn new(username: String, password: String) -> Result<Self, BridgeConfigError> {
        validate_auth_field(&username, BridgeConfigError::InvalidUsername)?;
        validate_auth_field(&password, BridgeConfigError::InvalidPassword)?;
        if username.trim().is_empty() {
            return Err(BridgeConfigError::InvalidUsername);
        }
        if password.trim().is_empty() {
            return Err(BridgeConfigError::InvalidPassword);
        }
        let material = ProxyCredentialMaterial::new(username, password).map_err(|_| {
            BridgeConfigError::InvalidUsername
        })?;
        Ok(Self { material })
    }

    fn material(&self) -> &ProxyCredentialMaterial {
        &self.material
    }
}

impl fmt::Debug for BridgeCredentials {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("BridgeCredentials")
            .field("username", &"<redacted>")
            .field("password", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeConfigError {
    NonLoopbackAddress,
    InvalidUsername,
    InvalidPassword,
}

impl fmt::Display for BridgeConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::NonLoopbackAddress => "cellular egress bridge must bind loopback only",
            Self::InvalidUsername => "bridge username must contain 1..=255 bytes",
            Self::InvalidPassword => "bridge password must contain 1..=255 bytes",
        })
    }
}

impl std::error::Error for BridgeConfigError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutboundConnectError {
    Unavailable,
    Rejected,
    Failed,
}

impl fmt::Display for OutboundConnectError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::Unavailable => "cellular outbound is unavailable",
            Self::Rejected => "cellular outbound target was rejected",
            Self::Failed => "cellular outbound connect failed",
        })
    }
}

impl std::error::Error for OutboundConnectError {}

/// Consumer-owned effect port. Domain resolution remains below this boundary and must
/// happen only after Cellular Egress issued the current cellular network authority.
pub trait CellularOutboundConnector: Send + Sync {
    fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError>;
}

#[derive(Debug)]
pub enum SessionError {
    Io(io::Error),
    Protocol(ProtocolError),
    Outbound(OutboundConnectError),
}

impl fmt::Display for SessionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "bridge I/O failed: {error}"),
            Self::Protocol(error) => write!(formatter, "bridge protocol failed: {error}"),
            Self::Outbound(error) => write!(formatter, "bridge outbound failed: {error}"),
        }
    }
}

impl std::error::Error for SessionError {}

impl From<io::Error> for SessionError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<Socks5SessionError> for SessionError {
    fn from(error: Socks5SessionError) -> Self {
        match error {
            Socks5SessionError::Io(error) => Self::Io(error),
            Socks5SessionError::Protocol(error) => Self::Protocol(error),
        }
    }
}

impl From<Socks5ProtocolError> for SessionError {
    fn from(error: Socks5ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RelayStats {
    pub client_to_upstream: u64,
    pub upstream_to_client: u64,
}

/// Temporary loopback adapter. It owns neither protocol policy nor surrounding lifecycle.
#[derive(Debug)]
pub struct BridgeListener {
    listener: TcpListener,
    credentials: BridgeCredentials,
}

impl BridgeListener {
    pub fn bind(
        address: IpAddr,
        port: u16,
        credentials: BridgeCredentials,
    ) -> Result<Self, BridgeBindError> {
        if !address.is_loopback() {
            return Err(BridgeBindError::Config(
                BridgeConfigError::NonLoopbackAddress,
            ));
        }
        let listener =
            TcpListener::bind(SocketAddr::new(address, port)).map_err(BridgeBindError::Io)?;
        Ok(Self {
            listener,
            credentials,
        })
    }

    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.listener.local_addr()
    }

    pub fn accept(&self) -> io::Result<(TcpStream, SocketAddr)> {
        self.listener.accept()
    }

    pub fn serve_session<C: CellularOutboundConnector + ?Sized>(
        &self,
        client: TcpStream,
        connector: &C,
    ) -> Result<RelayStats, SessionError> {
        let mut client = client;
        let result = self.serve_session_inner(&mut client, connector);
        if result.is_err() {
            let _ = client.shutdown(Shutdown::Write);
        }
        result
    }

    fn serve_session_inner<C: CellularOutboundConnector + ?Sized>(
        &self,
        client: &mut TcpStream,
        connector: &C,
    ) -> Result<RelayStats, SessionError> {
        let target = accept_socks5_connect(client, self.credentials.material())?;
        let upstream = match connector.connect(&target) {
            Ok(stream) => stream,
            Err(error) => {
                write_socks5_reply(client, outbound_reply(error), unspecified_bind_addr())?;
                return Err(SessionError::Outbound(error));
            }
        };

        let bound = upstream
            .local_addr()
            .unwrap_or_else(|_| unspecified_bind_addr());
        write_socks5_reply(client, Socks5Reply::Succeeded, bound)?;
        relay_bidirectional(client.try_clone()?, upstream).map_err(SessionError::Io)
    }
}

#[derive(Debug)]
pub enum BridgeBindError {
    Config(BridgeConfigError),
    Io(io::Error),
}

impl fmt::Display for BridgeBindError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Config(error) => write!(formatter, "bridge bind rejected: {error}"),
            Self::Io(error) => write!(formatter, "bridge bind failed: {error}"),
        }
    }
}

impl std::error::Error for BridgeBindError {}

fn validate_auth_field(value: &str, error: BridgeConfigError) -> Result<(), BridgeConfigError> {
    if value.is_empty() || value.len() > MAX_AUTH_FIELD_LEN {
        Err(error)
    } else {
        Ok(())
    }
}

fn outbound_reply(error: OutboundConnectError) -> Socks5Reply {
    match error {
        OutboundConnectError::Unavailable => Socks5Reply::HostUnreachable,
        OutboundConnectError::Rejected => Socks5Reply::ConnectionNotAllowed,
        OutboundConnectError::Failed => Socks5Reply::GeneralFailure,
    }
}

fn unspecified_bind_addr() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)
}

fn relay_bidirectional(mut client: TcpStream, mut upstream: TcpStream) -> io::Result<RelayStats> {
    let mut client_reader = client.try_clone()?;
    let mut upstream_writer = upstream.try_clone()?;

    let client_to_upstream = thread::spawn(move || -> io::Result<u64> {
        let copied = io::copy(&mut client_reader, &mut upstream_writer)?;
        upstream_writer.shutdown(Shutdown::Write)?;
        Ok(copied)
    });

    let upstream_to_client = io::copy(&mut upstream, &mut client)?;
    client.shutdown(Shutdown::Write)?;

    let client_to_upstream = client_to_upstream
        .join()
        .map_err(|_| io::Error::other("bridge relay worker panicked"))??;

    Ok(RelayStats {
        client_to_upstream,
        upstream_to_client,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::{Ipv6Addr, Shutdown};
    use std::sync::{Arc, Mutex};

    const SOCKS_VERSION: u8 = 0x05;
    const USERNAME_PASSWORD_METHOD: u8 = 0x02;
    const USERNAME_PASSWORD_VERSION: u8 = 0x01;
    const CONNECT_COMMAND: u8 = 0x01;
    const IPV4_ADDRESS_TYPE: u8 = 0x01;
    const DOMAIN_ADDRESS_TYPE: u8 = 0x03;
    const IPV6_ADDRESS_TYPE: u8 = 0x04;

    #[derive(Debug)]
    struct RecordingConnector {
        target: Mutex<Option<ConnectTarget>>,
        upstream: SocketAddr,
        failure: Option<OutboundConnectError>,
    }

    impl RecordingConnector {
        fn success(upstream: SocketAddr) -> Self {
            Self {
                target: Mutex::new(None),
                upstream,
                failure: None,
            }
        }

        fn failure(error: OutboundConnectError) -> Self {
            Self {
                target: Mutex::new(None),
                upstream: "127.0.0.1:9".parse().expect("static socket address"),
                failure: Some(error),
            }
        }

        fn observed_target(&self) -> Option<ConnectTarget> {
            self.target.lock().expect("target mutex").clone()
        }
    }

    impl CellularOutboundConnector for RecordingConnector {
        fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
            *self.target.lock().expect("target mutex") = Some(target.clone());
            if let Some(error) = self.failure {
                return Err(error);
            }
            TcpStream::connect(self.upstream).map_err(|_| OutboundConnectError::Failed)
        }
    }

    fn credentials() -> BridgeCredentials {
        BridgeCredentials::new("internal-user".to_owned(), "internal-password".to_owned())
            .expect("valid credentials")
    }

    fn spawn_echo_server() -> (SocketAddr, thread::JoinHandle<()>) {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("echo listener");
        let address = listener.local_addr().expect("echo address");
        let handle = thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("echo accept");
            let mut buffer = [0_u8; 4096];
            loop {
                let read = stream.read(&mut buffer).expect("echo read");
                if read == 0 {
                    break;
                }
                stream.write_all(&buffer[..read]).expect("echo write");
            }
        });
        (address, handle)
    }

    fn spawn_bridge(
        connector: Arc<RecordingConnector>,
    ) -> (
        SocketAddr,
        thread::JoinHandle<Result<RelayStats, SessionError>>,
    ) {
        let bridge = Arc::new(
            BridgeListener::bind(IpAddr::V4(Ipv4Addr::LOCALHOST), 0, credentials())
                .expect("bridge bind"),
        );
        let address = bridge.local_addr().expect("bridge address");
        let handle = thread::spawn(move || {
            let (stream, peer) = bridge.accept().expect("bridge accept");
            assert!(peer.ip().is_loopback());
            bridge.serve_session(stream, connector.as_ref())
        });
        (address, handle)
    }

    fn connect_and_authenticate(address: SocketAddr) -> TcpStream {
        let mut stream = TcpStream::connect(address).expect("connect bridge");
        stream
            .write_all(&[SOCKS_VERSION, 1, USERNAME_PASSWORD_METHOD])
            .expect("write greeting");
        let mut method = [0_u8; 2];
        stream.read_exact(&mut method).expect("read method");
        assert_eq!(method, [SOCKS_VERSION, USERNAME_PASSWORD_METHOD]);

        let username = b"internal-user";
        let password = b"internal-password";
        let mut auth = vec![USERNAME_PASSWORD_VERSION, username.len() as u8];
        auth.extend_from_slice(username);
        auth.push(password.len() as u8);
        auth.extend_from_slice(password);
        stream.write_all(&auth).expect("write auth");

        let mut auth_reply = [0_u8; 2];
        stream.read_exact(&mut auth_reply).expect("read auth reply");
        assert_eq!(auth_reply, [USERNAME_PASSWORD_VERSION, 0]);
        stream
    }

    fn read_reply(stream: &mut TcpStream) -> u8 {
        let mut header = [0_u8; 4];
        stream.read_exact(&mut header).expect("read reply header");
        match header[3] {
            IPV4_ADDRESS_TYPE => {
                let mut rest = [0_u8; 6];
                stream.read_exact(&mut rest).expect("read IPv4 reply");
            }
            IPV6_ADDRESS_TYPE => {
                let mut rest = [0_u8; 18];
                stream.read_exact(&mut rest).expect("read IPv6 reply");
            }
            other => panic!("unexpected reply address type {other}"),
        }
        header[1]
    }

    #[test]
    fn credentials_debug_output_is_redacted() {
        let rendered = format!("{:?}", credentials());
        assert!(!rendered.contains("internal-user"));
        assert!(!rendered.contains("internal-password"));
        assert!(rendered.contains("<redacted>"));
    }

    #[test]
    fn credentials_reject_empty_or_oversized_fields() {
        assert_eq!(
            BridgeCredentials::new(String::new(), "password".to_owned()),
            Err(BridgeConfigError::InvalidUsername)
        );
        assert_eq!(
            BridgeCredentials::new("user".to_owned(), String::new()),
            Err(BridgeConfigError::InvalidPassword)
        );
        assert_eq!(
            BridgeCredentials::new("x".repeat(256), "password".to_owned()),
            Err(BridgeConfigError::InvalidUsername)
        );
    }

    #[test]
    fn non_loopback_bind_is_rejected_before_os_bind() {
        let result = BridgeListener::bind(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0, credentials());
        assert!(matches!(
            result,
            Err(BridgeBindError::Config(
                BridgeConfigError::NonLoopbackAddress
            ))
        ));
    }

    #[test]
    fn authenticated_ipv4_connect_relays_bytes() {
        let (echo_address, echo_thread) = spawn_echo_server();
        let connector = Arc::new(RecordingConnector::success(echo_address));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));

        let mut client = connect_and_authenticate(bridge_address);
        client
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
        assert_eq!(read_reply(&mut client), 0x00);

        client.write_all(b"bridge-ok").expect("write payload");
        client.shutdown(Shutdown::Write).expect("client shutdown");
        let mut response = Vec::new();
        client.read_to_end(&mut response).expect("read echo");
        assert_eq!(response, b"bridge-ok");

        let stats = bridge_thread.join().expect("bridge thread").expect("bridge session");
        echo_thread.join().expect("echo thread");
        assert_eq!(stats.client_to_upstream, 9);
        assert_eq!(stats.upstream_to_client, 9);
        assert_eq!(
            connector.observed_target(),
            Some(ProxyConnectTarget::ipv4(Ipv4Addr::new(203, 0, 113, 10), 443).expect("target"))
        );
    }

    #[test]
    fn domain_and_ipv6_remain_typed_without_bridge_dns() {
        let connector = Arc::new(RecordingConnector::failure(
            OutboundConnectError::Unavailable,
        ));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut client = connect_and_authenticate(bridge_address);
        let domain = b"example.invalid";
        let mut request = vec![
            SOCKS_VERSION,
            CONNECT_COMMAND,
            0,
            DOMAIN_ADDRESS_TYPE,
            domain.len() as u8,
        ];
        request.extend_from_slice(domain);
        request.extend_from_slice(&443_u16.to_be_bytes());
        client.write_all(&request).expect("write domain CONNECT");
        assert_eq!(read_reply(&mut client), 0x04);
        assert!(matches!(
            bridge_thread.join().expect("bridge thread"),
            Err(SessionError::Outbound(OutboundConnectError::Unavailable))
        ));
        assert_eq!(
            connector.observed_target(),
            Some(ProxyConnectTarget::domain("example.invalid", 443).expect("target"))
        );

        let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Failed));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut client = connect_and_authenticate(bridge_address);
        let address = Ipv6Addr::LOCALHOST;
        let mut request = vec![SOCKS_VERSION, CONNECT_COMMAND, 0, IPV6_ADDRESS_TYPE];
        request.extend_from_slice(&address.octets());
        request.extend_from_slice(&8443_u16.to_be_bytes());
        client.write_all(&request).expect("write IPv6 CONNECT");
        assert_eq!(read_reply(&mut client), 0x01);
        assert!(matches!(
            bridge_thread.join().expect("bridge thread"),
            Err(SessionError::Outbound(OutboundConnectError::Failed))
        ));
        assert_eq!(
            connector.observed_target(),
            Some(ProxyConnectTarget::ipv6(address, 8443).expect("target"))
        );
    }

    #[test]
    fn wrong_authentication_fails_before_connector_invocation() {
        let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Failed));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut client = TcpStream::connect(bridge_address).expect("connect bridge");
        client
            .write_all(&[SOCKS_VERSION, 1, USERNAME_PASSWORD_METHOD])
            .expect("write greeting");
        let mut method = [0_u8; 2];
        client.read_exact(&mut method).expect("read method");
        assert_eq!(method, [SOCKS_VERSION, USERNAME_PASSWORD_METHOD]);
        client
            .write_all(&[
                USERNAME_PASSWORD_VERSION,
                4,
                b'u',
                b's',
                b'e',
                b'r',
                5,
                b'w',
                b'r',
                b'o',
                b'n',
                b'g',
            ])
            .expect("write wrong auth");
        let mut reply = [0_u8; 2];
        client.read_exact(&mut reply).expect("read auth failure");
        assert_eq!(reply, [USERNAME_PASSWORD_VERSION, 1]);
        assert!(matches!(
            bridge_thread.join().expect("bridge thread"),
            Err(SessionError::Protocol(ProtocolError::AuthenticationFailed))
        ));
        assert_eq!(connector.observed_target(), None);
    }
}
