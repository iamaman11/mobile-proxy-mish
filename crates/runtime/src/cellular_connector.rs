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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const MAX_IPV4_CANDIDATES: usize = 8;
const DNS_SLOW_OBSERVATION_THRESHOLD: Duration = Duration::from_secs(5);

/// Process-wide read-only facts about the synchronous native DNS seam.
///
/// These atomics observe execution only; they do not participate in admission, cancellation,
/// generation selection, retries or result acceptance. Process scope is intentional because a
/// started `spawn_blocking` operation can outlive the runtime generation that started it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CellularDnsDiagnosticSnapshot {
    pub started: u64,
    pub completed: u64,
    pub active: u64,
    pub peak_active: u64,
    pub slow_completions: u64,
    pub failed: u64,
    pub discarded_after_deadline: u64,
    pub completed_after_owner_change: u64,
    pub discarded_stale: u64,
    pub accepted_current: u64,
    pub max_native_elapsed_ms: u64,
    pub last_started_owner_sequence: Option<u64>,
    pub last_completed_start_owner_sequence: Option<u64>,
    pub last_completed_current_owner_sequence: Option<u64>,
}

struct DnsDiagnosticsTracker {
    started: AtomicU64,
    completed: AtomicU64,
    active: AtomicU64,
    peak_active: AtomicU64,
    slow_completions: AtomicU64,
    failed: AtomicU64,
    discarded_after_deadline: AtomicU64,
    completed_after_owner_change: AtomicU64,
    discarded_stale: AtomicU64,
    accepted_current: AtomicU64,
    max_native_elapsed_ms: AtomicU64,
    last_started_owner_sequence: AtomicU64,
    last_completed_start_owner_sequence: AtomicU64,
    last_completed_current_owner_sequence: AtomicU64,
}

impl DnsDiagnosticsTracker {
    const fn new() -> Self {
        Self {
            started: AtomicU64::new(0),
            completed: AtomicU64::new(0),
            active: AtomicU64::new(0),
            peak_active: AtomicU64::new(0),
            slow_completions: AtomicU64::new(0),
            failed: AtomicU64::new(0),
            discarded_after_deadline: AtomicU64::new(0),
            completed_after_owner_change: AtomicU64::new(0),
            discarded_stale: AtomicU64::new(0),
            accepted_current: AtomicU64::new(0),
            max_native_elapsed_ms: AtomicU64::new(0),
            last_started_owner_sequence: AtomicU64::new(0),
            last_completed_start_owner_sequence: AtomicU64::new(0),
            last_completed_current_owner_sequence: AtomicU64::new(0),
        }
    }

    fn start(&self, authority: CellularNetworkAuthority) -> DnsCallObservation<'_> {
        let start_sequence = authority.observation_sequence().raw();
        self.started.fetch_add(1, Ordering::Relaxed);
        self.last_started_owner_sequence
            .store(start_sequence, Ordering::Relaxed);
        let active = self.active.fetch_add(1, Ordering::Relaxed) + 1;
        update_max(&self.peak_active, active);
        DnsCallObservation {
            tracker: self,
            started_at: Instant::now(),
            start_sequence,
            completed: false,
        }
    }

    fn snapshot(&self) -> CellularDnsDiagnosticSnapshot {
        CellularDnsDiagnosticSnapshot {
            started: self.started.load(Ordering::Relaxed),
            completed: self.completed.load(Ordering::Relaxed),
            active: self.active.load(Ordering::Relaxed),
            peak_active: self.peak_active.load(Ordering::Relaxed),
            slow_completions: self.slow_completions.load(Ordering::Relaxed),
            failed: self.failed.load(Ordering::Relaxed),
            discarded_after_deadline: self.discarded_after_deadline.load(Ordering::Relaxed),
            completed_after_owner_change: self
                .completed_after_owner_change
                .load(Ordering::Relaxed),
            discarded_stale: self.discarded_stale.load(Ordering::Relaxed),
            accepted_current: self.accepted_current.load(Ordering::Relaxed),
            max_native_elapsed_ms: self.max_native_elapsed_ms.load(Ordering::Relaxed),
            last_started_owner_sequence: non_zero(
                self.last_started_owner_sequence.load(Ordering::Relaxed),
            ),
            last_completed_start_owner_sequence: non_zero(
                self.last_completed_start_owner_sequence
                    .load(Ordering::Relaxed),
            ),
            last_completed_current_owner_sequence: non_zero(
                self.last_completed_current_owner_sequence
                    .load(Ordering::Relaxed),
            ),
        }
    }
}

