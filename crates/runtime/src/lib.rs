//! Runtime Lifecycle natural-owner capability.
//!
//! Owns bounded runtime composition without becoming the semantic owner of transport,
//! proxy, or cellular readiness. The concrete egress connector consumes one shared
//! Cellular Egress owner. Network-scoped DNS remains a transitional read-only Android
//! adapter; public sockets are ordinary PRODUCT-UID sockets and are steered exclusively
//! by the accepted root policy-routing adapter.

use mish_android_network::AndroidNetworkError;
use mish_cellular::{CellularEgress, CellularNetworkAuthority, CellularNetworkAuthorityError};
use mish_cellular_egress_bridge::{
    CellularOutboundConnector, ConnectTarget, OutboundConnectError, TargetHost,
};
use std::fmt;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const RESOLVER_WORKER_COUNT: usize = 4;
const RESOLVER_QUEUE_CAPACITY: usize = 128;
const MAX_IPV4_CANDIDATES: usize = 8;

/// Configuration rejected before the runtime connector can perform any network effect.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularConnectorConfigError {
    ZeroOperationTimeout,
    ResolverWorkerUnavailable,
}

impl fmt::Display for CellularConnectorConfigError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::ZeroOperationTimeout => "cellular connector operation timeout must be non-zero",
            Self::ResolverWorkerUnavailable => "cellular DNS resolver worker could not start",
        })
    }
}

impl std::error::Error for CellularConnectorConfigError {}

/// Concrete runtime adapter from the private proxy bridge to one shared Cellular Egress
/// owner. It owns no network-selection state, DNS policy/cache, fallback, or second lifecycle.
/// Candidate retry is bounded and remains under one owner authority and one absolute deadline.
#[derive(Clone)]
pub struct AndroidCellularOutboundConnector {
    owner: Arc<Mutex<CellularEgress>>,
    operation_timeout: Duration,
    resolver: Arc<ResolverPool>,
}

impl AndroidCellularOutboundConnector {
    pub fn new(
        owner: Arc<Mutex<CellularEgress>>,
        operation_timeout: Duration,
    ) -> Result<Self, CellularConnectorConfigError> {
        if operation_timeout.is_zero() {
            return Err(CellularConnectorConfigError::ZeroOperationTimeout);
        }
        Ok(Self {
            resolver: Arc::new(ResolverPool::spawn(Arc::clone(&owner))?),
            owner,
            operation_timeout,
        })
    }
}

impl fmt::Debug for AndroidCellularOutboundConnector {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AndroidCellularOutboundConnector")
            .field("operation_timeout", &self.operation_timeout)
            .field("resolver_workers", &RESOLVER_WORKER_COUNT)
            .field("resolver_queue_capacity", &RESOLVER_QUEUE_CAPACITY)
            .finish_non_exhaustive()
    }
}

