use std::fmt;
use std::io::{self, Read, Write};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use crate::{ProxyConnectTarget, ProxyCredentialMaterial, ProxyTargetError};

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
const MAX_AUTH_FIELD_LEN: usize = u8::MAX as usize;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Socks5Reply {
    Succeeded,
    GeneralFailure,
    ConnectionNotAllowed,
    HostUnreachable,
    CommandNotSupported,
    AddressTypeNotSupported,
}

impl Socks5Reply {
    const fn code(self) -> u8 {
        match self {
            Self::Succeeded => 0x00,
            Self::GeneralFailure => 0x01,
            Self::ConnectionNotAllowed => 0x02,
            Self::HostUnreachable => 0x04,
            Self::CommandNotSupported => 0x07,
            Self::AddressTypeNotSupported => 0x08,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Socks5ProtocolError {
    UnsupportedVersion,
    UnsupportedAuthenticationMethod,
    InvalidCredentialLength,
    MalformedAuthentication,
    AuthenticationFailed,
    MalformedRequest,
    BindNotSupported,
    UdpAssociateNotSupported,
    CommandNotSupported,
    AddressNotSupported,
    InvalidDomain,
    InvalidPort,
    Target(ProxyTargetError),
}

impl fmt::Display for Socks5ProtocolError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::UnsupportedVersion => "unsupported SOCKS version",
            Self::UnsupportedAuthenticationMethod => {
                "username/password authentication was not offered"
            }
            Self::InvalidCredentialLength => "SOCKS5 credentials must contain 1..=255 bytes",
            Self::MalformedAuthentication => "malformed SOCKS5 authentication frame",
            Self::AuthenticationFailed => "SOCKS5 authentication failed",
            Self::MalformedRequest => "malformed SOCKS5 request",
            Self::BindNotSupported => "SOCKS5 BIND is not supported",
            Self::UdpAssociateNotSupported => "SOCKS5 UDP ASSOCIATE is not supported",
            Self::CommandNotSupported => "SOCKS5 command is not supported",
            Self::AddressNotSupported => "SOCKS5 address type is not supported",
            Self::InvalidDomain => "SOCKS5 domain target is invalid",
            Self::InvalidPort => "SOCKS5 destination port must be non-zero",
            Self::Target(_) => "SOCKS5 target is rejected by Proxy Serving policy",
        })
    }
}

impl std::error::Error for Socks5ProtocolError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Target(error) => Some(error),
            _ => None,
        }
    }
}

#[derive(Debug)]
pub enum Socks5SessionError {
    Io(io::Error),
    Protocol(Socks5ProtocolError),
}

impl fmt::Display for Socks5SessionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(formatter, "SOCKS5 I/O failed: {error}"),
            Self::Protocol(error) => write!(formatter, "SOCKS5 protocol failed: {error}"),
        }
    }
}

impl std::error::Error for Socks5SessionError {}

impl From<io::Error> for Socks5SessionError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<Socks5ProtocolError> for Socks5SessionError {
    fn from(error: Socks5ProtocolError) -> Self {
        Self::Protocol(error)
    }
}

/// Performs the bounded SOCKS5 greeting, RFC1929 authentication and CONNECT request decode.
///
/// The returned target is typed but unresolved. This protocol capability performs no DNS,
/// network selection, socket connection, listener ownership or relay work.
pub fn accept_socks5_connect<S: Read + Write>(
    stream: &mut S,
    credentials: &ProxyCredentialMaterial,
) -> Result<ProxyConnectTarget, Socks5SessionError> {
    validate_credentials(credentials)?;
    negotiate_username_password(stream)?;
    authenticate(stream, credentials)?;
    read_connect_request(stream)
}