struct DnsCallObservation<'a> {
    tracker: &'a DnsDiagnosticsTracker,
    started_at: Instant,
    start_sequence: u64,
    completed: bool,
}

impl DnsCallObservation<'_> {
    fn complete(&mut self, current_owner_sequence: Option<u64>) {
        if self.completed {
            return;
        }
        let elapsed = self.started_at.elapsed();
        let elapsed_ms = u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX);
        self.tracker.active.fetch_sub(1, Ordering::Relaxed);
        self.tracker.completed.fetch_add(1, Ordering::Relaxed);
        self.tracker
            .last_completed_start_owner_sequence
            .store(self.start_sequence, Ordering::Relaxed);
        self.tracker
            .last_completed_current_owner_sequence
            .store(current_owner_sequence.unwrap_or(0), Ordering::Relaxed);
        if current_owner_sequence != Some(self.start_sequence) {
            self.tracker
                .completed_after_owner_change
                .fetch_add(1, Ordering::Relaxed);
        }
        if elapsed >= DNS_SLOW_OBSERVATION_THRESHOLD {
            self.tracker
                .slow_completions
                .fetch_add(1, Ordering::Relaxed);
        }
        update_max(&self.tracker.max_native_elapsed_ms, elapsed_ms);
        self.completed = true;
    }
}

impl Drop for DnsCallObservation<'_> {
    fn drop(&mut self) {
        if !self.completed {
            self.tracker.active.fetch_sub(1, Ordering::Relaxed);
        }
    }
}

fn update_max(target: &AtomicU64, candidate: u64) {
    let mut current = target.load(Ordering::Relaxed);
    while candidate > current {
        match target.compare_exchange_weak(
            current,
            candidate,
            Ordering::Relaxed,
            Ordering::Relaxed,
        ) {
            Ok(_) => break,
            Err(actual) => current = actual,
        }
    }
}

const fn non_zero(value: u64) -> Option<u64> {
    if value == 0 { None } else { Some(value) }
}

static DNS_DIAGNOSTICS: DnsDiagnosticsTracker = DnsDiagnosticsTracker::new();

pub fn cellular_dns_diagnostic_snapshot() -> CellularDnsDiagnosticSnapshot {
    DNS_DIAGNOSTICS.snapshot()
}

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
        Ok(Self {
            owner,
            operation_timeout,
            resolver,
        })
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
            |_authority, address, attempt_deadline| {
                connect_root_policy_socket(address, attempt_deadline)
            },
        )
    }
}