impl CellularOutboundConnector for AndroidCellularOutboundConnector {
    fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
        let deadline = Instant::now()
            .checked_add(self.operation_timeout)
            .ok_or(OutboundConnectError::Rejected)?;
        connect_host_with(
            &self.owner,
            target.host(),
            target.port(),
            deadline,
            |authority, domain, deadline| self.resolver.resolve(authority, domain, deadline),
            |_authority, address, attempt_deadline| {
                connect_root_policy_socket(address, attempt_deadline)
            },
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ResolverFailure {
    Overloaded,
    Unavailable,
    Lookup(OutboundConnectError),
}

impl ResolverFailure {
    fn into_outbound(self) -> OutboundConnectError {
        match self {
            Self::Overloaded | Self::Unavailable => OutboundConnectError::Unavailable,
            Self::Lookup(error) => error,
        }
    }
}

struct ResolveRequest {
    authority: CellularNetworkAuthority,
    hostname: Box<str>,
    deadline: Instant,
    response: SyncSender<Result<Vec<IpAddr>, ResolverFailure>>,
}

type BlockingResolver = dyn Fn(CellularNetworkAuthority, &str) -> Result<Vec<IpAddr>, OutboundConnectError>
    + Send
    + Sync
    + 'static;

struct ResolverPool {
    requests: SyncSender<ResolveRequest>,
}

impl ResolverPool {
    fn spawn(owner: Arc<Mutex<CellularEgress>>) -> Result<Self, CellularConnectorConfigError> {
        Self::spawn_with(owner, Arc::new(resolve_domain_blocking))
    }

    fn spawn_with(
        owner: Arc<Mutex<CellularEgress>>,
        resolver: Arc<BlockingResolver>,
    ) -> Result<Self, CellularConnectorConfigError> {
        let (requests, receiver) = mpsc::sync_channel(RESOLVER_QUEUE_CAPACITY);
        let receiver = Arc::new(Mutex::new(receiver));

        for worker_index in 0..RESOLVER_WORKER_COUNT {
            let owner = Arc::clone(&owner);
            let receiver = Arc::clone(&receiver);
            let resolver = Arc::clone(&resolver);
            thread::Builder::new()
                .name(format!("mish-cellular-dns-{worker_index}"))
                .spawn(move || resolver_worker_loop(owner, receiver, resolver))
                .map_err(|_| CellularConnectorConfigError::ResolverWorkerUnavailable)?;
        }

        Ok(Self { requests })
    }

    fn resolve(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
        deadline: Instant,
    ) -> Result<Vec<IpAddr>, OutboundConnectError> {
        self.resolve_typed(authority, hostname, deadline)
            .map_err(ResolverFailure::into_outbound)
    }

    fn resolve_typed(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
        deadline: Instant,
    ) -> Result<Vec<IpAddr>, ResolverFailure> {
        let initial_remaining = remaining(deadline).map_err(|_| ResolverFailure::Unavailable)?;
        let (response, result) = mpsc::sync_channel(1);
        let request = ResolveRequest {
            authority,
            hostname: hostname.into(),
            deadline,
            response,
        };
        match self.requests.try_send(request) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) => return Err(ResolverFailure::Overloaded),
            Err(TrySendError::Disconnected(_)) => return Err(ResolverFailure::Unavailable),
        }

        let wait = remaining(deadline)
            .map_err(|_| ResolverFailure::Unavailable)?
            .min(initial_remaining);
        match result.recv_timeout(wait) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => {
                Err(ResolverFailure::Unavailable)
            }
        }
    }
}

fn resolver_worker_loop(
    owner: Arc<Mutex<CellularEgress>>,
    receiver: Arc<Mutex<Receiver<ResolveRequest>>>,
    resolver: Arc<BlockingResolver>,
) {
    loop {
        let request = {
            let receiver = match receiver.lock() {
                Ok(receiver) => receiver,
                Err(_) => return,
            };
            match receiver.recv() {
                Ok(request) => request,
                Err(_) => return,
            }
        };

        if Instant::now() >= request.deadline {
            let _ = request.response.send(Err(ResolverFailure::Unavailable));
            continue;
        }
        if validate_authority(&owner, request.authority).is_err() {
            let _ = request.response.send(Err(ResolverFailure::Unavailable));
            continue;
        }

        let lookup =
            resolver(request.authority, &request.hostname).map_err(ResolverFailure::Lookup);
        let result = if Instant::now() >= request.deadline
            || validate_authority(&owner, request.authority).is_err()
        {
            Err(ResolverFailure::Unavailable)
        } else {
            lookup
        };
        let _ = request.response.send(result);
    }
}

fn resolve_domain_blocking(
    authority: CellularNetworkAuthority,
    domain: &str,
) -> Result<Vec<IpAddr>, OutboundConnectError> {
    let numeric =
        mish_android_network::resolve_host(authority, domain).map_err(map_android_network_error)?;
    bounded_ipv4_resolver_output(numeric)
}