pub fn write_socks5_reply<W: Write>(
    stream: &mut W,
    reply: Socks5Reply,
    bound: SocketAddr,
) -> io::Result<()> {
    let mut frame = Vec::with_capacity(22);
    frame.extend_from_slice(&[SOCKS_VERSION, reply.code(), 0x00]);
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

fn validate_credentials(credentials: &ProxyCredentialMaterial) -> Result<(), Socks5ProtocolError> {
    if credentials.username().is_empty()
        || credentials.username().len() > MAX_AUTH_FIELD_LEN
        || credentials.password().is_empty()
        || credentials.password().len() > MAX_AUTH_FIELD_LEN
    {
        Err(Socks5ProtocolError::InvalidCredentialLength)
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

fn negotiate_username_password<S: Read + Write>(stream: &mut S) -> Result<(), Socks5SessionError> {
    let mut header = [0_u8; 2];
    stream.read_exact(&mut header)?;
    if header[0] != SOCKS_VERSION {
        return Err(Socks5ProtocolError::UnsupportedVersion.into());
    }

    let method_count = usize::from(header[1]);
    if method_count == 0 {
        stream.write_all(&[SOCKS_VERSION, NO_ACCEPTABLE_METHODS])?;
        return Err(Socks5ProtocolError::UnsupportedAuthenticationMethod.into());
    }

    let mut methods = vec![0_u8; method_count];
    stream.read_exact(&mut methods)?;
    if !methods.contains(&USERNAME_PASSWORD_METHOD) {
        stream.write_all(&[SOCKS_VERSION, NO_ACCEPTABLE_METHODS])?;
        return Err(Socks5ProtocolError::UnsupportedAuthenticationMethod.into());
    }

    stream.write_all(&[SOCKS_VERSION, USERNAME_PASSWORD_METHOD])?;
    Ok(())
}

fn authenticate<S: Read + Write>(
    stream: &mut S,
    credentials: &ProxyCredentialMaterial,
) -> Result<(), Socks5SessionError> {
    let mut header = [0_u8; 2];
    stream.read_exact(&mut header)?;
    if header[0] != USERNAME_PASSWORD_VERSION || header[1] == 0 {
        let _ = stream.write_all(&[USERNAME_PASSWORD_VERSION, 0x01]);
        return Err(Socks5ProtocolError::MalformedAuthentication.into());
    }

    let mut username = vec![0_u8; usize::from(header[1])];
    stream.read_exact(&mut username)?;

    let mut password_len = [0_u8; 1];
    stream.read_exact(&mut password_len)?;
    if password_len[0] == 0 {
        let _ = stream.write_all(&[USERNAME_PASSWORD_VERSION, 0x01]);
        return Err(Socks5ProtocolError::MalformedAuthentication.into());
    }

    let mut password = vec![0_u8; usize::from(password_len[0])];
    stream.read_exact(&mut password)?;

    if !(constant_time_eq(credentials.username().as_bytes(), &username)
        & constant_time_eq(credentials.password().as_bytes(), &password))
    {
        stream.write_all(&[USERNAME_PASSWORD_VERSION, 0x01])?;
        return Err(Socks5ProtocolError::AuthenticationFailed.into());
    }

    stream.write_all(&[USERNAME_PASSWORD_VERSION, 0x00])?;
    Ok(())
}

fn read_connect_request<S: Read + Write>(
    stream: &mut S,
) -> Result<ProxyConnectTarget, Socks5SessionError> {
    let mut header = [0_u8; 4];
    stream.read_exact(&mut header)?;
    if header[0] != SOCKS_VERSION || header[2] != 0 {
        write_socks5_reply(stream, Socks5Reply::GeneralFailure, unspecified_bind_addr())?;
        return Err(Socks5ProtocolError::MalformedRequest.into());
    }

    match header[1] {
        CONNECT_COMMAND => {}
        BIND_COMMAND => {
            write_socks5_reply(
                stream,
                Socks5Reply::CommandNotSupported,
                unspecified_bind_addr(),
            )?;
            return Err(Socks5ProtocolError::BindNotSupported.into());
        }
        UDP_ASSOCIATE_COMMAND => {
            write_socks5_reply(
                stream,
                Socks5Reply::CommandNotSupported,
                unspecified_bind_addr(),
            )?;
            return Err(Socks5ProtocolError::UdpAssociateNotSupported.into());
        }
        _ => {
            write_socks5_reply(
                stream,
                Socks5Reply::CommandNotSupported,
                unspecified_bind_addr(),
            )?;
            return Err(Socks5ProtocolError::CommandNotSupported.into());
        }
    }

    let target = match header[3] {
        IPV4_ADDRESS_TYPE => {
            let mut octets = [0_u8; 4];
            stream.read_exact(&mut octets)?;
            let port = read_port(stream)?;
            ProxyConnectTarget::ipv4(Ipv4Addr::from(octets), port)
        }
        IPV6_ADDRESS_TYPE => {
            let mut octets = [0_u8; 16];
            stream.read_exact(&mut octets)?;
            let port = read_port(stream)?;
            ProxyConnectTarget::ipv6(Ipv6Addr::from(octets), port)
        }
        DOMAIN_ADDRESS_TYPE => {
            let mut length = [0_u8; 1];
            stream.read_exact(&mut length)?;
            if length[0] == 0 {
                write_socks5_reply(
                    stream,
                    Socks5Reply::AddressTypeNotSupported,
                    unspecified_bind_addr(),
                )?;
                return Err(Socks5ProtocolError::InvalidDomain.into());
            }
            let mut bytes = vec![0_u8; usize::from(length[0])];
            stream.read_exact(&mut bytes)?;
            let domain =
                std::str::from_utf8(&bytes).map_err(|_| Socks5ProtocolError::InvalidDomain)?;
            if domain
                .bytes()
                .any(|byte| byte == 0 || byte.is_ascii_control())
            {
                write_socks5_reply(
                    stream,
                    Socks5Reply::AddressTypeNotSupported,
                    unspecified_bind_addr(),
                )?;
                return Err(Socks5ProtocolError::InvalidDomain.into());
            }
            let port = read_port(stream)?;
            ProxyConnectTarget::domain(domain, port)
        }
        _ => {
            write_socks5_reply(
                stream,
                Socks5Reply::AddressTypeNotSupported,
                unspecified_bind_addr(),
            )?;
            return Err(Socks5ProtocolError::AddressNotSupported.into());
        }
    };

    target.map_err(|error| match error {
        ProxyTargetError::ZeroPort => Socks5ProtocolError::InvalidPort.into(),
        other => Socks5ProtocolError::Target(other).into(),
    })
}

fn read_port<S: Read + Write>(stream: &mut S) -> Result<u16, Socks5SessionError> {
    let mut port = [0_u8; 2];
    stream.read_exact(&mut port)?;
    let port = u16::from_be_bytes(port);
    if port == 0 {
        write_socks5_reply(stream, Socks5Reply::GeneralFailure, unspecified_bind_addr())?;
        return Err(Socks5ProtocolError::InvalidPort.into());
    }
    Ok(port)
}

fn unspecified_bind_addr() -> SocketAddr {
    SocketAddr::new(IpAddr::V4(Ipv4Addr::UNSPECIFIED), 0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ProxyTargetHost;

    #[derive(Debug)]
    struct TestIo {
        input: io::Cursor<Vec<u8>>,
        output: Vec<u8>,
    }

    impl TestIo {
        fn new(input: Vec<u8>) -> Self {
            Self {
                input: io::Cursor::new(input),
                output: Vec::new(),
            }
        }
    }

    impl Read for TestIo {
        fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
            self.input.read(buffer)
        }
    }

    impl Write for TestIo {
        fn write(&mut self, buffer: &[u8]) -> io::Result<usize> {
            self.output.extend_from_slice(buffer);
            Ok(buffer.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn credentials() -> ProxyCredentialMaterial {
        ProxyCredentialMaterial::new("user", "password").expect("valid credentials")
    }

    fn authenticated_prefix() -> Vec<u8> {
        let mut bytes = vec![SOCKS_VERSION, 1, USERNAME_PASSWORD_METHOD];
        bytes.extend_from_slice(&[USERNAME_PASSWORD_VERSION, 4]);
        bytes.extend_from_slice(b"user");
        bytes.push(8);
        bytes.extend_from_slice(b"password");
        bytes
    }

    #[test]
    fn authenticated_domain_connect_remains_unresolved() {
        let mut input = authenticated_prefix();
        input.extend_from_slice(&[SOCKS_VERSION, CONNECT_COMMAND, 0, DOMAIN_ADDRESS_TYPE, 15]);
        input.extend_from_slice(b"example.invalid");
        input.extend_from_slice(&443_u16.to_be_bytes());
        let mut io = TestIo::new(input);

        let target = accept_socks5_connect(&mut io, &credentials()).expect("CONNECT accepted");
        assert_eq!(target.port(), 443);
        assert_eq!(
            target.host(),
            &ProxyTargetHost::Domain("example.invalid".into())
        );
        assert_eq!(target.host().numeric(), None);
        assert_eq!(
            io.output,
            vec![
                SOCKS_VERSION,
                USERNAME_PASSWORD_METHOD,
                USERNAME_PASSWORD_VERSION,
                0x00,
            ]
        );
    }

    #[test]
    fn ipv4_and_ipv6_are_typed_without_dns() {
        let mut ipv4_input = authenticated_prefix();
        ipv4_input.extend_from_slice(&[
            SOCKS_VERSION,
            CONNECT_COMMAND,
            0,
            IPV4_ADDRESS_TYPE,
            203,
            0,
            113,
            9,
        ]);
        ipv4_input.extend_from_slice(&8443_u16.to_be_bytes());
        let mut ipv4_io = TestIo::new(ipv4_input);
        let ipv4 = accept_socks5_connect(&mut ipv4_io, &credentials()).expect("IPv4 accepted");
        assert_eq!(
            ipv4.host(),
            &ProxyTargetHost::Ipv4(Ipv4Addr::new(203, 0, 113, 9))
        );

        let mut ipv6_input = authenticated_prefix();
        ipv6_input.extend_from_slice(&[SOCKS_VERSION, CONNECT_COMMAND, 0, IPV6_ADDRESS_TYPE]);
        ipv6_input.extend_from_slice(&"2001:db8::1".parse::<Ipv6Addr>().expect("IPv6").octets());
        ipv6_input.extend_from_slice(&443_u16.to_be_bytes());
        let mut ipv6_io = TestIo::new(ipv6_input);
        let ipv6 = accept_socks5_connect(&mut ipv6_io, &credentials()).expect("IPv6 accepted");
        assert_eq!(
            ipv6.host(),
            &ProxyTargetHost::Ipv6("2001:db8::1".parse().expect("IPv6"))
        );
    }

    #[test]
    fn missing_auth_method_fails_closed() {
        let mut io = TestIo::new(vec![SOCKS_VERSION, 1, 0x00]);
        let error = accept_socks5_connect(&mut io, &credentials()).expect_err("must reject");
        assert!(matches!(
            error,
            Socks5SessionError::Protocol(Socks5ProtocolError::UnsupportedAuthenticationMethod)
        ));
        assert_eq!(io.output, vec![SOCKS_VERSION, NO_ACCEPTABLE_METHODS]);
    }

    #[test]
    fn wrong_authentication_fails_closed() {
        let mut input = vec![SOCKS_VERSION, 1, USERNAME_PASSWORD_METHOD];
        input.extend_from_slice(&[USERNAME_PASSWORD_VERSION, 4]);
        input.extend_from_slice(b"user");
        input.push(5);
        input.extend_from_slice(b"wrong");
        let mut io = TestIo::new(input);
        let error = accept_socks5_connect(&mut io, &credentials()).expect_err("must reject");
        assert!(matches!(
            error,
            Socks5SessionError::Protocol(Socks5ProtocolError::AuthenticationFailed)
        ));
        assert_eq!(
            io.output,
            vec![
                SOCKS_VERSION,
                USERNAME_PASSWORD_METHOD,
                USERNAME_PASSWORD_VERSION,
                0x01,
            ]
        );
    }

    #[test]
    fn bind_and_udp_are_explicitly_rejected() {
        for (command, expected) in [
            (BIND_COMMAND, Socks5ProtocolError::BindNotSupported),
            (
                UDP_ASSOCIATE_COMMAND,
                Socks5ProtocolError::UdpAssociateNotSupported,
            ),
        ] {
            let mut input = authenticated_prefix();
            input.extend_from_slice(&[
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
            ]);
            let mut io = TestIo::new(input);
            let error = accept_socks5_connect(&mut io, &credentials()).expect_err("must reject");
            assert!(matches!(error, Socks5SessionError::Protocol(value) if value == expected));
            assert_eq!(
                &io.output[4..6],
                &[SOCKS_VERSION, Socks5Reply::CommandNotSupported.code()]
            );
        }
    }

    #[test]
    fn zero_port_and_empty_domain_fail_closed() {
        let mut zero_port = authenticated_prefix();
        zero_port.extend_from_slice(&[
            SOCKS_VERSION,
            CONNECT_COMMAND,
            0,
            IPV4_ADDRESS_TYPE,
            127,
            0,
            0,
            1,
            0,
            0,
        ]);
        let mut zero_port_io = TestIo::new(zero_port);
        assert!(matches!(
            accept_socks5_connect(&mut zero_port_io, &credentials()),
            Err(Socks5SessionError::Protocol(
                Socks5ProtocolError::InvalidPort
            ))
        ));

        let mut empty_domain = authenticated_prefix();
        empty_domain.extend_from_slice(&[
            SOCKS_VERSION,
            CONNECT_COMMAND,
            0,
            DOMAIN_ADDRESS_TYPE,
            0,
        ]);
        let mut empty_domain_io = TestIo::new(empty_domain);
        assert!(matches!(
            accept_socks5_connect(&mut empty_domain_io, &credentials()),
            Err(Socks5SessionError::Protocol(
                Socks5ProtocolError::InvalidDomain
            ))
        ));
    }

    #[test]
    fn reply_encoding_supports_ipv4_and_ipv6_bound_addresses() {
        let mut ipv4 = Vec::new();
        write_socks5_reply(
            &mut ipv4,
            Socks5Reply::Succeeded,
            "127.0.0.1:1234".parse().expect("IPv4 bound address"),
        )
        .expect("reply");
        assert_eq!(ipv4[0..4], [SOCKS_VERSION, 0x00, 0x00, IPV4_ADDRESS_TYPE]);

        let mut ipv6 = Vec::new();
        write_socks5_reply(
            &mut ipv6,
            Socks5Reply::Succeeded,
            "[::1]:1234".parse().expect("IPv6 bound address"),
        )
        .expect("reply");
        assert_eq!(ipv6[0..4], [SOCKS_VERSION, 0x00, 0x00, IPV6_ADDRESS_TYPE]);
    }
}
