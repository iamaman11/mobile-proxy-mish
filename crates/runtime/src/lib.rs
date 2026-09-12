//! Vendor-neutral runtime connector from the private proxy bridge to Cellular Egress.
//!
//! Android DNS mechanics are injected through `CellularDnsResolver`; this crate does not depend
//! on Android, Cloudflare, a resolver implementation, or platform network APIs. Public sockets
//! remain ordinary PRODUCT-UID sockets steered by the accepted root policy-routing adapter.

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

/// Narrow consumer-owned DNS port used only after Cellular Egress issued one current authority.
///
/// Implementations perform the platform/vendor DNS effect. They must never resolve through a
/// default network fallback. Runtime validates the owner authority before and after the effect.
pub trait CellularDnsResolver: Send + Sync + 'static {
    fn resolve(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
    ) -> Result<Vec<IpAddr>, OutboundConnectError>;
}

impl<F> CellularDnsResolver for F
where
    F: Fn(CellularNetworkAuthority, &str) -> Result<Vec<IpAddr>, OutboundConnectError>
        + Send
        + Sync
        + 'static,
{
    fn resolve(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
    ) -> Result<Vec<IpAddr>, OutboundConnectError> {
        self(authority, hostname)
    }
}

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

/// Vendor-neutral runtime connector using one shared Cellular Egress owner and one injected DNS
/// effect port. Candidate retry is bounded under one owner authority and one absolute deadline.
#[derive(Clone)]
pub struct CellularOutboundRuntimeConnector {
    owner: Arc<Mutex<CellularEgress>>,
    operation_timeout: Duration,
    resolver: Arc<ResolverPool>,
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
            resolver: Arc::new(ResolverPool::spawn(Arc::clone(&owner), resolver)?),
            owner,
            operation_timeout,
        })
    }
}

impl fmt::Debug for CellularOutboundRuntimeConnector {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("CellularOutboundRuntimeConnector")
            .field("operation_timeout", &self.operation_timeout)
            .field("resolver_workers", &RESOLVER_WORKER_COUNT)
            .field("resolver_queue_capacity", &RESOLVER_QUEUE_CAPACITY)
            .finish_non_exhaustive()
    }
}

impl CellularOutboundConnector for CellularOutboundRuntimeConnector {
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

struct ResolverPool {
    requests: SyncSender<ResolveRequest>,
}

impl ResolverPool {
    fn spawn(
        owner: Arc<Mutex<CellularEgress>>,
        resolver: Arc<dyn CellularDnsResolver>,
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
    resolver: Arc<dyn CellularDnsResolver>,
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

        let lookup = resolver
            .resolve(request.authority, &request.hostname)
            .map_err(ResolverFailure::Lookup);
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

/// Ordinary PRODUCT-UID socket. Routing is intentionally not selected here: the root adapter is
/// the single infrastructure mechanism that marks this flow and routes it to the current
/// owner-admitted cellular table. No default-route fallback is introduced.
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

/// Private deterministic operation seam used to prove owner sequencing/currentness and bounded
/// candidate retry. Production uses the injected DNS port plus root-policy socket path above.
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
        TargetHost::Ipv6(_) => return Err(OutboundConnectError::Rejected),
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

    fn resolver(
        effect: impl Fn(CellularNetworkAuthority, &str) -> Result<Vec<IpAddr>, OutboundConnectError>
        + Send
        + Sync
        + 'static,
    ) -> Arc<dyn CellularDnsResolver> {
        Arc::new(effect)
    }

    #[test]
    fn zero_timeout_is_rejected_at_composition_boundary() {
        let result = CellularOutboundRuntimeConnector::new(
            admitted_owner(),
            Duration::ZERO,
            resolver(|_, _| Ok(Vec::new())),
        );
        assert!(matches!(
            result,
            Err(CellularConnectorConfigError::ZeroOperationTimeout)
        ));
    }

    #[test]
    fn expired_deadline_prevents_all_effects() {
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
    fn no_authority_prevents_dns_and_connect_effects() {
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
                Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 10))])
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
    fn numeric_ipv4_skips_dns_and_connects_once() {
        let owner = admitted_owner();
        let calls = Cell::new(0_u8);
        let result = connect_host_with(
            &owner,
            &TargetHost::Ipv4(Ipv4Addr::new(203, 0, 113, 10)),
            8443,
            deadline(),
            |_, _, _| -> Result<Vec<IpAddr>, OutboundConnectError> {
                panic!("numeric IPv4 target must never invoke DNS")
            },
            |_, _, _| {
                calls.set(calls.get() + 1);
                Ok(())
            },
        );
        assert_eq!(result, Ok(()));
        assert_eq!(calls.get(), 1);
    }

