use mish_cellular_egress_bridge::{
    CellularOutboundConnector, ConnectTarget, OutboundConnectError, TargetHost,
};
use std::fmt;
use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::time::{Duration, Instant};

const SOCKS_VERSION: u8 = 0x05;
const USERNAME_PASSWORD_METHOD: u8 = 0x02;
const USERNAME_PASSWORD_VERSION: u8 = 0x01;
const CONNECT_COMMAND: u8 = 0x01;
const IPV4_ADDRESS_TYPE: u8 = 0x01;
const DOMAIN_ADDRESS_TYPE: u8 = 0x03;
const IPV6_ADDRESS_TYPE: u8 = 0x04;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrivateBridgeConnectorConfigError {
    ZeroPort,
    InvalidUsername,
    InvalidPassword,
    ZeroOperationTimeout,
}

impl fmt::Display for PrivateBridgeConnectorConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::ZeroPort => "private cellular bridge port must be non-zero",
            Self::InvalidUsername => "private cellular bridge username must contain 1..=255 bytes",
            Self::InvalidPassword => "private cellular bridge password must contain 1..=255 bytes",
            Self::ZeroOperationTimeout => "private cellular bridge timeout must be non-zero",
        })
    }
}

impl std::error::Error for PrivateBridgeConnectorConfigError {}

/// Temporary migration connector from native Proxy Serving to the existing private Cellular bridge.
///
/// This adapter performs no DNS and never accepts a non-loopback bridge address. Domain targets
/// remain domain targets in the SOCKS5 request so Cellular Egress remains the only DNS-effect owner.
/// L8 removes this final loopback hop and connects Proxy Serving directly to the root-policy-gated
/// Cellular connector.
#[derive(Clone)]
pub struct PrivateBridgeOutboundConnector {
    bridge_address: SocketAddr,
    username: Box<[u8]>,
    password: Box<[u8]>,
    operation_timeout: Duration,
}

impl PrivateBridgeOutboundConnector {
    pub fn new(
        port: u16,
        username: String,
        password: String,
        operation_timeout: Duration,
    ) -> Result<Self, PrivateBridgeConnectorConfigError> {
        if port == 0 {
            return Err(PrivateBridgeConnectorConfigError::ZeroPort);
        }
        validate_auth_field(&username, PrivateBridgeConnectorConfigError::InvalidUsername)?;
        validate_auth_field(&password, PrivateBridgeConnectorConfigError::InvalidPassword)?;
        if operation_timeout.is_zero() {
            return Err(PrivateBridgeConnectorConfigError::ZeroOperationTimeout);
        }
        Ok(Self {
            bridge_address: SocketAddr::new(Ipv4Addr::LOCALHOST.into(), port),
            username: username.into_bytes().into_boxed_slice(),
            password: password.into_bytes().into_boxed_slice(),
            operation_timeout,
        })
    }

    fn connect_inner(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
        let deadline = Instant::now()
            .checked_add(self.operation_timeout)
            .ok_or(OutboundConnectError::Rejected)?;
        let mut stream = TcpStream::connect_timeout(&self.bridge_address, remaining(deadline)?)
            .map_err(|_| OutboundConnectError::Unavailable)?;
        configure_timeout(&stream, deadline)?;

        stream
            .write_all(&[SOCKS_VERSION, 1, USERNAME_PASSWORD_METHOD])
            .map_err(|_| OutboundConnectError::Failed)?;
        let mut method = [0_u8; 2];
        stream
            .read_exact(&mut method)
            .map_err(|_| OutboundConnectError::Failed)?;
        if method != [SOCKS_VERSION, USERNAME_PASSWORD_METHOD] {
            return Err(OutboundConnectError::Rejected);
        }

        let mut auth = Vec::with_capacity(self.username.len() + self.password.len() + 3);
        auth.push(USERNAME_PASSWORD_VERSION);
        auth.push(self.username.len() as u8);
        auth.extend_from_slice(&self.username);
        auth.push(self.password.len() as u8);
        auth.extend_from_slice(&self.password);
        stream
            .write_all(&auth)
            .map_err(|_| OutboundConnectError::Failed)?;
        let mut auth_reply = [0_u8; 2];
        stream
            .read_exact(&mut auth_reply)
            .map_err(|_| OutboundConnectError::Failed)?;
        if auth_reply != [USERNAME_PASSWORD_VERSION, 0] {
            return Err(OutboundConnectError::Rejected);
        }

        let request = connect_request(target)?;
        configure_timeout(&stream, deadline)?;
        stream
            .write_all(&request)
            .map_err(|_| OutboundConnectError::Failed)?;
        read_connect_reply(&mut stream)?;
        stream
            .set_read_timeout(None)
            .map_err(|_| OutboundConnectError::Failed)?;
        stream
            .set_write_timeout(None)
            .map_err(|_| OutboundConnectError::Failed)?;
        Ok(stream)
    }
}

