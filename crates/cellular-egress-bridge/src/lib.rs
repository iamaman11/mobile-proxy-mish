//! Loopback-only TCP/relay adapter into the Cellular Egress capability.
//!
//! SOCKS5 framing, authentication, request decoding and reply encoding belong to
//! `mish-proxy`. This crate owns only the temporary loopback listener/relay mechanics
//! required while PRODUCT is still migrating away from the external sing-box child.

use mish_proxy::{
    ProxyCredentialMaterial, ProxyPolicyError, Socks5Reply, Socks5SessionError,
    accept_socks5_connect, write_socks5_reply,
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
        let material = ProxyCredentialMaterial::new(username, password).map_err(|error| match error {
            ProxyPolicyError::EmptyUsername => BridgeConfigError::InvalidUsername,
            ProxyPolicyError::EmptyPassword => BridgeConfigError::InvalidPassword,
            ProxyPolicyError::WildcardListenAddress => BridgeConfigError::InvalidUsername,
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
            return Err(BridgeBindError::Config(BridgeConfigError::NonLoopbackAddress));
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

    fn credentials() -> BridgeCredentials {
        BridgeCredentials::new("internal-user".to_owned(), "internal-password".to_owned())
            .expect("valid credentials")
    }

    #[test]
    fn credentials_debug_output_is_redacted() {
        let rendered = format!("{:?}", credentials());
        assert!(!rendered.contains("internal-user"));
        assert!(!rendered.contains("internal-password"));
        assert!(rendered.contains("<redacted>"));
    }

    #[test]
    fn credentials_reject_invalid_fields() {
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
            Err(BridgeBindError::Config(BridgeConfigError::NonLoopbackAddress))
        ));
    }

    #[test]
    fn port_zero_uses_os_assigned_loopback_port() {
        let bridge = BridgeListener::bind(IpAddr::V4(Ipv4Addr::LOCALHOST), 0, credentials())
            .expect("bridge bind");
        let address = bridge.local_addr().expect("bound address");
        assert!(address.ip().is_loopback());
        assert_ne!(address.port(), 0);
    }
}