    #[test]
    fn literal_ipv6_fails_closed_before_dns_or_connect() {
        let owner = admitted_owner();
        let resolved = Cell::new(false);
        let connected = Cell::new(false);
        let result = connect_host_with(
            &owner,
            &TargetHost::Ipv6(Ipv6Addr::LOCALHOST),
            8443,
            deadline(),
            |_, _, _| {
                resolved.set(true);
                Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 10))])
            },
            |_, _, _| {
                connected.set(true);
                Ok(())
            },
        );
        assert_eq!(result, Err(OutboundConnectError::Rejected));
        assert!(!resolved.get());
        assert!(!connected.get());
    }

    #[test]
    fn lookup_error_empty_or_aaaa_only_never_connects() {
        let outcomes = [
            Err(OutboundConnectError::Failed),
            Ok(Vec::new()),
            Ok(vec![IpAddr::V6(Ipv6Addr::LOCALHOST)]),
        ];
        for outcome in outcomes {
            let owner = admitted_owner();
            let connected = Cell::new(false);
            let result = connect_host_with(
                &owner,
                &TargetHost::Domain("example.invalid".into()),
                443,
                deadline(),
                move |_, _, _| outcome,
                |_, _, _| {
                    connected.set(true);
                    Ok(())
                },
            );
            assert!(result.is_err());
            assert!(!connected.get());
        }
    }

    #[test]
    fn lookup_timeout_never_connects() {
        let owner = admitted_owner();
        let connected = Cell::new(false);
        let operation_deadline = Instant::now() + Duration::from_millis(5);
        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("slow.invalid".into()),
            443,
            operation_deadline,
            |_, _, _| {
                thread::sleep(Duration::from_millis(20));
                Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 10))])
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
    fn ipv4_candidate_retry_is_bounded_by_one_absolute_deadline() {
        let owner = admitted_owner();
        let attempts = Cell::new(0_usize);
        let operation_deadline = Instant::now() + Duration::from_secs(1);
        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("retry.invalid".into()),
            443,
            operation_deadline,
            |_, _, _| {
                Ok(vec![
                    IpAddr::V4(Ipv4Addr::new(203, 0, 113, 1)),
                    IpAddr::V4(Ipv4Addr::new(203, 0, 113, 2)),
                    IpAddr::V4(Ipv4Addr::new(203, 0, 113, 3)),
                ])
            },
            |_, address, attempt_deadline| {
                assert!(address.is_ipv4());
                assert!(attempt_deadline <= operation_deadline);
                attempts.set(attempts.get() + 1);
                Err::<(), _>(OutboundConnectError::Failed)
            },
        );
        assert_eq!(result, Err(OutboundConnectError::Failed));
        assert_eq!(attempts.get(), 3);
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
    fn domain_filters_ipv6_deduplicates_and_bounds_candidates() {
        let mut addresses = vec![
            IpAddr::V6(Ipv6Addr::LOCALHOST),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 1)),
            IpAddr::V4(Ipv4Addr::new(203, 0, 113, 1)),
        ];
        for suffix in 2..=20 {
            addresses.push(IpAddr::V4(Ipv4Addr::new(203, 0, 113, suffix)));
        }
        let candidates = bounded_ipv4_candidates(addresses).expect("bounded candidates");
        assert_eq!(candidates.len(), MAX_IPV4_CANDIDATES);
        assert!(candidates.iter().all(IpAddr::is_ipv4));
    }

    #[test]
    fn resolver_pool_is_bounded_under_parallel_load() {
        let owner = admitted_owner();
        let authority = issue_authority(&owner).expect("authority");
        let active = Arc::new(AtomicUsize::new(0));
        let maximum = Arc::new(AtomicUsize::new(0));
        let active_for_resolver = Arc::clone(&active);
        let maximum_for_resolver = Arc::clone(&maximum);
        let resolver = resolver(move |_, _| {
            let now = active_for_resolver.fetch_add(1, Ordering::SeqCst) + 1;
            maximum_for_resolver.fetch_max(now, Ordering::SeqCst);
            thread::sleep(Duration::from_millis(2));
            active_for_resolver.fetch_sub(1, Ordering::SeqCst);
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        });
        let pool = Arc::new(ResolverPool::spawn(Arc::clone(&owner), resolver).expect("pool"));
        let parallelism = 50_usize;
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
            assert!(handle.join().expect("resolver caller").is_ok());
        }
        assert_eq!(active.load(Ordering::SeqCst), 0);
        assert!(maximum.load(Ordering::SeqCst) <= RESOLVER_WORKER_COUNT);
    }

    #[test]
    fn resolver_queue_overload_is_typed_and_fails_closed() {
        let owner = admitted_owner();
        let authority = issue_authority(&owner).expect("authority");
        let active = Arc::new(AtomicUsize::new(0));
        let release = Arc::new((Mutex::new(false), Condvar::new()));
        let active_for_resolver = Arc::clone(&active);
        let release_for_resolver = Arc::clone(&release);
        let resolver = resolver(move |_, _| {
            active_for_resolver.fetch_add(1, Ordering::SeqCst);
            let (lock, condition) = &*release_for_resolver;
            let mut released = lock.lock().expect("release mutex");
            while !*released {
                released = condition.wait(released).expect("release wait");
            }
            active_for_resolver.fetch_sub(1, Ordering::SeqCst);
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        });
        let pool = Arc::new(ResolverPool::spawn(Arc::clone(&owner), resolver).expect("pool"));

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
    fn resolver_worker_revalidates_authority_before_dns_effect() {
        let owner = admitted_owner();
        let authority = issue_authority(&owner).expect("authority");
        let invoked = Arc::new(AtomicBool::new(false));
        let invoked_for_resolver = Arc::clone(&invoked);
        let pool = ResolverPool::spawn(
            Arc::clone(&owner),
            resolver(move |_, _| {
                invoked_for_resolver.store(true, Ordering::SeqCst);
                Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
            }),
        )
        .expect("pool");
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
}
