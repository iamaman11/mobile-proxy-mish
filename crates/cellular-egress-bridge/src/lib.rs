//! Loopback-only TCP adapter into the Cellular Egress capability.
//!
//! Proxy protocol/authentication, outbound effect-port semantics and relay behavior belong to
//! `mish-proxy`. This crate owns only the temporary loopback listener required while PRODUCT is
//! still migrating away from the external sing-box child.

use mish_proxy::{ProxyCredentialMaterial, ProxyPolicyError, ProxyProtocol, serve_proxy_session};
use std::fmt;
use std::io;
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream};

const MAX_AUTH_FIELD_LEN: usize = u8::MAX as usize;

pub use mish_proxy::{
    ProxyConnectTarget as ConnectTarget, ProxyOutboundConnectError as OutboundConnectError,
    ProxyOutboundConnector as CellularOutboundConnector, ProxyRelayStats as RelayStats,
    ProxySessionError as SessionError, ProxyTargetHost as TargetHost,
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
        let material =
            ProxyCredentialMaterial::new(username, password).map_err(|error| match error {
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

/// Temporary loopback adapter. It owns neither protocol/session policy nor surrounding lifecycle.
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
        serve_proxy_session(
            ProxyProtocol::Socks5,
            client,
            self.credentials.material(),
            connector,
        )
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv4Addr;

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
            Err(BridgeBindError::Config(
                BridgeConfigError::NonLoopbackAddress
            ))
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
