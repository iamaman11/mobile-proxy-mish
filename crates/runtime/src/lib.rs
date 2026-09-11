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
/// owner. It has no network-selection state, retry policy, fallback, or second lifecycle.
#[derive(Clone)]
pub struct AndroidCellularOutboundConnector {
    owner: Arc<Mutex<CellularEgress>>,
    operation_timeout: Duration,
    resolver: Arc<ResolverWorker>,
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
            owner,
            operation_timeout,
            resolver: Arc::new(ResolverWorker::spawn()?),
        })
    }
}

impl fmt::Debug for AndroidCellularOutboundConnector {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AndroidCellularOutboundConnector")
            .field("operation_timeout", &self.operation_timeout)
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
            |_authority, address, deadline| connect_root_policy_socket(address, deadline),
        )
    }
}

struct ResolveRequest {
    authority: CellularNetworkAuthority,
    hostname: Box<str>,
    deadline: Instant,
    response: SyncSender<Result<Vec<IpAddr>, OutboundConnectError>>,
}

struct ResolverWorker {
    requests: SyncSender<ResolveRequest>,
}

impl ResolverWorker {
    fn spawn() -> Result<Self, CellularConnectorConfigError> {
        let (requests, receiver) = mpsc::sync_channel(1);
        thread::Builder::new()
            .name("mish-cellular-dns".into())
            .spawn(move || resolver_worker_loop(receiver))
            .map_err(|_| CellularConnectorConfigError::ResolverWorkerUnavailable)?;
        Ok(Self { requests })
    }

    fn resolve(
        &self,
        authority: CellularNetworkAuthority,
        hostname: &str,
        deadline: Instant,
    ) -> Result<Vec<IpAddr>, OutboundConnectError> {
        let initial_remaining = remaining(deadline)?;
        let (response, result) = mpsc::sync_channel(1);
        let request = ResolveRequest {
            authority,
            hostname: hostname.into(),
            deadline,
            response,
        };
        match self.requests.try_send(request) {
            Ok(()) => {}
            Err(TrySendError::Full(_)) | Err(TrySendError::Disconnected(_)) => {
                return Err(OutboundConnectError::Unavailable);
            }
        }

        let wait = remaining(deadline)?.min(initial_remaining);
        match result.recv_timeout(wait) {
            Ok(result) => result,
            Err(RecvTimeoutError::Timeout) | Err(RecvTimeoutError::Disconnected) => {
                Err(OutboundConnectError::Unavailable)
            }
        }
    }
}

fn resolver_worker_loop(receiver: Receiver<ResolveRequest>) {
    while let Ok(request) = receiver.recv() {
        if Instant::now() >= request.deadline {
            let _ = request
                .response
                .send(Err(OutboundConnectError::Unavailable));
            continue;
        }

        let result = resolve_domain_blocking(request.authority, &request.hostname);
        let result = if Instant::now() < request.deadline {
            result
        } else {
            Err(OutboundConnectError::Unavailable)
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
    numeric
        .into_iter()
        .map(|address| {
            address
                .parse::<IpAddr>()
                .map_err(|_| OutboundConnectError::Failed)
        })
        .collect()
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

/// Private deterministic operation seam. Closures exist only to prove owner sequencing
/// and currentness in hosted tests; production has the DNS + root-policy socket path above.
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
    connect: impl FnOnce(
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
    let address = match host {
        TargetHost::Ipv4(address) => IpAddr::V4(*address),
        TargetHost::Ipv6(address) => IpAddr::V6(*address),
        TargetHost::Domain(domain) => {
            ensure_deadline(deadline)?;
            let addresses = resolve(authority, domain, deadline)?;
            ensure_deadline(deadline)?;
            validate_authority(owner, authority)?;
            addresses
                .into_iter()
                .next()
                .ok_or(OutboundConnectError::Failed)?
        }
    };

    // Exactly one address/connect attempt is dispatched. Authority is validated both
    // before and after the bounded platform effect so a stale generation cannot be
    // promoted into apparent success.
    ensure_deadline(deadline)?;
    validate_authority(owner, authority)?;
    let stream = connect(authority, SocketAddr::new(address, port), deadline)?;
    ensure_deadline(deadline)?;
    validate_authority(owner, authority)?;
    Ok(stream)
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
            let expected_deadline = deadline();

            let result = connect_host_with(
                &owner,
                &host,
                8443,
                expected_deadline,
                |_, _, _| -> Result<Vec<IpAddr>, OutboundConnectError> {
                    panic!("numeric target must never invoke DNS")
                },
                |_, address, received_deadline| {
                    calls.set(calls.get() + 1);
                    observed.set(Some(address));
                    assert_eq!(received_deadline, expected_deadline);
                    Ok(())
                },
            );

            assert_eq!(result, Ok(()));
            assert_eq!(calls.get(), 1);
            assert_eq!(observed.get().expect("connect address").port(), 8443);
        }
    }

    #[test]
    fn domain_dns_and_connect_share_authority_and_deadline() {
        let owner = admitted_owner();
        let dns_authority = Cell::new(None::<CellularNetworkAuthority>);
        let connect_authority = Cell::new(None::<CellularNetworkAuthority>);
        let expected_deadline = deadline();
        let first = IpAddr::V4(Ipv4Addr::new(203, 0, 113, 20));

        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("example.invalid".into()),
            443,
            expected_deadline,
            |authority, domain, received_deadline| {
                assert_eq!(domain, "example.invalid");
                assert_eq!(received_deadline, expected_deadline);
                dns_authority.set(Some(authority));
                Ok(vec![first])
            },
            |authority, address, received_deadline| {
                assert_eq!(received_deadline, expected_deadline);
                connect_authority.set(Some(authority));
                assert_eq!(address, SocketAddr::new(first, 443));
                Ok(())
            },
        );

        assert_eq!(result, Ok(()));
        assert_eq!(dns_authority.get(), connect_authority.get());
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
