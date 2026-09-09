//! Proxy Serving natural-owner capability.
//!
//! Owns the vendor-neutral listener and public authentication policy. Vendor JSON,
//! Mesh endpoint discovery, credential persistence, cellular selection, and child
//! process lifecycle remain outside this capability.

use std::{error::Error, fmt, net::IpAddr};

pub const MIXED_PORT: u16 = 1080;
pub const SOCKS5_PORT: u16 = 1081;
pub const HTTP_CONNECT_PORT: u16 = 3128;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyProtocol {
    Mixed,
    Socks5,
    Http,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProxyListener {
    pub protocol: ProxyProtocol,
    pub port: u16,
}

const CANONICAL_LISTENERS: [ProxyListener; 3] = [
    ProxyListener {
        protocol: ProxyProtocol::Mixed,
        port: MIXED_PORT,
    },
    ProxyListener {
        protocol: ProxyProtocol::Socks5,
        port: SOCKS5_PORT,
    },
    ProxyListener {
        protocol: ProxyProtocol::Http,
        port: HTTP_CONNECT_PORT,
    },
];

#[derive(Clone, PartialEq, Eq)]
pub struct ProxyCredentialMaterial {
    username: String,
    password: String,
}

impl ProxyCredentialMaterial {
    pub fn new(
        username: impl Into<String>,
        password: impl Into<String>,
    ) -> Result<Self, ProxyPolicyError> {
        let username = username.into();
        let password = password.into();

        if username.trim().is_empty() {
            return Err(ProxyPolicyError::EmptyUsername);
        }
        if password.trim().is_empty() {
            return Err(ProxyPolicyError::EmptyPassword);
        }

        Ok(Self { username, password })
    }

    pub fn username(&self) -> &str {
        &self.username
    }

    pub fn password(&self) -> &str {
        &self.password
    }
}

impl fmt::Debug for ProxyCredentialMaterial {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProxyCredentialMaterial")
            .field("username", &"<redacted>")
            .field("password", &"<redacted>")
            .finish()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProxyServingPlan {
    listen_address: IpAddr,
    credentials: ProxyCredentialMaterial,
}

impl ProxyServingPlan {
    /// Builds the canonical public serving plan for an exact address supplied by the
    /// Transport/composition boundary. Wildcard exposure is forbidden fail-closed.
    pub fn canonical(
        listen_address: IpAddr,
        credentials: ProxyCredentialMaterial,
    ) -> Result<Self, ProxyPolicyError> {
        if listen_address.is_unspecified() {
            return Err(ProxyPolicyError::WildcardListenAddress);
        }

        Ok(Self {
            listen_address,
            credentials,
        })
    }

    pub fn listen_address(&self) -> IpAddr {
        self.listen_address
    }

    pub fn listeners(&self) -> &'static [ProxyListener; 3] {
        &CANONICAL_LISTENERS
    }

    /// Runtime-resolved material consumed by the serving adapter. This capability owns
    /// authentication semantics, not durable credential storage.
    pub fn credentials(&self) -> &ProxyCredentialMaterial {
        &self.credentials
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyPolicyError {
    WildcardListenAddress,
    EmptyUsername,
    EmptyPassword,
}

impl fmt::Display for ProxyPolicyError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::WildcardListenAddress => "wildcard proxy exposure is forbidden",
            Self::EmptyUsername => "public proxy username must be non-empty",
            Self::EmptyPassword => "public proxy password must be non-empty",
        };
        formatter.write_str(message)
    }
}

impl Error for ProxyPolicyError {}

#[cfg(test)]
mod tests {
    use super::*;

    fn credentials() -> ProxyCredentialMaterial {
        ProxyCredentialMaterial::new("ci-user", "ci-password").expect("valid credentials")
    }

    #[test]
    fn canonical_listener_contract_is_fixed() {
        let plan = ProxyServingPlan::canonical(IpAddr::from([127, 0, 0, 1]), credentials())
            .expect("explicit address");

        assert_eq!(
            plan.listeners(),
            &[
                ProxyListener {
                    protocol: ProxyProtocol::Mixed,
                    port: 1080,
                },
                ProxyListener {
                    protocol: ProxyProtocol::Socks5,
                    port: 1081,
                },
                ProxyListener {
                    protocol: ProxyProtocol::Http,
                    port: 3128,
                },
            ],
        );
    }

    #[test]
    fn wildcard_ipv4_and_ipv6_are_rejected() {
        for address in ["0.0.0.0", "::"] {
            let error =
                ProxyServingPlan::canonical(address.parse().expect("valid IP"), credentials())
                    .expect_err("wildcard must fail closed");
            assert_eq!(error, ProxyPolicyError::WildcardListenAddress);
        }
    }

    #[test]
    fn explicit_loopback_is_allowed_for_bounded_local_acceptance() {
        let plan = ProxyServingPlan::canonical(IpAddr::from([127, 0, 0, 1]), credentials())
            .expect("explicit loopback is not wildcard exposure");
        assert_eq!(plan.listen_address(), IpAddr::from([127, 0, 0, 1]));
    }

    #[test]
    fn public_authentication_material_cannot_be_empty() {
        assert_eq!(
            ProxyCredentialMaterial::new("", "password"),
            Err(ProxyPolicyError::EmptyUsername),
        );
        assert_eq!(
            ProxyCredentialMaterial::new("user", "  "),
            Err(ProxyPolicyError::EmptyPassword),
        );
    }

    #[test]
    fn credential_debug_output_is_redacted() {
        let material = ProxyCredentialMaterial::new("visible-user", "secret-password")
            .expect("valid credentials");
        let debug = format!("{material:?}");
        assert!(!debug.contains("visible-user"));
        assert!(!debug.contains("secret-password"));
        assert!(debug.contains("<redacted>"));
    }
}
