//! Desired Configuration natural-owner capability.
//!
//! Owns validated non-secret desired product state. Platform/IaC adapters may materialize or
//! persist an owner-approved value, but must not redefine its syntax or safety constraints.

use std::fmt;
use std::net::{IpAddr, Ipv4Addr};

const MIN_MESH_ACCEPTED_PREFIX: u8 = 8;
const READINESS_PROBE_PORT: u16 = 443;

/// Bounded, fail-closed concurrent TCP budget for one external proxy runtime generation.
///
/// Transport owns this one external admission fact while admitted Mesh/Proxy work executes on the
/// single process-wide Tokio runtime owned by `mish-runtime`. Connections above the budget are
/// rejected at the Mesh edge; they are never rerouted through a default/VPN path. Raising this
/// value requires measured Android/LAB capacity evidence, not an executor or timeout workaround.
///
/// U7 DEVICE-1 capacity candidate: 512 sessions. This remains one shared, fail-closed bound, not
/// an autoscaling target or a second execution/admission authority.
pub const EXTERNAL_TCP_SESSION_BUDGET: usize = 512;
const DEPLOYMENT_MESH_ACCEPTED_CIDR_RAW: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../config/deployment/mesh-device-cidr.txt"
));
const DEPLOYMENT_READINESS_PROBE_HOST_RAW: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../config/deployment/readiness-probe-host.txt"
));
const DEPLOYMENT_CONTROL_HOST_RAW: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../config/deployment/control-host.txt"
));
const CONTROL_PORT: u16 = 443;
const CONTROL_DEVICE_PATH: &str = "/v1/device/connect";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeshAcceptedCidr {
    network: Ipv4Addr,
    prefix: u8,
}

impl MeshAcceptedCidr {
    /// Loads and validates the one repository-owned deployment Mesh classification.
    pub fn deployment() -> Result<Self, DesiredConfigurationError> {
        Self::parse(DEPLOYMENT_MESH_ACCEPTED_CIDR_RAW.trim())
    }

    /// Parses one canonical deployment-approved IPv4 CIDR for Mesh endpoint admission.
    ///
    /// This is a range/classification fact, never an exact live Mesh endpoint. The exact endpoint
    /// remains a fresh Transport Reachability observation and is never inferred from this value.
    pub fn parse(raw: &str) -> Result<Self, DesiredConfigurationError> {
        if raw.is_empty() || raw.trim() != raw {
            return Err(DesiredConfigurationError::InvalidMeshAcceptedCidr);
        }
        let (network, prefix) = raw
            .split_once('/')
            .ok_or(DesiredConfigurationError::InvalidMeshAcceptedCidr)?;
        if prefix.contains('/') {
            return Err(DesiredConfigurationError::InvalidMeshAcceptedCidr);
        }
        let network = network
            .parse::<Ipv4Addr>()
            .map_err(|_| DesiredConfigurationError::InvalidMeshAcceptedCidr)?;
        let prefix = prefix
            .parse::<u8>()
            .map_err(|_| DesiredConfigurationError::InvalidMeshAcceptedCidr)?;
        if !(MIN_MESH_ACCEPTED_PREFIX..=32).contains(&prefix)
            || network.is_unspecified()
            || network.is_multicast()
            || network == Ipv4Addr::BROADCAST
        {
            return Err(DesiredConfigurationError::UnsafeMeshAcceptedCidr);
        }

        let mask = u32::MAX << (32 - prefix);
        if u32::from(network) & mask != u32::from(network) {
            return Err(DesiredConfigurationError::NonCanonicalMeshAcceptedCidr);
        }
        Ok(Self { network, prefix })
    }

    pub const fn network(self) -> Ipv4Addr {
        self.network
    }

    pub const fn prefix(self) -> u8 {
        self.prefix
    }
}

/// One repository-owned hostname used only by the bounded runtime readiness TLS probe.
///
/// It is intentionally a hostname, never an IP literal, so a successful probe necessarily crosses
/// the selected Cellular Egress DNS path. This is not the dedicated physical anti-leak canary used
/// by P1/E3/E4 and does not establish those stronger acceptance claims.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReadinessProbeTarget {
    hostname: String,
    port: u16,
}

impl ReadinessProbeTarget {
    pub fn deployment() -> Result<Self, DesiredConfigurationError> {
        Self::parse(
            DEPLOYMENT_READINESS_PROBE_HOST_RAW.trim(),
            READINESS_PROBE_PORT,
        )
    }

    pub fn parse(raw: &str, port: u16) -> Result<Self, DesiredConfigurationError> {
        if raw.is_empty()
            || raw.trim() != raw
            || raw.len() > 253
            || port == 0
            || raw.parse::<IpAddr>().is_ok()
            || !raw.contains('.')
        {
            return Err(DesiredConfigurationError::InvalidReadinessProbeTarget);
        }

        for label in raw.split('.') {
            if label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
            {
                return Err(DesiredConfigurationError::InvalidReadinessProbeTarget);
            }
        }

        Ok(Self {
            hostname: raw.to_owned(),
            port,
        })
    }

    pub fn hostname(&self) -> &str {
        &self.hostname
    }

    pub const fn port(&self) -> u16 {
        self.port
    }
}

/// Repository-owned non-secret endpoint for the outbound control WebSocket.
///
/// Only the host/path are desired configuration. Device identity and authentication material are
/// supplied by the dedicated control identity owner and never committed here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlEndpoint {
    hostname: String,
    port: u16,
    path: &'static str,
}

