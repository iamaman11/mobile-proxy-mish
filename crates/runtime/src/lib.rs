//! Direct vendor-neutral connector from Proxy Serving to Cellular Egress.
//!
//! Android DNS mechanics are injected through `CellularDnsResolver`; this module owns no Android,
//! root-shell or lifecycle policy. Each operation acquires one current Cellular Egress authority,
//! resolves domain targets only through the injected exact-network DNS port, validates authority
//! again after every external effect, and creates an ordinary PRODUCT-UID socket whose routing is
//! enforced by the existing root-policy adapter.

use mish_cellular::{CellularEgress, CellularNetworkAuthority, CellularNetworkAuthorityError};
use mish_proxy::{
    ProxyConnectTarget, ProxyOutboundConnectError, ProxyOutboundConnector, ProxyTargetHost,
};
use std::fmt;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const MAX_IPV4_CANDIDATES: usize = 8;

pub trait CellularDnsResolver: Send + Sync + 'static {
    fn resolve(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
    ) -> Result<Vec<IpAddr>, ProxyOutboundConnectError>;
}

impl<F> CellularDnsResolver for F
where
    F: Fn(CellularNetworkAuthority, &str) -> Result<Vec<IpAddr>, ProxyOutboundConnectError>
        + Send
        + Sync
        + 'static,
{
    fn resolve(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
    ) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
        self(authority, hostname)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularConnectorConfigError {
    ZeroOperationTimeout,
}

impl fmt::Display for CellularConnectorConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::ZeroOperationTimeout => "cellular connector operation timeout must be non-zero",
        })
    }
}
impl std::error::Error for CellularConnectorConfigError {}

/// Blocking setup connector. PRODUCT executes this only inside the runtime owner's bounded
/// `spawn_blocking` seam; no second resolver pool or thread-per-session scheduler exists here.
#[derive(Clone)]
pub struct CellularOutboundRuntimeConnector {
    owner: Arc<Mutex<CellularEgress>>,
    operation_timeout: Duration,
    resolver: Arc<dyn CellularDnsResolver>,
}

impl CellularOutboundRuntimeConnector {
    pub fn new(
        owner: Arc<Mutex<CellularEgress>>,
        operation_timeout: Duration,
        resolver: Arc<dyn CellularDnsResolver>,
    ) -> Result<Self, CellularConnectorConfigError> {
        if operation_timeout.is_zero() {
            return Err(CellularConnectorConfigError::ZeroOperationTimeout);
        }
        Ok(Self { owner, operation_timeout, resolver })
    }
}

impl fmt::Debug for CellularOutboundRuntimeConnector {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CellularOutboundRuntimeConnector")
            .field("operation_timeout", &self.operation_timeout)
            .finish_non_exhaustive()
    }
}

impl ProxyOutboundConnector for CellularOutboundRuntimeConnector {
    fn connect(&self, target: &ProxyConnectTarget) -> Result<TcpStream, ProxyOutboundConnectError> {
        let deadline = Instant::now()
            .checked_add(self.operation_timeout)
            .ok_or(ProxyOutboundConnectError::Rejected)?;
        connect_host_with(
            &self.owner,
            target.host(),
            target.port(),
            deadline,
            |authority, domain, _deadline| self.resolver.resolve(authority, domain),
            |_authority, address, attempt_deadline| connect_root_policy_socket(address, attempt_deadline),
        )
    }
}

fn connect_root_policy_socket(
    address: SocketAddr,
    deadline: Instant,
) -> Result<TcpStream, ProxyOutboundConnectError> {
    let timeout = remaining(deadline)?;
    TcpStream::connect_timeout(&address, timeout).map_err(|error| {
        if matches!(error.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock) {
            ProxyOutboundConnectError::Unavailable
        } else {
            ProxyOutboundConnectError::Failed
        }
    })
}

