use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

const MAX_DOMAIN_BYTES: usize = u8::MAX as usize;

/// Vendor-neutral destination preserved by Proxy Serving until Cellular Egress owns resolution.
///
/// A domain stays a domain. This type deliberately exposes no resolver or socket-address
/// conversion API, so Proxy Serving cannot accidentally use the process/default DNS path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxyConnectTarget {
    host: ProxyTargetHost,
    port: u16,
}

impl ProxyConnectTarget {
    pub fn new(host: ProxyTargetHost, port: u16) -> Result<Self, ProxyTargetError> {
        if port == 0 {
            return Err(ProxyTargetError::ZeroPort);
        }
        Ok(Self { host, port })
    }

    pub fn ipv4(address: Ipv4Addr, port: u16) -> Result<Self, ProxyTargetError> {
        Self::new(ProxyTargetHost::Ipv4(address), port)
    }

    pub fn ipv6(address: Ipv6Addr, port: u16) -> Result<Self, ProxyTargetError> {
        Self::new(ProxyTargetHost::Ipv6(address), port)
    }

    pub fn domain(domain: impl Into<String>, port: u16) -> Result<Self, ProxyTargetError> {
        Self::new(ProxyTargetHost::domain(domain)?, port)
    }

    pub const fn host(&self) -> &ProxyTargetHost {
        &self.host
    }

    pub const fn port(&self) -> u16 {
        self.port
    }
}

/// Destination identity before any network-specific DNS effect.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProxyTargetHost {
    Ipv4(Ipv4Addr),
    Ipv6(Ipv6Addr),
    Domain(Box<str>),
}

impl ProxyTargetHost {
    pub fn domain(domain: impl Into<String>) -> Result<Self, ProxyTargetError> {
        let domain = domain.into();
        if domain.is_empty() {
            return Err(ProxyTargetError::EmptyDomain);
        }
        if domain.len() > MAX_DOMAIN_BYTES {
            return Err(ProxyTargetError::DomainTooLong);
        }
        if domain
            .bytes()
            .any(|byte| byte == 0 || byte.is_ascii_control())
        {
            return Err(ProxyTargetError::InvalidDomain);
        }
        Ok(Self::Domain(domain.into_boxed_str()))
    }

    pub const fn numeric(&self) -> Option<IpAddr> {
        match self {
            Self::Ipv4(address) => Some(IpAddr::V4(*address)),
            Self::Ipv6(address) => Some(IpAddr::V6(*address)),
            Self::Domain(_) => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyTargetError {
    EmptyDomain,
    DomainTooLong,
    InvalidDomain,
    ZeroPort,
}

impl fmt::Display for ProxyTargetError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::EmptyDomain => "proxy target domain must not be empty",
            Self::DomainTooLong => "proxy target domain exceeds the bounded protocol field",
            Self::InvalidDomain => "proxy target domain contains a forbidden control byte",
            Self::ZeroPort => "proxy target port must be non-zero",
        })
    }
}

impl std::error::Error for ProxyTargetError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn domain_is_preserved_without_resolution() {
        let target = ProxyConnectTarget::domain("example.invalid", 443).expect("valid target");
        assert_eq!(
            target.host(),
            &ProxyTargetHost::Domain("example.invalid".into())
        );
        assert_eq!(target.port(), 443);
        assert_eq!(target.host().numeric(), None);
    }

    #[test]
    fn numeric_targets_are_explicit_and_skip_domain_semantics() {
        let ipv4 = Ipv4Addr::new(203, 0, 113, 10);
        let ipv6 = Ipv6Addr::LOCALHOST;
        assert_eq!(
            ProxyConnectTarget::ipv4(ipv4, 443)
                .expect("IPv4 target")
                .host()
                .numeric(),
            Some(IpAddr::V4(ipv4))
        );
        assert_eq!(
            ProxyConnectTarget::ipv6(ipv6, 443)
                .expect("IPv6 target")
                .host()
                .numeric(),
            Some(IpAddr::V6(ipv6))
        );
    }

    #[test]
    fn invalid_domain_and_zero_port_fail_closed() {
        assert_eq!(
            ProxyConnectTarget::domain("", 443),
            Err(ProxyTargetError::EmptyDomain)
        );
        assert_eq!(
            ProxyConnectTarget::domain("bad\0host", 443),
            Err(ProxyTargetError::InvalidDomain)
        );
        assert_eq!(
            ProxyConnectTarget::domain("example.invalid", 0),
            Err(ProxyTargetError::ZeroPort)
        );
        assert_eq!(
            ProxyConnectTarget::domain("x".repeat(256), 443),
            Err(ProxyTargetError::DomainTooLong)
        );
    }
}
