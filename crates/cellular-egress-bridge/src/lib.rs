//! Loopback-only SOCKS5 adapter into the Cellular Egress capability.
//!
//! This crate owns no cellular state and no long-lived runtime lifecycle. It owns
//! only the bounded internal SOCKS5 protocol/session semantics needed for sing-box
//! to hand one CONNECT stream to a consumer-owned Cellular Egress connector port.

use std::fmt;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::thread;

const SOCKS_VERSION: u8 = 0x05;
const USERNAME_PASSWORD_METHOD: u8 = 0x02;
const NO_ACCEPTABLE_METHODS: u8 = 0xff;
const USERNAME_PASSWORD_VERSION: u8 = 0x01;
const CONNECT_COMMAND: u8 = 0x01;
const BIND_COMMAND: u8 = 0x02;
const UDP_ASSOCIATE_COMMAND: u8 = 0x03;
const IPV4_ADDRESS_TYPE: u8 = 0x01;
const DOMAIN_ADDRESS_TYPE: u8 = 0x03;
const IPV6_ADDRESS_TYPE: u8 = 0x04;
const REPLY_SUCCEEDED: u8 = 0x00;
const REPLY_GENERAL_FAILURE: u8 = 0x01;
const REPLY_NOT_ALLOWED: u8 = 0x02;
const REPLY_HOST_UNREACHABLE: u8 = 0x04;
const REPLY_COMMAND_NOT_SUPPORTED: u8 = 0x07;
const REPLY_ADDRESS_TYPE_NOT_SUPPORTED: u8 = 0x08;
const MAX_AUTH_FIELD_LEN: usize = u8::MAX as usize;

/// Runtime-generation credentials for the private loopback SOCKS5 bridge.
#[derive(Clone, PartialEq, Eq)]
pub struct BridgeCredentials {
    username: Box<str>,
    password: Box<str>,
}

impl BridgeCredentials {
    /// Creates non-empty RFC1929-compatible bridge credentials.
    pub fn new(username: String, password: String) -> Result<Self, BridgeConfigError> {
        validate_auth_field(&username, BridgeConfigError::InvalidUsername)?;
        validate_auth_field(&password, BridgeConfigError::InvalidPassword)?;

        Ok(Self {
            username: username.into_boxed_str(),
            password: password.into_boxed_str(),
        })
    }

    fn matches(&self, username: &[u8], password: &[u8]) -> bool {
        constant_time_eq(self.username.as_bytes(), username)
            & constant_time_eq(self.password.as_bytes(), password)
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

/// Configuration failures rejected before the bridge can listen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BridgeConfigError {
    /// The listener address was not loopback.
    NonLoopbackAddress,
    /// The username was empty or too long for RFC1929.
    InvalidUsername,
    /// The password was empty or too long for RFC1929.
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

/// One typed destination requested by the internal SOCKS5 client.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConnectTarget {
    host: TargetHost,
    port: u16,
}

impl ConnectTarget {
    /// Returns the destination host without resolving it.
    pub const fn host(&self) -> &TargetHost {
        &self.host
    }

    /// Returns the requested TCP destination port.
    pub const fn port(&self) -> u16 {
        self.port
    }
}

/// Host representation preserved across the bridge/outbound boundary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TargetHost {
    /// Numeric IPv4 destination. No DNS is required.
    Ipv4(Ipv4Addr),
    /// Numeric IPv6 destination. No DNS is required.
    Ipv6(Ipv6Addr),
    /// Domain destination. Resolution belongs to the exact-network connector.
    Domain(Box<str>),
}

/// Bounded failures returned by the consumer-owned cellular outbound port.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutboundConnectError {
    /// No admissible cellular authority is currently available.
    Unavailable,
    /// Policy rejected the requested target.
    Rejected,
    /// An admitted outbound attempt failed.
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

/// Consumer-owned port used by the bridge to request one cellular-bound TCP stream.
///
/// Implementations must preserve the Cellular Egress invariants. In particular, a
/// domain target must not be resolved through the process/default network before the
/// implementation has acquired the exact owner-issued cellular authority.
pub trait CellularOutboundConnector: Send + Sync {
    /// Connects one typed target or fails closed without a default-network fallback.
    fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError>;
}