fn bounded_ipv4_resolver_output(numeric: Vec<String>) -> Result<Vec<IpAddr>, OutboundConnectError> {
    let mut addresses = Vec::with_capacity(MAX_IPV4_CANDIDATES);
    for numeric_address in numeric {
        let address = numeric_address
            .parse::<IpAddr>()
            .map_err(|_| OutboundConnectError::Failed)?;
        if !address.is_ipv4() || addresses.contains(&address) {
            continue;
        }
        addresses.push(address);
        if addresses.len() == MAX_IPV4_CANDIDATES {
            break;
        }
    }
    if addresses.is_empty() {
        Err(OutboundConnectError::Failed)
    } else {
        Ok(addresses)
    }
}

/// Ordinary PRODUCT-UID socket. Routing is intentionally not selected here: the root
/// adapter is the single infrastructure mechanism that marks this flow and routes it to
/// the current owner-admitted cellular table. No default-route fallback is introduced.
fn connect_root_policy_socket(
    address: SocketAddr,
    deadline: Instant,
) -> Result<TcpStream, OutboundConnectError> {
    let timeout = remaining(deadline)?;
    TcpStream::connect_timeout(&address, timeout).map_err(|error| {
        if matches!(
            error.kind(),
            std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
        ) {
            OutboundConnectError::Unavailable
        } else {
            OutboundConnectError::Failed
        }
    })
}

/// Private deterministic operation seam. Closures exist only to prove owner sequencing,
/// currentness and bounded candidate retry in hosted tests; production has the DNS +
/// root-policy socket path above.
fn connect_host_with<T>(
    owner: &Arc<Mutex<CellularEgress>>,
    host: &TargetHost,
    port: u16,
    deadline: Instant,
    resolve: impl FnOnce(
        CellularNetworkAuthority,
        &str,
        Instant,
    ) -> Result<Vec<IpAddr>, OutboundConnectError>,
    mut connect: impl FnMut(
        CellularNetworkAuthority,
        SocketAddr,
        Instant,
    ) -> Result<T, OutboundConnectError>,
) -> Result<T, OutboundConnectError> {
    if port == 0 {
        return Err(OutboundConnectError::Rejected);
    }
    ensure_deadline(deadline)?;

    let authority = issue_authority(owner)?;
    let candidates = match host {
        TargetHost::Ipv4(address) => vec![IpAddr::V4(*address)],
        TargetHost::Ipv6(address) => vec![IpAddr::V6(*address)],
        TargetHost::Domain(domain) => {
            ensure_deadline(deadline)?;
            let addresses = resolve(authority, domain, deadline)?;
            ensure_deadline(deadline)?;
            validate_authority(owner, authority)?;
            bounded_ipv4_candidates(addresses)?
        }
    };

    let mut last_error = OutboundConnectError::Failed;
    for (index, address) in candidates.iter().copied().enumerate() {
        ensure_deadline(deadline)?;
        validate_authority(owner, authority)?;
        let attempts_remaining = candidates.len() - index;
        let attempt_deadline = per_candidate_deadline(deadline, attempts_remaining)?;
        match connect(authority, SocketAddr::new(address, port), attempt_deadline) {
            Ok(stream) => {
                ensure_deadline(deadline)?;
                validate_authority(owner, authority)?;
                return Ok(stream);
            }
            Err(error @ OutboundConnectError::Rejected) => return Err(error),
            Err(error) => {
                validate_authority(owner, authority)?;
                last_error = error;
            }
        }
    }

    Err(last_error)
}

fn bounded_ipv4_candidates(addresses: Vec<IpAddr>) -> Result<Vec<IpAddr>, OutboundConnectError> {
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
        Err(OutboundConnectError::Failed)
    } else {
        Ok(candidates)
    }
}

fn per_candidate_deadline(
    operation_deadline: Instant,
    attempts_remaining: usize,
) -> Result<Instant, OutboundConnectError> {
    let remaining_budget = remaining(operation_deadline)?;
    let divisor = u32::try_from(attempts_remaining).map_err(|_| OutboundConnectError::Rejected)?;
    if divisor == 0 {
        return Err(OutboundConnectError::Rejected);
    }
    let slice = remaining_budget / divisor;
    let candidate = Instant::now()
        .checked_add(slice)
        .unwrap_or(operation_deadline);
    Ok(candidate.min(operation_deadline))
}

