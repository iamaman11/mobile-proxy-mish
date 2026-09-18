//! Generation-bound public egress IP observation for the existing Cellular Egress owner.
//!
//! This module does not create a second network owner or socket path. Preparation acquires one
//! current owner authority, uses the shared owner-bound Android DNS seam, and returns a bounded
//! one-shot observation ticket. Android performs only the ordinary PRODUCT-UID TLS/HTTPS effect;
//! completion is accepted only if the original owner generation is still current.

use crate::{
    CellularDnsPrepareError, CellularDnsResolver, issue_authority, resolve_current_domain,
    validate_authority,
};
use mish_cellular::{CellularEgress, CellularNetworkAuthority};
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const PUBLIC_IP_ENDPOINT_HOST: &str = "checkip.amazonaws.com";
pub const PUBLIC_IP_ENDPOINT_PORT: u16 = 443;
pub const PUBLIC_IP_ENDPOINT_PATH: &str = "/";
pub const PUBLIC_IP_RESPONSE_BODY_MAX_BYTES: usize = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PublicIpProbeEffectFailure {
    SocketConnect,
    SocketTimeout,
    TlsHandshake,
    TlsHostname,
    HttpStatus,
    ResponseTooLarge,
    ResponseMalformed,
    Io,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PublicIpProbeFailure {
    NoCurrentCellular,
    RootPolicyUnavailable,
    DnsUnavailable,
    DeadlineExceeded,
    StaleGeneration,
    InvalidResponse,
    SocketConnect,
    SocketTimeout,
    TlsHandshake,
    TlsHostname,
    HttpStatus,
    ResponseTooLarge,
    ResponseMalformed,
    Io,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PublicEgressIpObservation {
    address: IpAddr,
    generation: u64,
}

impl PublicEgressIpObservation {
    pub const fn address(self) -> IpAddr {
        self.address
    }

    pub const fn generation(self) -> u64 {
        self.generation
    }
}

pub struct PreparedPublicIpProbe {
    owner: Arc<Mutex<CellularEgress>>,
    authority: CellularNetworkAuthority,
    addresses: Vec<IpAddr>,
    deadline: Instant,
}

impl PreparedPublicIpProbe {
    pub(crate) fn prepare(
        owner: Arc<Mutex<CellularEgress>>,
        resolver: Arc<dyn CellularDnsResolver>,
        timeout: Duration,
    ) -> Result<Self, PublicIpProbeFailure> {
        let deadline = Instant::now()
            .checked_add(timeout)
            .ok_or(PublicIpProbeFailure::DeadlineExceeded)?;
        let authority =
            issue_authority(&owner).map_err(|_| PublicIpProbeFailure::NoCurrentCellular)?;
        let prepared = resolve_current_domain(
            &owner,
            authority,
            PUBLIC_IP_ENDPOINT_HOST,
            deadline,
            |authority, hostname| resolver.resolve(authority, hostname),
        )
        .map_err(map_dns_failure)?;

        Ok(Self {
            owner,
            authority: prepared.authority,
            addresses: prepared.addresses,
            deadline,
        })
    }

    pub const fn host(&self) -> &'static str {
        PUBLIC_IP_ENDPOINT_HOST
    }

    pub const fn port(&self) -> u16 {
        PUBLIC_IP_ENDPOINT_PORT
    }

    pub const fn path(&self) -> &'static str {
        PUBLIC_IP_ENDPOINT_PATH
    }

    pub const fn response_body_max_bytes(&self) -> usize {
        PUBLIC_IP_RESPONSE_BODY_MAX_BYTES
    }

    pub fn generation(&self) -> u64 {
        self.authority.observation_sequence().raw()
    }

    pub fn numeric_addresses(&self) -> Vec<String> {
        self.addresses.iter().map(ToString::to_string).collect()
    }

    pub fn is_current(&self) -> bool {
        self.ensure_current().is_ok()
    }

    pub fn remaining_timeout_ms(&self) -> Result<u64, PublicIpProbeFailure> {
        self.ensure_current()?;
        let remaining = self
            .deadline
            .checked_duration_since(Instant::now())
            .filter(|duration| !duration.is_zero())
            .ok_or(PublicIpProbeFailure::DeadlineExceeded)?;
        let millis = u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX);
        Ok(millis.max(1))
    }

    pub fn complete(
        &self,
        raw_body: &str,
    ) -> Result<PublicEgressIpObservation, PublicIpProbeFailure> {
        self.ensure_current()?;
        self.ensure_deadline()?;

        if raw_body.len() > PUBLIC_IP_RESPONSE_BODY_MAX_BYTES {
            return Err(PublicIpProbeFailure::ResponseTooLarge);
        }
        let value = raw_body.trim_matches(|value: char| value.is_ascii_whitespace());
        if value.is_empty()
            || value
                .chars()
                .any(|character| character.is_ascii_whitespace())
        {
            return Err(PublicIpProbeFailure::InvalidResponse);
        }
        let address = value
            .parse::<IpAddr>()
            .map_err(|_| PublicIpProbeFailure::InvalidResponse)?;

        // Parsing is an effect boundary too: never publish bytes after an owner change that raced
        // with response processing.
        self.ensure_current()?;
        self.ensure_deadline()?;

        Ok(PublicEgressIpObservation {
            address,
            generation: self.generation(),
        })
    }

    pub fn effect_failed(&self, effect: PublicIpProbeEffectFailure) -> PublicIpProbeFailure {
        if self.ensure_current().is_err() {
            return PublicIpProbeFailure::StaleGeneration;
        }
        if self.ensure_deadline().is_err() {
            return PublicIpProbeFailure::DeadlineExceeded;
        }
        match effect {
            PublicIpProbeEffectFailure::SocketConnect => PublicIpProbeFailure::SocketConnect,
            PublicIpProbeEffectFailure::SocketTimeout => PublicIpProbeFailure::SocketTimeout,
            PublicIpProbeEffectFailure::TlsHandshake => PublicIpProbeFailure::TlsHandshake,
            PublicIpProbeEffectFailure::TlsHostname => PublicIpProbeFailure::TlsHostname,
            PublicIpProbeEffectFailure::HttpStatus => PublicIpProbeFailure::HttpStatus,
            PublicIpProbeEffectFailure::ResponseTooLarge => PublicIpProbeFailure::ResponseTooLarge,
            PublicIpProbeEffectFailure::ResponseMalformed => {
                PublicIpProbeFailure::ResponseMalformed
            }
            PublicIpProbeEffectFailure::Io => PublicIpProbeFailure::Io,
        }
    }

    fn ensure_current(&self) -> Result<(), PublicIpProbeFailure> {
        validate_authority(&self.owner, self.authority)
            .map_err(|_| PublicIpProbeFailure::StaleGeneration)
    }

    fn ensure_deadline(&self) -> Result<(), PublicIpProbeFailure> {
        self.deadline
            .checked_duration_since(Instant::now())
            .filter(|duration| !duration.is_zero())
            .map(|_| ())
            .ok_or(PublicIpProbeFailure::DeadlineExceeded)
    }
}

