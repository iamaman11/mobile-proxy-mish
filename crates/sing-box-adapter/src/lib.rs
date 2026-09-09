//! Explicit sing-box vendor boundary.
//!
//! JSON is permitted only inside this adapter when required by sing-box. Generated
//! vendor JSON is disposable output and never authoritative product state.

use std::{error::Error, fmt, net::IpAddr};

use mish_proxy::{ProxyProtocol, ProxyServingPlan};
use serde_json::json;

pub const CELLULAR_EGRESS_OUTBOUND_TAG: &str = "cellular-egress";

/// Runtime-provided private SOCKS5 hop toward the bounded Cellular Egress bridge.
///
/// This adapter consumes the endpoint but does not own its lifecycle or durable secrets.
#[derive(Clone, PartialEq, Eq)]
pub struct PrivateSocks5Endpoint {
    address: IpAddr,
    port: u16,
    username: String,
    password: String,
}

impl PrivateSocks5Endpoint {
    pub fn new(
        address: IpAddr,
        port: u16,
        username: impl Into<String>,
        password: impl Into<String>,
    ) -> Result<Self, SingBoxAdapterError> {
        let username = username.into();
        let password = password.into();

        if !address.is_loopback() {
            return Err(SingBoxAdapterError::EgressNotLoopback);
        }
        if port == 0 {
            return Err(SingBoxAdapterError::EgressPortZero);
        }
        if username.trim().is_empty() {
            return Err(SingBoxAdapterError::EmptyEgressUsername);
        }
        if password.trim().is_empty() {
            return Err(SingBoxAdapterError::EmptyEgressPassword);
        }

        Ok(Self {
            address,
            port,
            username,
            password,
        })
    }
}

impl fmt::Debug for PrivateSocks5Endpoint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("PrivateSocks5Endpoint")
            .field("address", &self.address)
            .field("port", &self.port)
            .field("username", &"<redacted>")
            .field("password", &"<redacted>")
            .finish()
    }
}

/// Render disposable sing-box JSON from already-owned product facts.
///
/// The generated product configuration has exactly one outbound and it is the private
/// SOCKS5 cellular-egress hop. There is deliberately no `direct` fallback and no DNS
/// section: destination domains remain available to the SOCKS5 egress boundary, where
/// Cellular Egress can perform network-scoped DNS.
pub fn render_product_config(
    plan: &ProxyServingPlan,
    egress: &PrivateSocks5Endpoint,
) -> Result<String, SingBoxAdapterError> {
    let listen = plan.listen_address().to_string();
    let public_user = plan.credentials();

    let inbounds = plan
        .listeners()
        .iter()
        .map(|listener| {
            let base_user = json!({
                "username": public_user.username(),
                "password": public_user.password(),
            });

            match listener.protocol {
                ProxyProtocol::Mixed => json!({
                    "type": "mixed",
                    "tag": "mixed-in",
                    "listen": listen.as_str(),
                    "listen_port": listener.port,
                    "users": [base_user],
                    "set_system_proxy": false,
                }),
                ProxyProtocol::Socks5 => json!({
                    "type": "socks",
                    "tag": "socks-in",
                    "listen": listen.as_str(),
                    "listen_port": listener.port,
                    "users": [base_user],
                }),
                ProxyProtocol::Http => json!({
                    "type": "http",
                    "tag": "http-in",
                    "listen": listen.as_str(),
                    "listen_port": listener.port,
                    "users": [base_user],
                    "set_system_proxy": false,
                }),
            }
        })
        .collect::<Vec<_>>();

    let config = json!({
        "inbounds": inbounds,
        "outbounds": [{
            "type": "socks",
            "tag": CELLULAR_EGRESS_OUTBOUND_TAG,
            "server": egress.address.to_string(),
            "server_port": egress.port,
            "version": "5",
            "username": egress.username.as_str(),
            "password": egress.password.as_str(),
            "network": "tcp",
        }],
        "route": {
            "final": CELLULAR_EGRESS_OUTBOUND_TAG,
        },
    });

    let mut rendered = serde_json::to_string_pretty(&config).map_err(SingBoxAdapterError::Json)?;
    rendered.push('\n');
    Ok(rendered)
}

#[derive(Debug)]
pub enum SingBoxAdapterError {
    EgressNotLoopback,
    EgressPortZero,
    EmptyEgressUsername,
    EmptyEgressPassword,
    Json(serde_json::Error),
}