/// Protocol failures for one SOCKS5 session.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProtocolError {
    /// The client did not speak SOCKS5.
    UnsupportedVersion,
    /// The client did not offer username/password authentication.
    UnsupportedAuthenticationMethod,
    /// The RFC1929 authentication frame was malformed.
    MalformedAuthentication,
    /// Authentication failed.
    AuthenticationFailed,
    /// The request header was malformed.
    MalformedRequest,
    /// SOCKS5 BIND is intentionally unsupported.
    BindNotSupported,
    /// SOCKS5 UDP ASSOCIATE is intentionally unsupported.
    UdpAssociateNotSupported,
    /// Another SOCKS5 command is unsupported.
    CommandNotSupported,
    /// The address type is unsupported or malformed.
    AddressNotSupported,
    /// The domain target is empty/invalid.
    InvalidDomain,
    /// Destination port zero is rejected.
    InvalidPort,
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::UnsupportedVersion => "unsupported SOCKS version",
            Self::UnsupportedAuthenticationMethod => {
                "username/password authentication was not offered"
            }
            Self::MalformedAuthentication => "malformed SOCKS5 authentication frame",
            Self::AuthenticationFailed => "SOCKS5 authentication failed",
            Self::MalformedRequest => "malformed SOCKS5 request",
            Self::BindNotSupported => "SOCKS5 BIND is not supported",
            Self::UdpAssociateNotSupported => "SOCKS5 UDP ASSOCIATE is not supported",
            Self::CommandNotSupported => "SOCKS5 command is not supported",
            Self::AddressNotSupported => "SOCKS5 address type is not supported",
            Self::InvalidDomain => "SOCKS5 domain target is invalid",
            Self::InvalidPort => "SOCKS5 destination port must be non-zero",
        })
    }
}

impl std::error::Error for ProtocolError {}

/// Failure while serving one accepted bridge session.
#[derive(Debug)]
pub enum SessionError {
    /// Socket I/O failed.
    Io(io::Error),
    /// The SOCKS5 peer violated the accepted internal protocol.
    Protocol(ProtocolError),
    /// The cellular outbound port failed closed.
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

impl From<ProtocolError> for SessionError {
    fn from(error: ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

/// Byte counts from one completed CONNECT relay.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RelayStats {
    /// Bytes copied from sing-box/client toward cellular Internet.
    pub client_to_upstream: u64,
    /// Bytes copied from cellular Internet back toward sing-box/client.
    pub upstream_to_client: u64,
}

/// A bound bridge endpoint. It owns no accept loop or restart policy.
#[derive(Debug)]
pub struct BridgeListener {
    listener: TcpListener,
    credentials: BridgeCredentials,
}

impl BridgeListener {
    /// Binds a loopback endpoint. Port `0` requests an OS-assigned ephemeral port.
    pub fn bind(
        address: IpAddr,
        port: u16,
        credentials: BridgeCredentials,
    ) -> Result<Self, BridgeBindError> {
        if !address.is_loopback() {
            return Err(BridgeBindError::Config(BridgeConfigError::NonLoopbackAddress));
        }

        let listener = TcpListener::bind(SocketAddr::new(address, port)).map_err(BridgeBindError::Io)?;
        Ok(Self {
            listener,
            credentials,
        })
    }

    /// Returns the exact bound loopback endpoint, including an OS-assigned port.
    pub fn local_addr(&self) -> io::Result<SocketAddr> {
        self.listener.local_addr()
    }

    /// Accepts one TCP connection. Runtime Lifecycle owns any surrounding loop.
    pub fn accept(&self) -> io::Result<(TcpStream, SocketAddr)> {
        self.listener.accept()
    }

