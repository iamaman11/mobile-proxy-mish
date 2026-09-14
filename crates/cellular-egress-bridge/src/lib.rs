//! Loopback-only SOCKS5 adapter into the Cellular Egress capability.
//!
//! This crate owns no cellular state and no long-lived runtime lifecycle. It owns
//! only the bounded internal SOCKS5 protocol/session semantics needed for sing-box
//! to hand one CONNECT stream to a consumer-owned Cellular Egress connector port.

use std::collections::HashMap;
use std::fmt;
use std::io::{self, Read, Write};
use std::net::{
    IpAddr, Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream, UdpSocket,
};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Duration;

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
const UDP_ASSOCIATION_MAX_TARGETS: usize = 16;
const UDP_ASSOCIATION_MAX_DATAGRAM: usize = 16 * 1024;
const UDP_ASSOCIATION_POLL: Duration = Duration::from_millis(50);

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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
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
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
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

    /// Creates one owner-authorized cellular UDP socket or fails closed.
    ///
    /// The default is deliberate: introducing UDP support requires the private bridge's SOCKS
    /// association/authentication implementation and must never silently enable it for an
    /// existing TCP-only connector.
    fn connect_udp(&self, _target: &ConnectTarget) -> Result<UdpSocket, OutboundConnectError> {
        Err(OutboundConnectError::Rejected)
    }
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
    /// SOCKS5 UDP ASSOCIATE framing was malformed or tried unsupported fragmentation.
    UdpAssociateMalformed,
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
            Self::UdpAssociateMalformed => "SOCKS5 UDP ASSOCIATE frame is malformed",
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
        client: TcpStream,
        connector: &C,
    ) -> Result<RelayStats, SessionError> {
        let mut client = client;
        let result = self.serve_session_inner(&mut client, connector);
        if result.is_err() {
            // A protocol rejection has already written a bounded SOCKS reply. Gracefully finish
            // the write side before dropping the socket so Windows clients can consume that
            // reply instead of seeing an intermittent reset from an immediate close.
            let _ = client.shutdown(Shutdown::Write);
        }
        result
    }

    fn serve_session_inner<C: CellularOutboundConnector + ?Sized>(
        &self,
        client: &mut TcpStream,
        connector: &C,
    ) -> Result<RelayStats, SessionError> {
        negotiate_username_password(client)?;
        authenticate(client, &self.credentials)?;
        let request = read_socks_request(client)?;
        match request.command {
            SocksCommand::Connect => {
                let upstream = match connector.connect(&request.target) {
                    Ok(stream) => stream,
                    Err(error) => {
                        write_reply(client, outbound_reply_code(error), unspecified_bind_addr())?;
                        return Err(SessionError::Outbound(error));
                    }
                };

                let bound = upstream
                    .local_addr()
                    .unwrap_or_else(|_| unspecified_bind_addr());
                write_reply(client, REPLY_SUCCEEDED, bound)?;
                relay_bidirectional(client.try_clone()?, upstream).map_err(SessionError::Io)
            }
            SocksCommand::UdpAssociate => serve_udp_associate(client, connector),
        }
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SocksCommand {
    Connect,
    UdpAssociate,
}

struct SocksRequest {
    command: SocksCommand,
    target: ConnectTarget,
}

fn read_socks_request(stream: &mut TcpStream) -> Result<SocksRequest, SessionError> {
    let mut header = [0_u8; 4];
    stream.read_exact(&mut header)?;
    if header[0] != SOCKS_VERSION || header[2] != 0 {
        write_reply(stream, REPLY_GENERAL_FAILURE, unspecified_bind_addr())?;
        return Err(ProtocolError::MalformedRequest.into());
    }

    let command = match header[1] {
        CONNECT_COMMAND => SocksCommand::Connect,
        BIND_COMMAND => {
            write_reply(stream, REPLY_COMMAND_NOT_SUPPORTED, unspecified_bind_addr())?;
            return Err(ProtocolError::BindNotSupported.into());
        }
        UDP_ASSOCIATE_COMMAND => SocksCommand::UdpAssociate,
        _ => {
            write_reply(stream, REPLY_COMMAND_NOT_SUPPORTED, unspecified_bind_addr())?;
            return Err(ProtocolError::CommandNotSupported.into());
        }
    };

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
                write_reply(
                    stream,
                    REPLY_ADDRESS_TYPE_NOT_SUPPORTED,
                    unspecified_bind_addr(),
                )?;
                return Err(ProtocolError::InvalidDomain.into());
            }

            let mut bytes = vec![0_u8; usize::from(length[0])];
            stream.read_exact(&mut bytes)?;
            let domain = std::str::from_utf8(&bytes).map_err(|_| ProtocolError::InvalidDomain)?;
            if domain
                .bytes()
                .any(|byte| byte == 0 || byte.is_ascii_control())
            {
                write_reply(
                    stream,
                    REPLY_ADDRESS_TYPE_NOT_SUPPORTED,
                    unspecified_bind_addr(),
                )?;
                return Err(ProtocolError::InvalidDomain.into());
            }
            TargetHost::Domain(domain.to_owned().into_boxed_str())
        }
        _ => {
            write_reply(
                stream,
                REPLY_ADDRESS_TYPE_NOT_SUPPORTED,
                unspecified_bind_addr(),
            )?;
            return Err(ProtocolError::AddressNotSupported.into());
        }
    };

    let mut port = [0_u8; 2];
    stream.read_exact(&mut port)?;
    let port = u16::from_be_bytes(port);
    if port == 0 && command == SocksCommand::Connect {
        write_reply(stream, REPLY_GENERAL_FAILURE, unspecified_bind_addr())?;
        return Err(ProtocolError::InvalidPort.into());
    }

    Ok(SocksRequest {
        command,
        target: ConnectTarget { host, port },
    })
}