fn map_dns_failure(error: CellularDnsPrepareError) -> PublicIpProbeFailure {
    match error {
        CellularDnsPrepareError::AuthorityUnavailable => PublicIpProbeFailure::NoCurrentCellular,
        CellularDnsPrepareError::ResolverFailed | CellularDnsPrepareError::UnusableResult => {
            PublicIpProbeFailure::DnsUnavailable
        }
        CellularDnsPrepareError::DeadlineExceeded => PublicIpProbeFailure::DeadlineExceeded,
        CellularDnsPrepareError::StaleAuthority => PublicIpProbeFailure::StaleGeneration,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular::{NetworkHandle, NetworkObservation, ObservationSequence};
    use mish_proxy::ProxyOutboundConnectError;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::thread;

    fn sequence(raw: u64) -> ObservationSequence {
        ObservationSequence::new(raw).expect("sequence")
    }

    fn handle(raw: u64) -> NetworkHandle {
        NetworkHandle::new(raw).expect("handle")
    }

    fn admitted_owner() -> Arc<Mutex<CellularEgress>> {
        let mut owner = CellularEgress::new();
        owner.observe(NetworkObservation::new(
            sequence(1),
            handle(42),
            true,
            true,
            true,
            true,
        ));
        Arc::new(Mutex::new(owner))
    }

    fn resolver() -> Arc<dyn CellularDnsResolver> {
        Arc::new(
            |_authority: CellularNetworkAuthority,
             _hostname: &str|
             -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
                Ok(vec![
                    IpAddr::V6(Ipv6Addr::LOCALHOST),
                    IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9)),
                ])
            },
        )
    }

    #[test]
    fn prepare_without_current_owner_fails_before_dns() {
        let owner = Arc::new(Mutex::new(CellularEgress::new()));
        let invoked = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let effect_invoked = Arc::clone(&invoked);
        let resolver: Arc<dyn CellularDnsResolver> = Arc::new(
            move |_authority: CellularNetworkAuthority,
                  _hostname: &str|
                  -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
                effect_invoked.store(true, std::sync::atomic::Ordering::SeqCst);
                Ok(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)])
            },
        );

        assert!(matches!(
            PreparedPublicIpProbe::prepare(owner, resolver, Duration::from_secs(2)),
            Err(PublicIpProbeFailure::NoCurrentCellular)
        ));
        assert!(!invoked.load(std::sync::atomic::Ordering::SeqCst));
    }

    #[test]
    fn resolver_failure_is_typed_without_fallback() {
        let resolver: Arc<dyn CellularDnsResolver> = Arc::new(
            |_authority: CellularNetworkAuthority,
             _hostname: &str|
             -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
                Err(ProxyOutboundConnectError::Failed)
            },
        );
        assert!(matches!(
            PreparedPublicIpProbe::prepare(admitted_owner(), resolver, Duration::from_secs(2)),
            Err(PublicIpProbeFailure::DnsUnavailable)
        ));
    }

    #[test]
    fn prepare_uses_current_owner_generation_and_ipv4_dns_candidates() {
        let probe =
            PreparedPublicIpProbe::prepare(admitted_owner(), resolver(), Duration::from_secs(2))
                .expect("probe");
        assert_eq!(probe.generation(), 1);
        assert_eq!(probe.host(), PUBLIC_IP_ENDPOINT_HOST);
        assert_eq!(probe.port(), 443);
        assert_eq!(probe.path(), "/");
        assert_eq!(probe.numeric_addresses(), vec!["203.0.113.9"]);
    }

    #[test]
    fn strict_ip_parser_accepts_ipv4_and_ipv6_only() {
        let probe =
            PreparedPublicIpProbe::prepare(admitted_owner(), resolver(), Duration::from_secs(2))
                .expect("probe");
        assert_eq!(
            probe.complete("198.51.100.42\r\n").expect("IPv4").address(),
            "198.51.100.42".parse::<IpAddr>().expect("IPv4")
        );
        assert_eq!(
            probe.complete("2001:db8::42\n").expect("IPv6").address(),
            "2001:db8::42".parse::<IpAddr>().expect("IPv6")
        );
        assert_eq!(
            probe.complete("198.51.100.42 extra"),
            Err(PublicIpProbeFailure::InvalidResponse)
        );
        assert_eq!(
            probe.complete("not-an-ip"),
            Err(PublicIpProbeFailure::InvalidResponse)
        );
    }

    #[test]
    fn stale_completion_is_rejected_even_with_valid_ip_bytes() {
        let owner = admitted_owner();
        let probe = PreparedPublicIpProbe::prepare(
            Arc::clone(&owner),
            resolver(),
            Duration::from_secs(2),
        )
        .expect("probe");
        owner
            .lock()
            .expect("owner")
            .lost(sequence(2), handle(42));

        assert_eq!(
            probe.complete("198.51.100.42"),
            Err(PublicIpProbeFailure::StaleGeneration)
        );
        assert_eq!(
            probe.effect_failed(PublicIpProbeEffectFailure::Io),
            PublicIpProbeFailure::StaleGeneration
        );
    }

    #[test]
    fn absolute_deadline_rejects_late_completion() {
        let probe = PreparedPublicIpProbe::prepare(
            admitted_owner(),
            resolver(),
            Duration::from_millis(1),
        )
        .expect("probe");
        thread::sleep(Duration::from_millis(5));
        assert_eq!(
            probe.complete("198.51.100.42"),
            Err(PublicIpProbeFailure::DeadlineExceeded)
        );
    }

    #[test]
    fn oversized_body_is_rejected_without_publishing_raw_bytes() {
        let probe =
            PreparedPublicIpProbe::prepare(admitted_owner(), resolver(), Duration::from_secs(2))
                .expect("probe");
        let oversized = "1".repeat(PUBLIC_IP_RESPONSE_BODY_MAX_BYTES + 1);
        assert_eq!(
            probe.complete(&oversized),
            Err(PublicIpProbeFailure::ResponseTooLarge)
        );
    }
}