fn connect_host_with<T>(
    owner: &Arc<Mutex<CellularEgress>>,
    host: &ProxyTargetHost,
    port: u16,
    deadline: Instant,
    resolve: impl FnOnce(CellularNetworkAuthority, &str, Instant) -> Result<Vec<IpAddr>, ProxyOutboundConnectError>,
    mut connect: impl FnMut(CellularNetworkAuthority, SocketAddr, Instant) -> Result<T, ProxyOutboundConnectError>,
) -> Result<T, ProxyOutboundConnectError> {
    if port == 0 { return Err(ProxyOutboundConnectError::Rejected); }
    ensure_deadline(deadline)?;
    let authority = issue_authority(owner)?;
    let candidates = match host {
        ProxyTargetHost::Ipv4(address) => vec![IpAddr::V4(*address)],
        ProxyTargetHost::Ipv6(_) => return Err(ProxyOutboundConnectError::Rejected),
        ProxyTargetHost::Domain(domain) => {
            ensure_deadline(deadline)?;
            let addresses = resolve(authority, domain, deadline)?;
            ensure_deadline(deadline)?;
            validate_authority(owner, authority)?;
            bounded_ipv4_candidates(addresses)?
        }
    };

    let mut last_error = ProxyOutboundConnectError::Failed;
    for (index, address) in candidates.iter().copied().enumerate() {
        ensure_deadline(deadline)?;
        validate_authority(owner, authority)?;
        let attempt_deadline = per_candidate_deadline(deadline, candidates.len() - index)?;
        match connect(authority, SocketAddr::new(address, port), attempt_deadline) {
            Ok(stream) => {
                ensure_deadline(deadline)?;
                validate_authority(owner, authority)?;
                return Ok(stream);
            }
            Err(error @ ProxyOutboundConnectError::Rejected) => return Err(error),
            Err(error) => {
                validate_authority(owner, authority)?;
                last_error = error;
            }
        }
    }
    Err(last_error)
}

fn bounded_ipv4_candidates(addresses: Vec<IpAddr>) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
    let mut candidates = Vec::with_capacity(MAX_IPV4_CANDIDATES);
    for address in addresses {
        if !address.is_ipv4() || candidates.contains(&address) { continue; }
        candidates.push(address);
        if candidates.len() == MAX_IPV4_CANDIDATES { break; }
    }
    if candidates.is_empty() { Err(ProxyOutboundConnectError::Failed) } else { Ok(candidates) }
}

fn per_candidate_deadline(
    operation_deadline: Instant,
    attempts_remaining: usize,
) -> Result<Instant, ProxyOutboundConnectError> {
    let remaining_budget = remaining(operation_deadline)?;
    let divisor = u32::try_from(attempts_remaining).map_err(|_| ProxyOutboundConnectError::Rejected)?;
    if divisor == 0 { return Err(ProxyOutboundConnectError::Rejected); }
    let slice = remaining_budget / divisor;
    let candidate = Instant::now().checked_add(slice).unwrap_or(operation_deadline);
    Ok(candidate.min(operation_deadline))
}

fn remaining(deadline: Instant) -> Result<Duration, ProxyOutboundConnectError> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or(ProxyOutboundConnectError::Unavailable)
}
fn ensure_deadline(deadline: Instant) -> Result<(), ProxyOutboundConnectError> { remaining(deadline).map(|_| ()) }