fn remaining(deadline: Instant) -> Result<Duration, OutboundConnectError> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|duration| !duration.is_zero())
        .ok_or(OutboundConnectError::Unavailable)
}

fn ensure_deadline(deadline: Instant) -> Result<(), OutboundConnectError> {
    remaining(deadline).map(|_| ())
}

fn issue_authority(
    owner: &Arc<Mutex<CellularEgress>>,
) -> Result<CellularNetworkAuthority, OutboundConnectError> {
    owner
        .lock()
        .map_err(|_| OutboundConnectError::Unavailable)?
        .admitted_network_authority()
        .map_err(map_authority_error)
}

fn validate_authority(
    owner: &Arc<Mutex<CellularEgress>>,
    authority: CellularNetworkAuthority,
) -> Result<(), OutboundConnectError> {
    owner
        .lock()
        .map_err(|_| OutboundConnectError::Unavailable)?
        .validate_network_authority(authority)
        .map_err(map_authority_error)
}

fn map_authority_error(error: CellularNetworkAuthorityError) -> OutboundConnectError {
    match error {
        CellularNetworkAuthorityError::NoAdmittedNetwork
        | CellularNetworkAuthorityError::NetworkChanged => OutboundConnectError::Unavailable,
    }
}

fn map_android_network_error(error: AndroidNetworkError) -> OutboundConnectError {
    match error {
        AndroidNetworkError::InvalidHostname => OutboundConnectError::Rejected,
        AndroidNetworkError::UnsupportedPlatform => OutboundConnectError::Unavailable,
        AndroidNetworkError::NativeDnsLookupFailed
        | AndroidNetworkError::NativeDnsNoResults
        | AndroidNetworkError::NativeAddressConversionFailed => OutboundConnectError::Failed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular::{NetworkHandle, NetworkObservation, ObservationSequence};
    use std::cell::Cell;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use std::sync::{Barrier, Condvar};

    fn sequence(raw: u64) -> ObservationSequence {
        ObservationSequence::new(raw).expect("test sequence")
    }

    fn handle(raw: u64) -> NetworkHandle {
        NetworkHandle::new(raw).expect("test network")
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
        Instant::now() + Duration::from_secs(5)
    }

    #[test]
    fn zero_timeout_is_rejected_at_composition_boundary() {
        let result = AndroidCellularOutboundConnector::new(admitted_owner(), Duration::ZERO);
        assert!(matches!(
            result,
            Err(CellularConnectorConfigError::ZeroOperationTimeout)
        ));
    }

    #[test]
    fn expired_deadline_prevents_all_platform_effects() {
        let owner = admitted_owner();
        let resolved = Cell::new(false);
        let connected = Cell::new(false);
        let expired = Instant::now() - Duration::from_millis(1);

        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("example.invalid".into()),
            443,
            expired,
            |_, _, _| {
                resolved.set(true);
                Ok(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)])
            },
            |_, _, _| {
                connected.set(true);
                Ok(())
            },
        );

        assert_eq!(result, Err(OutboundConnectError::Unavailable));
        assert!(!resolved.get());
        assert!(!connected.get());
    }

    #[test]
    fn unavailable_owner_prevents_all_platform_effects() {
        let owner = Arc::new(Mutex::new(CellularEgress::new()));
        let resolved = Cell::new(false);
        let connected = Cell::new(false);

        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("example.invalid".into()),
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

        assert_eq!(result, Err(OutboundConnectError::Unavailable));
        assert!(!resolved.get());
        assert!(!connected.get());
    }

    #[test]
    fn numeric_targets_skip_dns_and_connect_once() {
        for host in [
            TargetHost::Ipv4(Ipv4Addr::new(203, 0, 113, 10)),
            TargetHost::Ipv6(Ipv6Addr::LOCALHOST),
        ] {
            let owner = admitted_owner();
            let calls = Cell::new(0_u8);
            let observed = Cell::new(None::<SocketAddr>);
            let operation_deadline = deadline();

            let result = connect_host_with(
                &owner,
                &host,
                8443,
                operation_deadline,
                |_, _, _| -> Result<Vec<IpAddr>, OutboundConnectError> {
                    panic!("numeric target must never invoke DNS")
                },
                |_, address, attempt_deadline| {
                    calls.set(calls.get() + 1);
                    observed.set(Some(address));
                    assert!(attempt_deadline <= operation_deadline);
                    Ok(())
                },
            );

            assert_eq!(result, Ok(()));
            assert_eq!(calls.get(), 1);
            assert_eq!(observed.get().expect("connect address").port(), 8443);
        }
    }

    #[test]
    fn domain_dns_and_connect_share_authority_and_operation_deadline() {
        let owner = admitted_owner();
        let dns_authority = Cell::new(None::<CellularNetworkAuthority>);
        let connect_authority = Cell::new(None::<CellularNetworkAuthority>);
        let operation_deadline = deadline();
        let first = IpAddr::V4(Ipv4Addr::new(203, 0, 113, 20));

        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("example.invalid".into()),
            443,
            operation_deadline,
            |authority, domain, received_deadline| {
                assert_eq!(domain, "example.invalid");
                assert_eq!(received_deadline, operation_deadline);
                dns_authority.set(Some(authority));
                Ok(vec![first])
            },
            |authority, address, attempt_deadline| {
                assert!(attempt_deadline <= operation_deadline);
                connect_authority.set(Some(authority));
                assert_eq!(address, SocketAddr::new(first, 443));
                Ok(())
            },
        );

        assert_eq!(result, Ok(()));
        assert_eq!(dns_authority.get(), connect_authority.get());
    }

    #[test]
    fn domain_ignores_ipv6_and_retries_bounded_ipv4_candidates_under_one_deadline() {
        let owner = admitted_owner();
        let operation_deadline = deadline();
        let first = Ipv4Addr::new(203, 0, 113, 20);
        let second = Ipv4Addr::new(203, 0, 113, 21);
        let attempts = Cell::new(0_usize);
        let first_attempt_deadline = Cell::new(None::<Instant>);

        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("example.invalid".into()),
            443,
            operation_deadline,
            |_, _, _| {
                Ok(vec![
                    IpAddr::V6(Ipv6Addr::LOCALHOST),
                    IpAddr::V4(first),
                    IpAddr::V4(first),
                    IpAddr::V4(second),
                ])
            },
            |_, address, attempt_deadline| {
                let call = attempts.get();
                attempts.set(call + 1);
                assert!(address.ip().is_ipv4());
                assert!(attempt_deadline <= operation_deadline);
                if call == 0 {
                    first_attempt_deadline.set(Some(attempt_deadline));
                    assert_eq!(address.ip(), IpAddr::V4(first));
                    Err(OutboundConnectError::Failed)
                } else {
                    assert_eq!(address.ip(), IpAddr::V4(second));
                    Ok(())
                }
            },
        );

        assert_eq!(result, Ok(()));
        assert_eq!(attempts.get(), 2);
        assert!(
            first_attempt_deadline
                .get()
                .expect("first attempt deadline")
                < operation_deadline
        );
    }

    #[test]
    fn authority_loss_after_dns_prevents_socket_connect() {
        let owner = admitted_owner();
        let owner_during_dns = Arc::clone(&owner);
        let connected = Cell::new(false);

        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("example.invalid".into()),
            443,
            deadline(),
            move |_, _, _| {
                owner_during_dns
                    .lock()
                    .expect("owner mutex")
                    .lost(sequence(2), handle(42));
                Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 20))])
            },
            |_, _, _| {
                connected.set(true);
                Ok(())
            },
        );

        assert_eq!(result, Err(OutboundConnectError::Unavailable));
        assert!(!connected.get());
    }

    #[test]
    fn authority_loss_between_failed_candidates_aborts_retry() {
        let owner = admitted_owner();
        let owner_during_connect = Arc::clone(&owner);
        let attempts = Cell::new(0_u8);

        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("example.invalid".into()),
            443,
            deadline(),
            |_, _, _| {
                Ok(vec![
                    IpAddr::V4(Ipv4Addr::new(203, 0, 113, 20)),
                    IpAddr::V4(Ipv4Addr::new(203, 0, 113, 21)),
                ])
            },
            |_, _, _| {
                let current = attempts.get();
                attempts.set(current + 1);
                if current == 0 {
                    owner_during_connect
                        .lock()
                        .expect("owner mutex")
                        .lost(sequence(2), handle(42));
                    Err(OutboundConnectError::Failed)
                } else {
                    Ok(())
                }
            },
        );

        assert_eq!(result, Err(OutboundConnectError::Unavailable));
        assert_eq!(attempts.get(), 1);
    }

    #[test]
    fn authority_loss_during_connect_rejects_apparent_success() {
        let owner = admitted_owner();
        let owner_during_connect = Arc::clone(&owner);

        let result = connect_host_with(
            &owner,
            &TargetHost::Ipv4(Ipv4Addr::new(203, 0, 113, 20)),
            443,
            deadline(),
            |_, _, _| -> Result<Vec<IpAddr>, OutboundConnectError> {
                panic!("numeric target must never invoke DNS")
            },
            move |_, _, _| {
                owner_during_connect
                    .lock()
                    .expect("owner mutex")
                    .lost(sequence(2), handle(42));
                Ok(())
            },
        );

        assert_eq!(result, Err(OutboundConnectError::Unavailable));
    }

    #[test]
    fn resolver_output_is_ipv4_only_deduplicated_and_bounded() {
        let mut numeric = vec!["::1".to_owned(), "203.0.113.1".to_owned()];
        numeric.push("203.0.113.1".to_owned());
        for suffix in 2..=20 {
            numeric.push(format!("203.0.113.{suffix}"));
        }

        let addresses = bounded_ipv4_resolver_output(numeric).expect("bounded resolver output");
        assert_eq!(addresses.len(), MAX_IPV4_CANDIDATES);
        assert!(addresses.iter().all(IpAddr::is_ipv4));
        assert_eq!(addresses[0], IpAddr::V4(Ipv4Addr::new(203, 0, 113, 1)));
        assert_eq!(addresses[1], IpAddr::V4(Ipv4Addr::new(203, 0, 113, 2)));
    }

    #[test]
    fn resolver_pool_handles_10_50_100_parallel_requests_with_bounded_workers() {
        let owner = admitted_owner();
        let authority = issue_authority(&owner).expect("admitted authority");
        let active = Arc::new(AtomicUsize::new(0));
        let maximum = Arc::new(AtomicUsize::new(0));
        let active_for_resolver = Arc::clone(&active);
        let maximum_for_resolver = Arc::clone(&maximum);
        let resolver: Arc<BlockingResolver> = Arc::new(move |_, _| {
            let now = active_for_resolver.fetch_add(1, Ordering::SeqCst) + 1;
            maximum_for_resolver.fetch_max(now, Ordering::SeqCst);
            thread::sleep(Duration::from_millis(2));
            active_for_resolver.fetch_sub(1, Ordering::SeqCst);
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        });
        let pool = Arc::new(
            ResolverPool::spawn_with(Arc::clone(&owner), resolver).expect("resolver pool"),
        );

        for parallelism in [10_usize, 50, 100] {
            let barrier = Arc::new(Barrier::new(parallelism + 1));
            let mut handles = Vec::with_capacity(parallelism);
            for request_index in 0..parallelism {
                let barrier = Arc::clone(&barrier);
                let pool = Arc::clone(&pool);
                handles.push(thread::spawn(move || {
                    barrier.wait();
                    pool.resolve(
                        authority,
                        &format!("stress-{request_index}.invalid"),
                        Instant::now() + Duration::from_secs(5),
                    )
                }));
            }
            barrier.wait();
            for handle in handles {
                assert_eq!(
                    handle.join().expect("resolver caller"),
                    Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
                );
            }
        }

        assert_eq!(active.load(Ordering::SeqCst), 0);
        assert!(maximum.load(Ordering::SeqCst) > 1);
        assert!(maximum.load(Ordering::SeqCst) <= RESOLVER_WORKER_COUNT);
    }

    #[test]
    fn resolver_queue_overload_is_typed_and_fails_closed() {
        let owner = admitted_owner();
        let authority = issue_authority(&owner).expect("admitted authority");
        let active = Arc::new(AtomicUsize::new(0));
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let active_for_resolver = Arc::clone(&active);
        let release_for_resolver = Arc::clone(&release);
        let resolver: Arc<BlockingResolver> = Arc::new(move |_, _| {
            active_for_resolver.fetch_add(1, Ordering::SeqCst);
            let (lock, condition) = &*release_for_resolver;
            let mut released = lock.lock().expect("release mutex");
            while !*released {
                released = condition.wait(released).expect("release wait");
            }
            active_for_resolver.fetch_sub(1, Ordering::SeqCst);
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        });
        let pool = Arc::new(
            ResolverPool::spawn_with(Arc::clone(&owner), resolver).expect("resolver pool"),
        );

        let mut blockers = Vec::with_capacity(RESOLVER_WORKER_COUNT);
        for worker_index in 0..RESOLVER_WORKER_COUNT {
            let pool = Arc::clone(&pool);
            blockers.push(thread::spawn(move || {
                pool.resolve_typed(
                    authority,
                    &format!("blocked-{worker_index}.invalid"),
                    Instant::now() + Duration::from_secs(5),
                )
            }));
        }

        let active_deadline = Instant::now() + Duration::from_secs(1);
        while active.load(Ordering::SeqCst) < RESOLVER_WORKER_COUNT {
            assert!(
                Instant::now() < active_deadline,
                "resolver workers did not become active"
            );
            thread::yield_now();
        }

        for queued_index in 0..RESOLVER_QUEUE_CAPACITY {
            let (response, _result) = mpsc::sync_channel(1);
            pool.requests
                .try_send(ResolveRequest {
                    authority,
                    hostname: format!("queued-{queued_index}.invalid").into(),
                    deadline: Instant::now() + Duration::from_secs(5),
                    response,
                })
                .expect("queue slot");
        }

        assert_eq!(
            pool.resolve_typed(
                authority,
                "overload.invalid",
                Instant::now() + Duration::from_secs(1),
            ),
            Err(ResolverFailure::Overloaded)
        );

        let (lock, condition) = &*release;
        *lock.lock().expect("release mutex") = true;
        condition.notify_all();
        for blocker in blockers {
            assert!(blocker.join().expect("blocking resolver caller").is_ok());
        }
    }

    #[test]
    fn resolver_worker_revalidates_authority_after_queue_delay_before_dns_effect() {
        let owner = admitted_owner();
        let authority = issue_authority(&owner).expect("admitted authority");
        let invoked = Arc::new(AtomicBool::new(false));
        let invoked_for_resolver = Arc::clone(&invoked);
        let resolver: Arc<BlockingResolver> = Arc::new(move |_, _| {
            invoked_for_resolver.store(true, Ordering::SeqCst);
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        });
        let pool = ResolverPool::spawn_with(Arc::clone(&owner), resolver).expect("resolver pool");

        owner
            .lock()
            .expect("owner mutex")
            .lost(sequence(2), handle(42));
        assert_eq!(
            pool.resolve_typed(
                authority,
                "stale.invalid",
                Instant::now() + Duration::from_secs(1),
            ),
            Err(ResolverFailure::Unavailable)
        );
        assert!(!invoked.load(Ordering::SeqCst));
    }

    #[test]
    fn zero_port_is_rejected_before_platform_access() {
        let owner = admitted_owner();
        let connected = Cell::new(false);

        let result = connect_host_with(
            &owner,
            &TargetHost::Ipv4(Ipv4Addr::LOCALHOST),
            0,
            deadline(),
            |_, _, _| -> Result<Vec<IpAddr>, OutboundConnectError> {
                panic!("zero port must fail before DNS")
            },
            |_, _, _| {
                connected.set(true);
                Ok(())
            },
        );

        assert_eq!(result, Err(OutboundConnectError::Rejected));
        assert!(!connected.get());
    }
}