    /// Serves one previously accepted SOCKS5 session.
    pub fn serve_session<C: CellularOutboundConnector + ?Sized>(
        &self,
        mut client: TcpStream,
        connector: &C,
    ) -> Result<RelayStats, SessionError> {
        negotiate_username_password(&mut client)?;
        authenticate(&mut client, &self.credentials)?;
        let target = read_connect_request(&mut client)?;

        let upstream = match connector.connect(&target) {
            Ok(stream) => stream,
            Err(error) => {
                write_reply(&mut client, outbound_reply_code(error), unspecified_bind_addr())?;
                return Err(SessionError::Outbound(error));
            }
        };

        let bound = upstream.local_addr().unwrap_or_else(|_| unspecified_bind_addr());
        write_reply(&mut client, REPLY_SUCCEEDED, bound)?;
        relay_bidirectional(client, upstream).map_err(SessionError::Io)
    }
}

/// Bind-time failures for the bridge endpoint.
#[derive(Debug)]
pub enum BridgeBindError {
    /// Static bridge configuration was unsafe or invalid.
    Config(BridgeConfigError),
    /// The OS could not bind the requested loopback endpoint.
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

fn constant_time_eq(expected: &[u8], supplied: &[u8]) -> bool {
    let mut difference = expected.len() ^ supplied.len();
    let max_len = expected.len().max(supplied.len());

    for index in 0..max_len {
        let left = expected.get(index).copied().unwrap_or(0);
        let right = supplied.get(index).copied().unwrap_or(0);
        difference |= usize::from(left ^ right);
    }

    difference == 0
}

fn negotiate_username_password(stream: &mut TcpStream) -> Result<(), SessionError> {
    let mut header = [0_u8; 2];
    stream.read_exact(&mut header)?;
    if header[0] != SOCKS_VERSION {
        return Err(ProtocolError::UnsupportedVersion.into());
    }

    let method_count = usize::from(header[1]);
    if method_count == 0 {
        stream.write_all(&[SOCKS_VERSION, NO_ACCEPTABLE_METHODS])?;
        return Err(ProtocolError::UnsupportedAuthenticationMethod.into());
    }

    let mut methods = vec![0_u8; method_count];
    stream.read_exact(&mut methods)?;
    if !methods.contains(&USERNAME_PASSWORD_METHOD) {
        stream.write_all(&[SOCKS_VERSION, NO_ACCEPTABLE_METHODS])?;
        return Err(ProtocolError::UnsupportedAuthenticationMethod.into());
    }

    stream.write_all(&[SOCKS_VERSION, USERNAME_PASSWORD_METHOD])?;
    Ok(())
}

fn authenticate(
    stream: &mut TcpStream,
    credentials: &BridgeCredentials,
) -> Result<(), SessionError> {
    let mut header = [0_u8; 2];
    stream.read_exact(&mut header)?;
    if header[0] != USERNAME_PASSWORD_VERSION || header[1] == 0 {
        let _ = stream.write_all(&[USERNAME_PASSWORD_VERSION, 0x01]);
        return Err(ProtocolError::MalformedAuthentication.into());
    }

    let mut username = vec![0_u8; usize::from(header[1])];
    stream.read_exact(&mut username)?;

    let mut password_len = [0_u8; 1];
    stream.read_exact(&mut password_len)?;
    if password_len[0] == 0 {
        let _ = stream.write_all(&[USERNAME_PASSWORD_VERSION, 0x01]);
        return Err(ProtocolError::MalformedAuthentication.into());
    }

    let mut password = vec![0_u8; usize::from(password_len[0])];
    stream.read_exact(&mut password)?;

    if !credentials.matches(&username, &password) {
        stream.write_all(&[USERNAME_PASSWORD_VERSION, 0x01])?;
        return Err(ProtocolError::AuthenticationFailed.into());
    }

    stream.write_all(&[USERNAME_PASSWORD_VERSION, 0x00])?;
    Ok(())
}

fn read_connect_request(stream: &mut TcpStream) -> Result<ConnectTarget, SessionError> {
    let mut header = [0_u8; 4];
    stream.read_exact(&mut header)?;
    if header[0] != SOCKS_VERSION || header[2] != 0 {
        write_reply(stream, REPLY_GENERAL_FAILURE, unspecified_bind_addr())?;
        return Err(ProtocolError::MalformedRequest.into());
    }

    match header[1] {
        CONNECT_COMMAND => {}
        BIND_COMMAND => {
            write_reply(stream, REPLY_COMMAND_NOT_SUPPORTED, unspecified_bind_addr())?;
            return Err(ProtocolError::BindNotSupported.into());
        }
        UDP_ASSOCIATE_COMMAND => {
            write_reply(stream, REPLY_COMMAND_NOT_SUPPORTED, unspecified_bind_addr())?;
            return Err(ProtocolError::UdpAssociateNotSupported.into());
        }
        _ => {
            write_reply(stream, REPLY_COMMAND_NOT_SUPPORTED, unspecified_bind_addr())?;
            return Err(ProtocolError::CommandNotSupported.into());
        }
    }

    let host = match header[3] {
        IPV4_ADDRESS_TYPE => {
            let mut octets = [0_u8; 4];
            stream.read_exact(&mut octets)?;
            TargetHost::Ipv4(Ipv4Addr::from(octets))
        }
        IPV6_ADDRESS_TYPE => {
            let mut octets = [0_u8; 16];
            stream.read_exact(&mut octets)?;
            TargetHost::Ipv6(Ipv6Addr::from(octets))
        }
        DOMAIN_ADDRESS_TYPE => {
            let mut length = [0_u8; 1];
            stream.read_exact(&mut length)?;
            if length[0] == 0 {
                write_reply(stream, REPLY_ADDRESS_TYPE_NOT_SUPPORTED, unspecified_bind_addr())?;
                return Err(ProtocolError::InvalidDomain.into());
            }

            let mut bytes = vec![0_u8; usize::from(length[0])];
            stream.read_exact(&mut bytes)?;
            let domain = std::str::from_utf8(&bytes).map_err(|_| ProtocolError::InvalidDomain)?;
            if domain.bytes().any(|byte| byte == 0 || byte.is_ascii_control()) {
                write_reply(stream, REPLY_ADDRESS_TYPE_NOT_SUPPORTED, unspecified_bind_addr())?;
                return Err(ProtocolError::InvalidDomain.into());
            }
            TargetHost::Domain(domain.to_owned().into_boxed_str())
        }
        _ => {
            write_reply(stream, REPLY_ADDRESS_TYPE_NOT_SUPPORTED, unspecified_bind_addr())?;
            return Err(ProtocolError::AddressNotSupported.into());
        }
    };

    let mut port = [0_u8; 2];
    stream.read_exact(&mut port)?;
    let port = u16::from_be_bytes(port);
    if port == 0 {
        write_reply(stream, REPLY_GENERAL_FAILURE, unspecified_bind_addr())?;
        return Err(ProtocolError::InvalidPort.into());
    }

    Ok(ConnectTarget { host, port })
}

fn outbound_reply_code(error: OutboundConnectError) -> u8 {
    match error {
        OutboundConnectError::Unavailable => REPLY_HOST_UNREACHABLE,
        OutboundConnectError::Rejected => REPLY_NOT_ALLOWED,
        OutboundConnectError::Failed => REPLY_GENERAL_FAILURE,
    }
}

fn unspecified_bind_addr() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)
}

fn write_reply(stream: &mut TcpStream, reply: u8, bound: SocketAddr) -> io::Result<()> {
    let mut frame = Vec::with_capacity(22);
    frame.extend_from_slice(&[SOCKS_VERSION, reply, 0x00]);
    match bound.ip() {
        IpAddr::V4(address) => {
            frame.push(IPV4_ADDRESS_TYPE);
            frame.extend_from_slice(&address.octets());
        }
        IpAddr::V6(address) => {
            frame.push(IPV6_ADDRESS_TYPE);
            frame.extend_from_slice(&address.octets());
        }
    }
    frame.extend_from_slice(&bound.port().to_be_bytes());
    stream.write_all(&frame)
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
    use std::sync::{Arc, Mutex};

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
            .expect("valid test credentials")
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
    ) -> (SocketAddr, thread::JoinHandle<Result<RelayStats, SessionError>>) {
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
        assert_eq!(header[0], SOCKS_VERSION);
        assert_eq!(header[2], 0);
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
        let result = BridgeListener::bind(
            IpAddr::V4(Ipv4Addr::UNSPECIFIED),
            0,
            credentials(),
        );
        assert!(matches!(
            result,
            Err(BridgeBindError::Config(BridgeConfigError::NonLoopbackAddress))
        ));
    }