impl fmt::Debug for PrivateBridgeOutboundConnector {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PrivateBridgeOutboundConnector")
            .field("bridge_address", &self.bridge_address)
            .field("credentials", &"<redacted>")
            .field("operation_timeout", &self.operation_timeout)
            .finish()
    }
}

impl CellularOutboundConnector for PrivateBridgeOutboundConnector {
    fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
        self.connect_inner(target)
    }
}

fn validate_auth_field(
    value: &str,
    error: PrivateBridgeConnectorConfigError,
) -> Result<(), PrivateBridgeConnectorConfigError> {
    if value.is_empty() || value.len() > u8::MAX as usize {
        Err(error)
    } else {
        Ok(())
    }
}

fn remaining(deadline: Instant) -> Result<Duration, OutboundConnectError> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .ok_or(OutboundConnectError::Unavailable)
}

fn configure_timeout(stream: &TcpStream, deadline: Instant) -> Result<(), OutboundConnectError> {
    let timeout = remaining(deadline)?;
    stream
        .set_read_timeout(Some(timeout))
        .map_err(|_| OutboundConnectError::Failed)?;
    stream
        .set_write_timeout(Some(timeout))
        .map_err(|_| OutboundConnectError::Failed)
}

fn connect_request(target: &ConnectTarget) -> Result<Vec<u8>, OutboundConnectError> {
    let mut request = vec![SOCKS_VERSION, CONNECT_COMMAND, 0];
    match target.host() {
        TargetHost::Ipv4(address) => {
            request.push(IPV4_ADDRESS_TYPE);
            request.extend_from_slice(&address.octets());
        }
        TargetHost::Ipv6(address) => {
            request.push(IPV6_ADDRESS_TYPE);
            request.extend_from_slice(&address.octets());
        }
        TargetHost::Domain(domain) => {
            let length = u8::try_from(domain.len()).map_err(|_| OutboundConnectError::Rejected)?;
            request.push(DOMAIN_ADDRESS_TYPE);
            request.push(length);
            request.extend_from_slice(domain.as_bytes());
        }
    }
    request.extend_from_slice(&target.port().to_be_bytes());
    Ok(request)
}

fn read_connect_reply(stream: &mut TcpStream) -> Result<(), OutboundConnectError> {
    let mut header = [0_u8; 4];
    stream
        .read_exact(&mut header)
        .map_err(|_| OutboundConnectError::Failed)?;
    if header[0] != SOCKS_VERSION || header[2] != 0 {
        return Err(OutboundConnectError::Failed);
    }
    if header[1] != 0 {
        return Err(match header[1] {
            0x02 => OutboundConnectError::Rejected,
            0x03 | 0x04 | 0x05 | 0x06 => OutboundConnectError::Unavailable,
            _ => OutboundConnectError::Failed,
        });
    }

    let address_bytes = match header[3] {
        IPV4_ADDRESS_TYPE => 4,
        IPV6_ADDRESS_TYPE => 16,
        DOMAIN_ADDRESS_TYPE => {
            let mut length = [0_u8; 1];
            stream
                .read_exact(&mut length)
                .map_err(|_| OutboundConnectError::Failed)?;
            length[0] as usize
        }
        _ => return Err(OutboundConnectError::Failed),
    };
    let mut discard = vec![0_u8; address_bytes + 2];
    stream
        .read_exact(&mut discard)
        .map_err(|_| OutboundConnectError::Failed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::Ipv6Addr;

    #[test]
    fn target_encoding_preserves_domain_without_resolution() {
        let target = ConnectTarget::domain("example.invalid", 443).expect("target");
        assert_eq!(
            connect_request(&target).expect("request"),
            [
                vec![SOCKS_VERSION, CONNECT_COMMAND, 0, DOMAIN_ADDRESS_TYPE, 15],
                b"example.invalid".to_vec(),
                443_u16.to_be_bytes().to_vec(),
            ]
            .concat()
        );
    }

    #[test]
    fn numeric_targets_are_encoded_without_dns() {
        let ipv4 = ConnectTarget::ipv4(Ipv4Addr::new(203, 0, 113, 10), 443).expect("IPv4");
        let ipv6 = ConnectTarget::ipv6(Ipv6Addr::LOCALHOST, 443).expect("IPv6");
        assert_eq!(connect_request(&ipv4).expect("IPv4 request")[3], IPV4_ADDRESS_TYPE);
        assert_eq!(connect_request(&ipv6).expect("IPv6 request")[3], IPV6_ADDRESS_TYPE);
    }

    #[test]
    fn connector_debug_redacts_private_credentials() {
        let connector = PrivateBridgeOutboundConnector::new(
            19080,
            "private-user".into(),
            "private-secret".into(),
            Duration::from_secs(1),
        )
        .expect("connector");
        let debug = format!("{connector:?}");
        assert!(!debug.contains("private-user"));
        assert!(!debug.contains("private-secret"));
        assert!(debug.contains("<redacted>"));
    }
}