impl ControlEndpoint {
    pub fn deployment() -> Result<Self, DesiredConfigurationError> {
        Self::parse(
            DEPLOYMENT_CONTROL_HOST_RAW.trim(),
            CONTROL_PORT,
            CONTROL_DEVICE_PATH,
        )
    }

    pub fn parse(
        hostname: &str,
        port: u16,
        path: &'static str,
    ) -> Result<Self, DesiredConfigurationError> {
        if hostname.is_empty()
            || hostname.trim() != hostname
            || hostname.len() > 253
            || port == 0
            || hostname.parse::<IpAddr>().is_ok()
            || !hostname.contains('.')
            || path != CONTROL_DEVICE_PATH
        {
            return Err(DesiredConfigurationError::InvalidControlTarget);
        }
        for label in hostname.split('.') {
            if label.is_empty()
                || label.len() > 63
                || label.starts_with('-')
                || label.ends_with('-')
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
            {
                return Err(DesiredConfigurationError::InvalidControlTarget);
            }
        }
        Ok(Self {
            hostname: hostname.to_owned(),
            port,
            path,
        })
    }

    pub fn hostname(&self) -> &str {
        &self.hostname
    }

    pub const fn port(&self) -> u16 {
        self.port
    }

    pub const fn path(&self) -> &'static str {
        self.path
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DesiredConfigurationError {
    InvalidMeshAcceptedCidr,
    UnsafeMeshAcceptedCidr,
    NonCanonicalMeshAcceptedCidr,
    InvalidReadinessProbeTarget,
    InvalidControlTarget,
}

impl fmt::Display for DesiredConfigurationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidMeshAcceptedCidr => "Mesh accepted CIDR must be one exact IPv4 CIDR",
            Self::UnsafeMeshAcceptedCidr => "Mesh accepted CIDR is too broad or unsafe",
            Self::NonCanonicalMeshAcceptedCidr => {
                "Mesh accepted CIDR must use its canonical network address"
            }
            Self::InvalidReadinessProbeTarget => {
                "readiness probe target must be one canonical lowercase DNS hostname and port"
            }
            Self::InvalidControlTarget => {
                "control target must be one canonical lowercase DNS hostname and fixed WSS path"
            }
        })
    }
}

impl std::error::Error for DesiredConfigurationError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deployment_mesh_cidr_is_valid_owner_state() {
        let desired = MeshAcceptedCidr::deployment().expect("deployment desired configuration");
        assert_eq!(desired, MeshAcceptedCidr::parse("100.96.0.0/12").unwrap());
    }

    #[test]
    fn mesh_cidr_requires_one_canonical_safe_ipv4_range() {
        let desired = MeshAcceptedCidr::parse("100.96.0.0/12").expect("canonical fixture");
        assert_eq!(desired.network(), Ipv4Addr::new(100, 96, 0, 0));
        assert_eq!(desired.prefix(), 12);

        for invalid in [
            "",
            " 100.96.0.0/12",
            "100.96.0.0/12 ",
            "100.96.0.0",
            "100.96.0.1/12",
            "0.0.0.0/8",
            "224.0.0.0/8",
            "100.96.0.0/7",
            "2001:db8::/64",
        ] {
            assert!(
                MeshAcceptedCidr::parse(invalid).is_err(),
                "accepted {invalid}"
            );
        }
    }

    #[test]
    fn exact_host_cidr_remains_valid_desired_classification() {
        let desired = MeshAcceptedCidr::parse("100.96.2.4/32").expect("host CIDR");
        assert_eq!(desired.network(), Ipv4Addr::new(100, 96, 2, 4));
        assert_eq!(desired.prefix(), 32);
    }

    #[test]
    fn deployment_readiness_probe_is_valid_dns_target() {
        let target = ReadinessProbeTarget::deployment().expect("deployment probe target");
        assert_eq!(target.hostname(), "example.com");
        assert_eq!(target.port(), 443);
    }

    #[test]
    fn deployment_control_target_is_canonical_wss_origin() {
        let target = ControlEndpoint::deployment().expect("control target");
        assert_eq!(target.hostname(), "api.alegria.by");
        assert_eq!(target.port(), 443);
        assert_eq!(target.path(), "/v1/device/connect");
    }

    #[test]
    fn control_target_rejects_ip_case_injection_and_alternate_path() {
        for (host, port, path) in [
            ("", 443, "/v1/device/connect"),
            ("Api.alegria.by", 443, "/v1/device/connect"),
            ("127.0.0.1", 443, "/v1/device/connect"),
            ("api.alegria.by\r\nX: y", 443, "/v1/device/connect"),
            ("api.alegria.by", 0, "/v1/device/connect"),
            ("api.alegria.by", 443, "/other"),
        ] {
            assert!(ControlEndpoint::parse(host, port, path).is_err());
        }
    }

    #[test]
    fn readiness_probe_requires_canonical_hostname_not_ip_or_injection() {
        for (host, port) in [
            ("", 443),
            ("example.com", 0),
            (" example.com", 443),
            ("example.com ", 443),
            ("Example.com", 443),
            ("example.com.", 443),
            ("127.0.0.1", 443),
            ("2001:db8::1", 443),
            ("localhost", 443),
            ("-example.com", 443),
            ("example-.com", 443),
            ("example..com", 443),
            ("example.com\r\nInjected: yes", 443),
        ] {
            assert!(
                ReadinessProbeTarget::parse(host, port).is_err(),
                "accepted invalid probe target {host:?}:{port}",
            );
        }
        assert_eq!(
            ReadinessProbeTarget::parse("probe.example.com", 8443)
                .expect("valid target")
                .hostname(),
            "probe.example.com",
        );
    }
}