fn connect_root_policy_socket(
    address: SocketAddr,
    deadline: Instant,
) -> Result<TcpStream, ProxyOutboundConnectError> {
    let timeout = remaining(deadline)?;
    TcpStream::connect_timeout(&address, timeout).map_err(|error| {
        if matches!(
            error.kind(),
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
        ) {
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
    resolve: impl FnOnce(
        CellularNetworkAuthority,
        &str,
        Instant,
    ) -> Result<Vec<IpAddr>, ProxyOutboundConnectError>,
    mut connect: impl FnMut(
        CellularNetworkAuthority,
        SocketAddr,
        Instant,
    ) -> Result<T, ProxyOutboundConnectError>,
) -> Result<T, ProxyOutboundConnectError> {
    if port == 0 {
        return Err(ProxyOutboundConnectError::Rejected);
    }
    ensure_deadline(deadline)?;
    let authority = issue_authority(owner)?;
    let candidates = match host {
        ProxyTargetHost::Ipv4(address) => vec![IpAddr::V4(*address)],
        ProxyTargetHost::Ipv6(_) => return Err(ProxyOutboundConnectError::Rejected),
        ProxyTargetHost::Domain(domain) => {
            ensure_deadline(deadline)?;
            let mut observation = DNS_DIAGNOSTICS.start(authority);
            let resolved = resolve(authority, domain, deadline);
            let current_sequence = current_owner_sequence(owner);
            observation.complete(current_sequence);
            let addresses = match resolved {
                Ok(addresses) => addresses,
                Err(error) => {
                    DNS_DIAGNOSTICS.failed.fetch_add(1, Ordering::Relaxed);
                    return Err(error);
                }
            };
            if let Err(error) = ensure_deadline(deadline) {
                DNS_DIAGNOSTICS
                    .discarded_after_deadline
                    .fetch_add(1, Ordering::Relaxed);
                return Err(error);
            }
            if let Err(error) = validate_authority(owner, authority) {
                if current_sequence != Some(authority.observation_sequence().raw()) {
                    DNS_DIAGNOSTICS
                        .discarded_stale
                        .fetch_add(1, Ordering::Relaxed);
                } else {
                    DNS_DIAGNOSTICS.failed.fetch_add(1, Ordering::Relaxed);
                }
                return Err(error);
            }
            let candidates = match bounded_ipv4_candidates(addresses) {
                Ok(candidates) => candidates,
                Err(error) => {
                    DNS_DIAGNOSTICS.failed.fetch_add(1, Ordering::Relaxed);
                    return Err(error);
                }
            };
            DNS_DIAGNOSTICS
                .accepted_current
                .fetch_add(1, Ordering::Relaxed);
            candidates
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

fn bounded_ipv4_candidates(
    addresses: Vec<IpAddr>,
) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
    let mut candidates = Vec::with_capacity(MAX_IPV4_CANDIDATES);
    for address in addresses {
        if !address.is_ipv4() || candidates.contains(&address) {
            continue;
        }
        candidates.push(address);
        if candidates.len() == MAX_IPV4_CANDIDATES {
            break;
        }
    }
    if candidates.is_empty() {
        Err(ProxyOutboundConnectError::Failed)
    } else {
        Ok(candidates)
    }
}

fn per_candidate_deadline(
    operation_deadline: Instant,
    attempts_remaining: usize,
) -> Result<Instant, ProxyOutboundConnectError> {
    let remaining_budget = remaining(operation_deadline)?;
    let divisor =
        u32::try_from(attempts_remaining).map_err(|_| ProxyOutboundConnectError::Rejected)?;
    if divisor == 0 {
        return Err(ProxyOutboundConnectError::Rejected);
    }
    let slice = remaining_budget / divisor;
    let candidate = Instant::now()
        .checked_add(slice)
        .unwrap_or(operation_deadline);
    Ok(candidate.min(operation_deadline))
}

fn remaining(deadline: Instant) -> Result<Duration, ProxyOutboundConnectError> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or(ProxyOutboundConnectError::Unavailable)
}

fn ensure_deadline(deadline: Instant) -> Result<(), ProxyOutboundConnectError> {
    remaining(deadline).map(|_| ())
}

fn issue_authority(
    owner: &Arc<Mutex<CellularEgress>>,
) -> Result<CellularNetworkAuthority, ProxyOutboundConnectError> {
    owner
        .lock()
        .map_err(|_| ProxyOutboundConnectError::Unavailable)?
        .admitted_network_authority()
        .map_err(map_authority_error)
}

fn validate_authority(
    owner: &Arc<Mutex<CellularEgress>>,
    authority: CellularNetworkAuthority,
) -> Result<(), ProxyOutboundConnectError> {
    owner
        .lock()
        .map_err(|_| ProxyOutboundConnectError::Unavailable)?
        .validate_network_authority(authority)
        .map_err(map_authority_error)
}

fn current_owner_sequence(owner: &Arc<Mutex<CellularEgress>>) -> Option<u64> {
    owner
        .lock()
        .ok()?
        .admission()
        .last_sequence()
        .map(|sequence| sequence.raw())
}

fn map_authority_error(error: CellularNetworkAuthorityError) -> ProxyOutboundConnectError {
    match error {
        CellularNetworkAuthorityError::NoAdmittedNetwork
        | CellularNetworkAuthorityError::NetworkChanged => ProxyOutboundConnectError::Unavailable,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular::{NetworkHandle, NetworkObservation, ObservationSequence};
    use std::cell::Cell;
    use std::net::{Ipv4Addr, Ipv6Addr};

    fn sequence(raw: u64) -> ObservationSequence {
        ObservationSequence::new(raw).expect("sequence")
    }
    fn handle(raw: u64) -> NetworkHandle {
        NetworkHandle::new(raw).expect("network")
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
    fn deadline() -> Instant {
        Instant::now() + Duration::from_secs(2)
    }
    fn empty_dns(
        _authority: CellularNetworkAuthority,
        _hostname: &str,
    ) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
        Ok(Vec::new())
    }

    #[test]
    fn zero_timeout_is_rejected() {
        let result = CellularOutboundRuntimeConnector::new(
            admitted_owner(),
            Duration::ZERO,
            Arc::new(empty_dns),
        );
        assert!(matches!(
            result,
            Err(CellularConnectorConfigError::ZeroOperationTimeout)
        ));
    }

    #[test]
    fn no_authority_prevents_dns_and_connect_effects() {
        let owner = Arc::new(Mutex::new(CellularEgress::new()));
        let resolved = Cell::new(false);
        let connected = Cell::new(false);
        let result = connect_host_with(
            &owner,
            &ProxyTargetHost::Domain("example.invalid".into()),
            443,
            deadline(),
            |_, _, _| {
                resolved.set(true);
                Ok(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)])
            },
            |_, _, _| {
                connected.set(true);
                Ok(())
            },
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
            &owner,
            &ProxyTargetHost::Ipv4(Ipv4Addr::new(203, 0, 113, 10)),
            443,
            deadline(),
            |_, _, _| -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
                panic!("numeric target must not invoke DNS")
            },
            |_, _, _| {
                connected.set(true);
                Ok(())
            },
        );
        assert_eq!(result, Ok(()));
        assert!(connected.get());
    }

    #[test]
    fn ipv6_literal_fails_closed_without_dns() {
        let owner = admitted_owner();
        let resolved = Cell::new(false);
        let result = connect_host_with(
            &owner,
            &ProxyTargetHost::Ipv6(Ipv6Addr::LOCALHOST),
            443,
            deadline(),
            |_, _, _| {
                resolved.set(true);
                Ok(Vec::new())
            },
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
            &owner,
            &ProxyTargetHost::Domain("example.invalid".into()),
            443,
            deadline(),
            move |_, _, _| {
                owner_during_dns
                    .lock()
                    .expect("owner")
                    .lost(sequence(2), handle(42));
                Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 20))])
            },
            |_, _, _| {
                connected.set(true);
                Ok(())
            },
        );
        assert_eq!(result, Err(ProxyOutboundConnectError::Unavailable));
        assert!(!connected.get());
    }

    #[test]
    fn candidate_list_is_ipv4_only_deduplicated_and_bounded() {
        let mut addresses = vec![
            IpAddr::V6(Ipv6Addr::LOCALHOST),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 1)),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 1)),
        ];
        for suffix in 2..=20 {
            addresses.push(IpAddr::V4(Ipv4Addr::new(203, 0, 113, suffix)));
        }
        let candidates = bounded_ipv4_candidates(addresses).expect("candidates");
        assert_eq!(candidates.len(), MAX_IPV4_CANDIDATES);
        assert!(candidates.iter().all(IpAddr::is_ipv4));
    }
}