fn issue_authority(owner: &Arc<Mutex<CellularEgress>>) -> Result<CellularNetworkAuthority, ProxyOutboundConnectError> {
    owner.lock().map_err(|_| ProxyOutboundConnectError::Unavailable)?
        .admitted_network_authority().map_err(map_authority_error)
}
fn validate_authority(
    owner: &Arc<Mutex<CellularEgress>>,
    authority: CellularNetworkAuthority,
) -> Result<(), ProxyOutboundConnectError> {
    owner.lock().map_err(|_| ProxyOutboundConnectError::Unavailable)?
        .validate_network_authority(authority).map_err(map_authority_error)
}
fn map_authority_error(error: CellularNetworkAuthorityError) -> ProxyOutboundConnectError {
    match error {
        CellularNetworkAuthorityError::NoAdmittedNetwork | CellularNetworkAuthorityError::NetworkChanged => {
            ProxyOutboundConnectError::Unavailable
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular::{NetworkHandle, NetworkObservation, ObservationSequence};
    use std::cell::Cell;
    use std::net::{Ipv4Addr, Ipv6Addr};

    fn sequence(raw: u64) -> ObservationSequence { ObservationSequence::new(raw).expect("sequence") }
    fn handle(raw: u64) -> NetworkHandle { NetworkHandle::new(raw).expect("network") }
    fn admitted_owner() -> Arc<Mutex<CellularEgress>> {
        let mut owner = CellularEgress::new();
        owner.observe(NetworkObservation::new(sequence(1), handle(42), true, true, true, true));
        Arc::new(Mutex::new(owner))
    }
    fn deadline() -> Instant { Instant::now() + Duration::from_secs(2) }

    #[test]
    fn zero_timeout_is_rejected() {
        let result = CellularOutboundRuntimeConnector::new(
            admitted_owner(), Duration::ZERO,
            Arc::new(|_, _| -> Result<Vec<IpAddr>, ProxyOutboundConnectError> { Ok(Vec::new()) }),
        );
        assert!(matches!(result, Err(CellularConnectorConfigError::ZeroOperationTimeout)));
    }

    #[test]
    fn no_authority_prevents_dns_and_connect_effects() {
        let owner = Arc::new(Mutex::new(CellularEgress::new()));
        let resolved = Cell::new(false);
        let connected = Cell::new(false);
        let result = connect_host_with(
            &owner, &ProxyTargetHost::Domain("example.invalid".into()), 443, deadline(),
            |_, _, _| { resolved.set(true); Ok(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)]) },
            |_, _, _| { connected.set(true); Ok(()) },
        );
        assert_eq!(result, Err(ProxyOutboundConnectError::Unavailable));
        assert!(!resolved.get());
        assert!(!connected.get());
    }

    #[test]
    fn numeric_ipv4_skips_dns() {
        let owner = admitted_owner();
        let connected = Cell::new(false);
        let result = connect_host_with(
            &owner, &ProxyTargetHost::Ipv4(Ipv4Addr::new(203,0,113,10)), 443, deadline(),
            |_, _, _| -> Result<Vec<IpAddr>, ProxyOutboundConnectError> { panic!("numeric target must not invoke DNS") },
            |_, _, _| { connected.set(true); Ok(()) },
        );
        assert_eq!(result, Ok(()));
        assert!(connected.get());
    }

    #[test]
    fn ipv6_literal_fails_closed_without_dns() {
        let owner = admitted_owner();
        let resolved = Cell::new(false);
        let result = connect_host_with(
            &owner, &ProxyTargetHost::Ipv6(Ipv6Addr::LOCALHOST), 443, deadline(),
            |_, _, _| { resolved.set(true); Ok(Vec::new()) },
            |_, _, _| Ok(()),
        );
        assert_eq!(result, Err(ProxyOutboundConnectError::Rejected));
        assert!(!resolved.get());
    }

    #[test]
    fn authority_change_after_dns_prevents_connect() {
        let owner = admitted_owner();
        let owner_during_dns = Arc::clone(&owner);
        let connected = Cell::new(false);
        let result = connect_host_with(
            &owner, &ProxyTargetHost::Domain("example.invalid".into()), 443, deadline(),
            move |_, _, _| {
                owner_during_dns.lock().expect("owner").lost(sequence(2), handle(42));
                Ok(vec![IpAddr::V4(Ipv4Addr::new(203,0,113,20))])
            },
            |_, _, _| { connected.set(true); Ok(()) },
        );
        assert_eq!(result, Err(ProxyOutboundConnectError::Unavailable));
        assert!(!connected.get());
    }

    #[test]
    fn candidate_list_is_ipv4_only_deduplicated_and_bounded() {
        let mut addresses = vec![
            IpAddr::V6(Ipv6Addr::LOCALHOST),
            IpAddr::V4(Ipv4Addr::new(203,0,113,1)),
            IpAddr::V4(Ipv4Addr::new(203,0,113,1)),
        ];
        for suffix in 2..=20 { addresses.push(IpAddr::V4(Ipv4Addr::new(203,0,113,suffix))); }
        let candidates = bounded_ipv4_candidates(addresses).expect("candidates");
        assert_eq!(candidates.len(), MAX_IPV4_CANDIDATES);
        assert!(candidates.iter().all(IpAddr::is_ipv4));
    }
}