struct UdpTargetWorker {
    socket: UdpSocket,
    response_worker: thread::JoinHandle<()>,
}

/// Bounded local SOCKS5 UDP ASSOCIATE implementation.
///
/// This is intentionally an internal loopback hop: the authenticated TCP control peer must be
/// loopback, the first UDP packet must have the same loopback IP, and its full socket address is
/// then pinned for the association lifetime. Public Mesh admission and external-client identity
/// are separate transport-owner responsibilities; this function never opens a public UDP socket.
fn serve_udp_associate<C: CellularOutboundConnector + ?Sized>(
    control: &mut TcpStream,
    connector: &C,
) -> Result<RelayStats, SessionError> {
    let control_peer = control.peer_addr()?;
    if !control_peer.ip().is_loopback() {
        return Err(ProtocolError::UdpAssociateMalformed.into());
    }
    let local_address = match control_peer {
        SocketAddr::V4(_) => SocketAddr::from((Ipv4Addr::LOCALHOST, 0)),
        SocketAddr::V6(_) => SocketAddr::from((Ipv6Addr::LOCALHOST, 0)),
    };
    let inbound = UdpSocket::bind(local_address)?;
    inbound.set_read_timeout(Some(UDP_ASSOCIATION_POLL))?;
    let bound = inbound.local_addr()?;
    write_reply(control, REPLY_SUCCEEDED, bound)?;

    let mut control_probe = control.try_clone()?;
    control_probe.set_nonblocking(true)?;
    let stopped = Arc::new(AtomicBool::new(false));
    let response_socket = inbound.try_clone()?;
    let mut source_peer = None;
    let mut targets: HashMap<ConnectTarget, UdpTargetWorker> = HashMap::new();
    let mut buffer = vec![0_u8; UDP_ASSOCIATION_MAX_DATAGRAM];

    while !stopped.load(Ordering::Acquire) {
        let mut control_byte = [0_u8; 1];
        match control_probe.read(&mut control_byte) {
            Ok(0) | Ok(_) => break,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) => return Err(error.into()),
        }

        let (count, peer) = match inbound.recv_from(&mut buffer) {
            Ok(received) => received,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        if peer.ip() != control_peer.ip() || !peer.ip().is_loopback() {
            continue;
        }
        match source_peer {
            Some(bound_peer) if bound_peer != peer => continue,
            Some(_) => {}
            None => source_peer = Some(peer),
        }

        let Some((target, payload)) = parse_udp_request(&buffer[..count]) else {
            continue;
        };
        if !targets.contains_key(&target) {
            if targets.len() >= UDP_ASSOCIATION_MAX_TARGETS {
                continue;
            }
            let outbound = match connector.connect_udp(&target) {
                Ok(socket) => socket,
                Err(_) => continue,
            };
            let reader = outbound.try_clone()?;
            reader.set_read_timeout(Some(UDP_ASSOCIATION_POLL))?;
            let sender = response_socket.try_clone()?;
            let response_target = target.clone();
            let response_peer = peer;
            let response_stop = Arc::clone(&stopped);
            let response_worker = thread::Builder::new()
                .name("mish-cellular-udp-response".to_owned())
                .spawn(move || {
                    udp_response_loop(
                        reader,
                        sender,
                        response_peer,
                        response_target,
                        response_stop,
                    )
                })
                .map_err(|_| io::Error::other("UDP response worker unavailable"))?;
            targets.insert(
                target.clone(),
                UdpTargetWorker {
                    socket: outbound,
                    response_worker,
                },
            );
        }
        if let Some(worker) = targets.get(&target) {
            let _ = worker.socket.send(payload);
        }
    }

    stopped.store(true, Ordering::Release);
    for (_, worker) in targets {
        let _ = worker.response_worker.join();
    }
    Ok(RelayStats {
        client_to_upstream: 0,
        upstream_to_client: 0,
    })
}