    #[test]
    fn port_zero_uses_an_os_assigned_loopback_port() {
        let bridge = BridgeListener::bind(
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            0,
            credentials(),
        )
        .expect("bridge bind");
        let address = bridge.local_addr().expect("bound address");
        assert!(address.ip().is_loopback());
        assert_ne!(address.port(), 0);
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
        assert_eq!(read_reply(&mut client), REPLY_SUCCEEDED);

        client.write_all(b"bridge-ok").expect("write payload");
        client.shutdown(Shutdown::Write).expect("client shutdown");
        let mut response = Vec::new();
        client.read_to_end(&mut response).expect("read echo");
        assert_eq!(response, b"bridge-ok");

        let stats = bridge_thread
            .join()
            .expect("bridge thread")
            .expect("bridge session");
        echo_thread.join().expect("echo thread");
        assert_eq!(stats.client_to_upstream, 9);
        assert_eq!(stats.upstream_to_client, 9);
        assert_eq!(
            connector.observed_target(),
            Some(ConnectTarget {
                host: TargetHost::Ipv4(Ipv4Addr::new(203, 0, 113, 10)),
                port: 443,
            })
        );
    }

    #[test]
    fn domain_is_preserved_for_connector_without_bridge_dns() {
        let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Unavailable));
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

        assert_eq!(read_reply(&mut client), REPLY_HOST_UNREACHABLE);
        assert!(matches!(
            bridge_thread.join().expect("bridge thread"),
            Err(SessionError::Outbound(OutboundConnectError::Unavailable))
        ));
        assert_eq!(
            connector.observed_target(),
            Some(ConnectTarget {
                host: TargetHost::Domain("example.invalid".into()),
                port: 443,
            })
        );
    }

    #[test]
    fn ipv6_is_preserved_for_connector_without_bridge_dns() {
        let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Failed));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut client = connect_and_authenticate(bridge_address);
        let address = Ipv6Addr::LOCALHOST;
        let mut request = vec![SOCKS_VERSION, CONNECT_COMMAND, 0, IPV6_ADDRESS_TYPE];
        request.extend_from_slice(&address.octets());
        request.extend_from_slice(&8443_u16.to_be_bytes());
        client.write_all(&request).expect("write IPv6 CONNECT");

        assert_eq!(read_reply(&mut client), REPLY_GENERAL_FAILURE);
        assert!(matches!(
            bridge_thread.join().expect("bridge thread"),
            Err(SessionError::Outbound(OutboundConnectError::Failed))
        ));
        assert_eq!(
            connector.observed_target(),
            Some(ConnectTarget {
                host: TargetHost::Ipv6(address),
                port: 8443,
            })
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

    #[test]
    fn unsupported_authentication_method_is_rejected() {
        let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Failed));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut client = TcpStream::connect(bridge_address).expect("connect bridge");
        client
            .write_all(&[SOCKS_VERSION, 1, 0x00])
            .expect("write unsupported greeting");
        let mut reply = [0_u8; 2];
        client.read_exact(&mut reply).expect("read method rejection");
        assert_eq!(reply, [SOCKS_VERSION, NO_ACCEPTABLE_METHODS]);

        assert!(matches!(
            bridge_thread.join().expect("bridge thread"),
            Err(SessionError::Protocol(
                ProtocolError::UnsupportedAuthenticationMethod
            ))
        ));
        assert_eq!(connector.observed_target(), None);
    }

    #[test]
    fn bind_and_udp_associate_are_rejected_before_connector_invocation() {
        for (command, expected) in [
            (BIND_COMMAND, ProtocolError::BindNotSupported),
            (UDP_ASSOCIATE_COMMAND, ProtocolError::UdpAssociateNotSupported),
        ] {
            let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Failed));
            let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
            let mut client = connect_and_authenticate(bridge_address);
            client
                .write_all(&[
                    SOCKS_VERSION,
                    command,
                    0,
                    IPV4_ADDRESS_TYPE,
                    127,
                    0,
                    0,
                    1,
                    0,
                    80,
                ])
                .expect("write unsupported request");
            assert_eq!(read_reply(&mut client), REPLY_COMMAND_NOT_SUPPORTED);
            assert!(matches!(
                bridge_thread.join().expect("bridge thread"),
                Err(SessionError::Protocol(error)) if error == expected
            ));
            assert_eq!(connector.observed_target(), None);
        }
    }

    #[test]
    fn malformed_domain_is_rejected_before_connector_invocation() {
        let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Failed));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut client = connect_and_authenticate(bridge_address);
        client
            .write_all(&[
                SOCKS_VERSION,
                CONNECT_COMMAND,
                0,
                DOMAIN_ADDRESS_TYPE,
                0,
            ])
            .expect("write malformed domain");

        assert_eq!(read_reply(&mut client), REPLY_ADDRESS_TYPE_NOT_SUPPORTED);
        assert!(matches!(
            bridge_thread.join().expect("bridge thread"),
            Err(SessionError::Protocol(ProtocolError::InvalidDomain))
        ));
        assert_eq!(connector.observed_target(), None);
    }
}
