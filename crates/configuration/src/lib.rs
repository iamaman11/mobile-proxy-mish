//! Desired Configuration natural-owner capability.
//!
//! Owns validated non-secret desired product state. Platform/IaC adapters may materialize or
//! persist an owner-approved value, but must not redefine its syntax or safety constraints.

use std::fmt;
use std::net::Ipv4Addr;

const MIN_MESH_ACCEPTED_PREFIX: u8 = 8;
const DEPLOYMENT_MESH_ACCEPTED_CIDR_RAW: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../config/deployment/mesh-device-cidr.txt"
));

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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DesiredConfigurationError {
    InvalidMeshAcceptedCidr,
    UnsafeMeshAcceptedCidr,
    NonCanonicalMeshAcceptedCidr,
}

impl fmt::Display for DesiredConfigurationError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidMeshAcceptedCidr => "Mesh accepted CIDR must be one exact IPv4 CIDR",
            Self::UnsafeMeshAcceptedCidr => "Mesh accepted CIDR is too broad or unsafe",
            Self::NonCanonicalMeshAcceptedCidr => {
                "Mesh accepted CIDR must use its canonical network address"
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
}