fn udp_response_loop(
    socket: UdpSocket,
    inbound: UdpSocket,
    peer: SocketAddr,
    target: ConnectTarget,
    stopped: Arc<AtomicBool>,
) {
    let mut response = vec![0_u8; UDP_ASSOCIATION_MAX_DATAGRAM];
    while !stopped.load(Ordering::Acquire) {
        match socket.recv(&mut response) {
            Ok(count) => {
                let frame = encode_udp_response(&target, &response[..count]);
                let _ = inbound.send_to(&frame, peer);
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) => {}
            Err(_) => return,
        }
    }
}

fn parse_udp_request(frame: &[u8]) -> Option<(ConnectTarget, &[u8])> {
    if frame.len() < 7 || frame[0] != 0 || frame[1] != 0 || frame[2] != 0 {
        return None;
    }
    let mut offset = 4;
    let host = match frame[3] {
        IPV4_ADDRESS_TYPE => {
            let octets: [u8; 4] = frame.get(offset..offset + 4)?.try_into().ok()?;
            offset += 4;
            TargetHost::Ipv4(Ipv4Addr::from(octets))
        }
        IPV6_ADDRESS_TYPE => {
            let octets: [u8; 16] = frame.get(offset..offset + 16)?.try_into().ok()?;
            offset += 16;
            TargetHost::Ipv6(Ipv6Addr::from(octets))
        }
        DOMAIN_ADDRESS_TYPE => {
            let length = usize::from(*frame.get(offset)?);
            offset += 1;
            if length == 0 {
                return None;
            }
            let bytes = frame.get(offset..offset + length)?;
            offset += length;
            let domain = std::str::from_utf8(bytes).ok()?;
            if domain
                .bytes()
                .any(|byte| byte == 0 || byte.is_ascii_control())
            {
                return None;
            }
            TargetHost::Domain(domain.to_owned().into_boxed_str())
        }
        _ => return None,
    };
    let port = u16::from_be_bytes(frame.get(offset..offset + 2)?.try_into().ok()?);
    offset += 2;
    if port == 0 || offset >= frame.len() {
        return None;
    }
    Some((ConnectTarget { host, port }, &frame[offset..]))
}