impl fmt::Display for SingBoxAdapterError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EgressNotLoopback => {
                formatter.write_str("cellular egress SOCKS endpoint must be loopback")
            }
            Self::EgressPortZero => formatter.write_str("cellular egress port must be non-zero"),
            Self::EmptyEgressUsername => {
                formatter.write_str("cellular egress username must be non-empty")
            }
            Self::EmptyEgressPassword => {
                formatter.write_str("cellular egress password must be non-empty")
            }
            Self::Json(error) => write!(formatter, "sing-box JSON serialization failed: {error}"),
        }
    }
}

impl Error for SingBoxAdapterError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Json(error) => Some(error),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::net::{IpAddr, Ipv4Addr};

    use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
    use serde_json::Value;

    use super::*;

    fn plan() -> ProxyServingPlan {
        ProxyServingPlan::canonical(
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            ProxyCredentialMaterial::new("public-user", "public-secret")
                .expect("valid public credentials"),
        )
        .expect("explicit listen address")
    }

    fn egress() -> PrivateSocks5Endpoint {
        PrivateSocks5Endpoint::new(
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            19080,
            "egress-user",
            "egress-secret",
        )
        .expect("valid private endpoint")
    }

    #[test]
    fn private_egress_endpoint_is_loopback_only_and_authenticated() {
        assert!(matches!(
            PrivateSocks5Endpoint::new(
                IpAddr::V4(Ipv4Addr::new(192, 0, 2, 1)),
                19080,
                "user",
                "secret",
            ),
            Err(SingBoxAdapterError::EgressNotLoopback)
        ));
        assert!(matches!(
            PrivateSocks5Endpoint::new(
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                0,
                "user",
                "secret",
            ),
            Err(SingBoxAdapterError::EgressPortZero)
        ));
        assert!(matches!(
            PrivateSocks5Endpoint::new(
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                19080,
                "",
                "secret",
            ),
            Err(SingBoxAdapterError::EmptyEgressUsername)
        ));
        assert!(matches!(
            PrivateSocks5Endpoint::new(
                IpAddr::V4(Ipv4Addr::LOCALHOST),
                19080,
                "user",
                "",
            ),
            Err(SingBoxAdapterError::EmptyEgressPassword)
        ));
    }

    #[test]
    fn endpoint_debug_output_redacts_private_credentials() {
        let debug = format!("{:?}", egress());
        assert!(!debug.contains("egress-user"));
        assert!(!debug.contains("egress-secret"));
        assert!(debug.contains("<redacted>"));
    }

    #[test]
    fn product_config_has_exact_public_listeners_and_auth() {
        let rendered = render_product_config(&plan(), &egress()).expect("render config");
        let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
        let inbounds = value["inbounds"].as_array().expect("inbounds array");

        assert_eq!(inbounds.len(), 3);
        assert_eq!(inbounds[0]["type"], "mixed");
        assert_eq!(inbounds[0]["listen_port"], 1080);
        assert_eq!(inbounds[1]["type"], "socks");
        assert_eq!(inbounds[1]["listen_port"], 1081);
        assert_eq!(inbounds[2]["type"], "http");
        assert_eq!(inbounds[2]["listen_port"], 3128);

        for inbound in inbounds {
            assert_eq!(inbound["listen"], "127.0.0.1");
            let users = inbound["users"].as_array().expect("auth users");
            assert_eq!(users.len(), 1);
            assert_eq!(users[0]["username"], "public-user");
            assert_eq!(users[0]["password"], "public-secret");
        }
        assert_eq!(inbounds[0]["set_system_proxy"], false);
        assert_eq!(inbounds[2]["set_system_proxy"], false);
    }

    #[test]
    fn product_config_has_one_private_socks_outbound_and_no_direct_fallback() {
        let rendered = render_product_config(&plan(), &egress()).expect("render config");
        let value: Value = serde_json::from_str(&rendered).expect("valid JSON");
        let outbounds = value["outbounds"].as_array().expect("outbounds array");

        assert_eq!(outbounds.len(), 1);
        assert_eq!(outbounds[0]["type"], "socks");
        assert_eq!(outbounds[0]["tag"], CELLULAR_EGRESS_OUTBOUND_TAG);
        assert_eq!(outbounds[0]["server"], "127.0.0.1");
        assert_eq!(outbounds[0]["server_port"], 19080);
        assert_eq!(outbounds[0]["version"], "5");
        assert_eq!(outbounds[0]["network"], "tcp");
        assert_eq!(value["route"]["final"], CELLULAR_EGRESS_OUTBOUND_TAG);

        assert!(!rendered.contains("\"type\": \"direct\""));
        assert!(value.get("dns").is_none());
        assert!(value.get("experimental").is_none());
    }

    #[test]
    fn rendering_is_deterministic_for_identical_inputs() {
        let first = render_product_config(&plan(), &egress()).expect("render first");
        let second = render_product_config(&plan(), &egress()).expect("render second");
        assert_eq!(first, second);
    }
}
