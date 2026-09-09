//! Runtime Lifecycle natural-owner capability.
//!
//! Owns desired-running reconciliation and owned-child lifecycle semantics without
//! becoming the semantic owner of transport, proxy, or cellular readiness.
//!
//! B4b adds only the concrete composition adapter that satisfies the bridge's
//! `CellularOutboundConnector` port. It does not add an accept loop, retry policy,
//! supervisor, or second cellular state machine.

use mish_android_network::{AndroidConnectError, AndroidNetworkError};
use mish_cellular::{CellularEgress, CellularNetworkAuthority, CellularNetworkAuthorityError};
use mish_cellular_egress_bridge::{
    CellularOutboundConnector, ConnectTarget, OutboundConnectError, TargetHost,
};
use std::fmt;
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::sync::{Arc, Mutex};

/// Concrete runtime-composition adapter from the bridge's outbound port to one shared
/// Cellular Egress natural owner plus the bounded Android exact-network mechanics.
///
/// The connector does not create or mutate admission state. Runtime composition passes
/// the same owner instance that receives Android observations, so every CONNECT obtains
/// a fresh owner-issued authority generation and fails closed when that generation is
/// stale or unavailable.
#[derive(Clone)]
pub struct AndroidCellularOutboundConnector {
    owner: Arc<Mutex<CellularEgress>>,
}

impl AndroidCellularOutboundConnector {
    /// Wires the connector to an existing runtime-scoped Cellular Egress owner.
    pub fn new(owner: Arc<Mutex<CellularEgress>>) -> Self {
        Self { owner }
    }
}

impl fmt::Debug for AndroidCellularOutboundConnector {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("AndroidCellularOutboundConnector")
            .finish_non_exhaustive()
    }
}

impl CellularOutboundConnector for AndroidCellularOutboundConnector {
    fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
        connect_host_with(
            &self.owner,
            target.host(),
            target.port(),
            resolve_domain,
            |authority, address| {
                mish_android_network::connect_tcp(authority, address)
                    .map_err(map_android_connect_error)
            },
        )
    }
}

fn resolve_domain(
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

/// Private deterministic operation seam. Production has exactly one implementation:
/// `mish-android-network`. Closures exist only to prove sequencing/failure behavior in
/// hosted tests without pretending those tests are physical E3 evidence.
fn connect_host_with<T>(
    owner: &Arc<Mutex<CellularEgress>>,
    host: &TargetHost,
    port: u16,
    resolve: impl FnOnce(CellularNetworkAuthority, &str) -> Result<Vec<IpAddr>, OutboundConnectError>,
    connect: impl FnOnce(CellularNetworkAuthority, SocketAddr) -> Result<T, OutboundConnectError>,
) -> Result<T, OutboundConnectError> {
    if port == 0 {
        return Err(OutboundConnectError::Rejected);
    }

    let authority = issue_authority(owner)?;

    let address = match host {
        TargetHost::Ipv4(address) => IpAddr::V4(*address),
        TargetHost::Ipv6(address) => IpAddr::V6(*address),
        TargetHost::Domain(domain) => {
            let addresses = resolve(authority, domain)?;
            validate_authority(owner, authority)?;
            addresses
                .into_iter()
                .next()
                .ok_or(OutboundConnectError::Failed)?
        }
    };

    // This is intentionally one connect attempt. Runtime Lifecycle owns any later
    // recovery decision; the connector has no hidden retry/address-fallback stack.
    validate_authority(owner, authority)?;
    let stream = connect(authority, SocketAddr::new(address, port))?;
    validate_authority(owner, authority)?;
    Ok(stream)
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
        AndroidNetworkError::InvalidHostname | AndroidNetworkError::InvalidSocketFd => {
            OutboundConnectError::Rejected
        }
        AndroidNetworkError::UnsupportedPlatform => OutboundConnectError::Unavailable,
        AndroidNetworkError::NativeSocketBindFailed
        | AndroidNetworkError::NativeDnsLookupFailed
        | AndroidNetworkError::NativeDnsNoResults
        | AndroidNetworkError::NativeAddressConversionFailed => OutboundConnectError::Failed,
    }
}

fn map_android_connect_error(error: AndroidConnectError) -> OutboundConnectError {
    match error {
        AndroidConnectError::UnsupportedPlatform => OutboundConnectError::Unavailable,
        AndroidConnectError::NativeSocketCreateFailed
        | AndroidConnectError::NativeSocketBindFailed
        | AndroidConnectError::NativeConnectFailed => OutboundConnectError::Failed,
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
        ));
        Arc::new(Mutex::new(owner))
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
            |_, _| {
                resolved.set(true);
                Ok(vec![IpAddr::V4(Ipv4Addr::LOCALHOST)])
            },
            |_, _| {
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

            let result = connect_host_with(
                &owner,
                &host,
                8443,
                |_, _| -> Result<Vec<IpAddr>, OutboundConnectError> {
                    panic!("numeric target must never invoke DNS")
                },
                |_, address| {
                    calls.set(calls.get() + 1);
                    observed.set(Some(address));
                    Ok(())
                },
            );

            assert_eq!(result, Ok(()));
            assert_eq!(calls.get(), 1);
            assert_eq!(observed.get().expect("connect address").port(), 8443);
        }
    }

    #[test]
    fn domain_dns_and_connect_use_same_authority_and_first_address_only() {
        let owner = admitted_owner();
        let dns_authority = Cell::new(None::<CellularNetworkAuthority>);
        let connect_authority = Cell::new(None::<CellularNetworkAuthority>);
        let connect_calls = Cell::new(0_u8);
        let first = IpAddr::V4(Ipv4Addr::new(203, 0, 113, 20));
        let second = IpAddr::V4(Ipv4Addr::new(203, 0, 113, 21));

        let result = connect_host_with(
            &owner,
            &TargetHost::Domain("example.invalid".into()),
            443,
            |authority, domain| {
                assert_eq!(domain, "example.invalid");
                dns_authority.set(Some(authority));
                Ok(vec![first, second])
            },
            |authority, address| {
                connect_authority.set(Some(authority));
                connect_calls.set(connect_calls.get() + 1);
                assert_eq!(address, SocketAddr::new(first, 443));
                Ok(())
            },
        );

        assert_eq!(result, Ok(()));
        assert_eq!(connect_calls.get(), 1);
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
            move |_, _| {
                owner_during_dns
                    .lock()
                    .expect("owner mutex")
                    .lost(sequence(2), handle(42));
                Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 20))])
            },
            |_, _| {
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
            |_, _| -> Result<Vec<IpAddr>, OutboundConnectError> {
                panic!("numeric target must never invoke DNS")
            },
            move |_, _| {
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
    fn zero_port_is_rejected_before_authority_or_platform_access() {
        let owner = admitted_owner();
        let connected = Cell::new(false);

        let result = connect_host_with(
            &owner,
            &TargetHost::Ipv4(Ipv4Addr::LOCALHOST),
            0,
            |_, _| -> Result<Vec<IpAddr>, OutboundConnectError> {
                panic!("zero port must fail before DNS")
            },
            |_, _| {
                connected.set(true);
                Ok(())
            },
        );

        assert_eq!(result, Err(OutboundConnectError::Rejected));
        assert!(!connected.get());
    }
}