fn encode_udp_response(target: &ConnectTarget, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(payload.len() + 22);
    frame.extend_from_slice(&[0, 0, 0]);
    match target.host() {
        TargetHost::Ipv4(address) => {
            frame.push(IPV4_ADDRESS_TYPE);
            frame.extend_from_slice(&address.octets());
        }
        TargetHost::Ipv6(address) => {
            frame.push(IPV6_ADDRESS_TYPE);
            frame.extend_from_slice(&address.octets());
        }
        TargetHost::Domain(domain) => {
            frame.push(DOMAIN_ADDRESS_TYPE);
            frame.push(domain.len() as u8);
            frame.extend_from_slice(domain.as_bytes());
        }
    }
    frame.extend_from_slice(&target.port().to_be_bytes());
    frame.extend_from_slice(payload);
    frame
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
        udp_target: Mutex<Option<ConnectTarget>>,
        upstream: SocketAddr,
        udp_upstream: Option<SocketAddr>,
        failure: Option<OutboundConnectError>,
    }

    impl RecordingConnector {
        fn success(upstream: SocketAddr) -> Self {
            Self {
                target: Mutex::new(None),
                udp_target: Mutex::new(None),
                upstream,
                udp_upstream: None,
                failure: None,
            }
        }

        fn failure(error: OutboundConnectError) -> Self {
            Self {
                target: Mutex::new(None),
                udp_target: Mutex::new(None),
                upstream: "127.0.0.1:9".parse().expect("static socket address"),
                udp_upstream: None,
                failure: Some(error),
            }
        }

        fn observed_target(&self) -> Option<ConnectTarget> {
            self.target.lock().expect("target mutex").clone()
        }

        fn udp_success(upstream: SocketAddr) -> Self {
            Self {
                target: Mutex::new(None),
                udp_target: Mutex::new(None),
                upstream: "127.0.0.1:9".parse().expect("static socket address"),
                udp_upstream: Some(upstream),
                failure: None,
            }
        }

        fn observed_udp_target(&self) -> Option<ConnectTarget> {
            self.udp_target.lock().expect("UDP target mutex").clone()
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

        fn connect_udp(&self, target: &ConnectTarget) -> Result<UdpSocket, OutboundConnectError> {
            *self.udp_target.lock().expect("UDP target mutex") = Some(target.clone());
            let upstream = self.udp_upstream.ok_or(OutboundConnectError::Rejected)?;
            let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0))
                .map_err(|_| OutboundConnectError::Failed)?;
            socket
                .connect(upstream)
                .map_err(|_| OutboundConnectError::Failed)?;
            Ok(socket)
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
        read_reply_with_address(stream).0
    }

    fn read_reply_with_address(stream: &mut TcpStream) -> (u8, SocketAddr) {
        let mut header = [0_u8; 4];
        stream.read_exact(&mut header).expect("read reply header");
        assert_eq!(header[0], SOCKS_VERSION);
        assert_eq!(header[2], 0);
        let address = match header[3] {
            IPV4_ADDRESS_TYPE => {
                let mut rest = [0_u8; 6];
                stream.read_exact(&mut rest).expect("read IPv4 reply");
                SocketAddr::from((
                    Ipv4Addr::new(rest[0], rest[1], rest[2], rest[3]),
                    u16::from_be_bytes([rest[4], rest[5]]),
                ))
            }
            IPV6_ADDRESS_TYPE => {
                let mut rest = [0_u8; 18];
                stream.read_exact(&mut rest).expect("read IPv6 reply");
                let octets: [u8; 16] = rest[..16].try_into().expect("IPv6 octets");
                SocketAddr::from((
                    Ipv6Addr::from(octets),
                    u16::from_be_bytes([rest[16], rest[17]]),
                ))
            }
            other => panic!("unexpected reply address type {other}"),
        };
        (header[1], address)
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
    fn port_zero_uses_an_os_assigned_loopback_port() {
        let bridge = BridgeListener::bind(IpAddr::V4(Ipv4Addr::LOCALHOST), 0, credentials())
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
    fn authenticated_udp_associate_relays_loopback_datagram_and_stops_with_control() {
        let backend = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("UDP backend bind");
        backend
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("UDP backend timeout");
        let backend_address = backend.local_addr().expect("UDP backend address");
        let backend_worker = thread::spawn(move || {
            let mut packet = [0_u8; 128];
            let (count, peer) = backend.recv_from(&mut packet).expect("UDP backend receive");
            assert_eq!(&packet[..count], b"udp-bridge-ok");
            backend
                .send_to(b"udp-response", peer)
                .expect("UDP backend response");
        });
        let connector = Arc::new(RecordingConnector::udp_success(backend_address));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut control = connect_and_authenticate(bridge_address);
        control
            .write_all(&[
                SOCKS_VERSION,
                UDP_ASSOCIATE_COMMAND,
                0,
                IPV4_ADDRESS_TYPE,
                0,
                0,
                0,
                0,
                0,
                0,
            ])
            .expect("write UDP associate");
        let (reply, relay) = read_reply_with_address(&mut control);
        assert_eq!(reply, REPLY_SUCCEEDED);
        assert!(relay.ip().is_loopback());

        let client = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("UDP client bind");
        client
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("UDP client timeout");
        let mut request = vec![0, 0, 0, IPV4_ADDRESS_TYPE, 203, 0, 113, 9, 1, 187];
        request.extend_from_slice(b"udp-bridge-ok");
        client.send_to(&request, relay).expect("UDP request");
        let mut response = [0_u8; 128];
        let (count, _) = client.recv_from(&mut response).expect("UDP response");
        assert_eq!(
            &response[..count],
            &[
                0,
                0,
                0,
                IPV4_ADDRESS_TYPE,
                203,
                0,
                113,
                9,
                1,
                187,
                b'u',
                b'd',
                b'p',
                b'-',
                b'r',
                b'e',
                b's',
                b'p',
                b'o',
                b'n',
                b's',
                b'e'
            ]
        );
        assert_eq!(
            connector.observed_udp_target(),
            Some(ConnectTarget {
                host: TargetHost::Ipv4(Ipv4Addr::new(203, 0, 113, 9)),
                port: 443,
            })
        );
        drop(control);
        backend_worker.join().expect("UDP backend worker");
        bridge_thread
            .join()
            .expect("bridge thread")
            .expect("UDP association session");
    }

    #[test]
    fn domain_is_preserved_for_connector_without_bridge_dns() {
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
        client
            .read_exact(&mut reply)
            .expect("read method rejection");
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
    fn bind_is_rejected_before_connector_invocation() {
        let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Failed));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut client = connect_and_authenticate(bridge_address);
        client
            .write_all(&[
                SOCKS_VERSION,
                BIND_COMMAND,
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
            Err(SessionError::Protocol(ProtocolError::BindNotSupported))
        ));
        assert_eq!(connector.observed_target(), None);
    }

    #[test]
    fn malformed_domain_is_rejected_before_connector_invocation() {
        let connector = Arc::new(RecordingConnector::failure(OutboundConnectError::Failed));
        let (bridge_address, bridge_thread) = spawn_bridge(Arc::clone(&connector));
        let mut client = connect_and_authenticate(bridge_address);
        client
            .write_all(&[SOCKS_VERSION, CONNECT_COMMAND, 0, DOMAIN_ADDRESS_TYPE, 0])
            .expect("write malformed domain");

        assert_eq!(read_reply(&mut client), REPLY_ADDRESS_TYPE_NOT_SUPPORTED);
        assert!(matches!(
            bridge_thread.join().expect("bridge thread"),
            Err(SessionError::Protocol(ProtocolError::InvalidDomain))
        ));
        assert_eq!(connector.observed_target(), None);
    }
}
