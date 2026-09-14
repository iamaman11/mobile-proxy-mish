//! Exact-address UDP ingress is deliberately feature-gated by authenticated associations.
//!
//! This is a transport primitive, not a raw public UDP relay. The Proxy Serving owner must
//! authorize every datagram. Product composition deliberately does not construct it yet.

use std::collections::{HashMap, hash_map::Entry};
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr, SocketAddrV4, UdpSocket};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const POLL: Duration = Duration::from_millis(20);
const IDLE: Duration = Duration::from_secs(30);
const MAX_UDP_DATAGRAM: usize = 65_507;
const ASSOCIATION_MAGIC: &[u8; 4] = b"MUDP";
const ASSOCIATION_HEADER_BYTES: usize = 4 + 16 + 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct UdpAssociationId(u64);

impl UdpAssociationId {
    pub const fn new(value: u64) -> Option<Self> {
        if value == 0 { None } else { Some(Self(value)) }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct UdpIngressBudget {
    max_associations: usize,
    packets_per_second: u32,
    max_datagram_bytes: usize,
}

impl UdpIngressBudget {
    pub const fn new(
        max_associations: usize,
        packets_per_second: u32,
        max_datagram_bytes: usize,
    ) -> Option<Self> {
        if max_associations == 0
            || packets_per_second == 0
            || max_datagram_bytes == 0
            || max_datagram_bytes > MAX_UDP_DATAGRAM
        {
            None
        } else {
            Some(Self {
                max_associations,
                packets_per_second,
                max_datagram_bytes,
            })
        }
    }

    pub const fn conservative() -> Self {
        Self {
            max_associations: 32,
            packets_per_second: 100,
            max_datagram_bytes: 16 * 1024,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AuthorizedUdpDatagram {
    association: UdpAssociationId,
    loopback_backend_port: u16,
    payload_offset: usize,
}

impl AuthorizedUdpDatagram {
    pub const fn new(association: UdpAssociationId, loopback_backend_port: u16) -> Option<Self> {
        if loopback_backend_port == 0 {
            None
        } else {
            Some(Self {
                association,
                loopback_backend_port,
                payload_offset: 0,
            })
        }
    }

    const fn enveloped(association: UdpAssociationId, loopback_backend_port: u16) -> Option<Self> {
        if loopback_backend_port == 0 {
            None
        } else {
            Some(Self {
                association,
                loopback_backend_port,
                payload_offset: ASSOCIATION_HEADER_BYTES,
            })
        }
    }
}

/// Per-generation opaque material issued only after authenticated TCP control.
/// The value is redacted and must never be logged or exposed in a UI.
#[derive(Clone, PartialEq, Eq)]
pub struct UdpAssociationCredential {
    id: [u8; 16],
    secret: [u8; 32],
}

impl UdpAssociationCredential {
    pub fn new(id: [u8; 16], secret: [u8; 32]) -> Option<Self> {
        if all_zero(&id) || all_zero(&secret) {
            None
        } else {
            Some(Self { id, secret })
        }
    }
}

impl std::fmt::Debug for UdpAssociationCredential {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("UdpAssociationCredential(<redacted>)")
    }
}

/// Association owner for a future authenticated control bridge. Epoch replacement and revoke
/// remove all permits. The first packet pins one exact Mesh peer socket.
pub struct UdpAssociationRegistry {
    state: Mutex<UdpAssociationState>,
}

struct UdpAssociationState {
    epoch: u64,
    permits: HashMap<[u8; 16], UdpAssociationPermit>,
}

struct UdpAssociationPermit {
    association: UdpAssociationId,
    secret: [u8; 32],
    backend_port: u16,
    expires: Instant,
    peer: Option<SocketAddr>,
}

impl UdpAssociationRegistry {
    pub fn new() -> Self {
        Self {
            state: Mutex::new(UdpAssociationState {
                epoch: 0,
                permits: HashMap::new(),
            }),
        }
    }

    pub fn replace_epoch(&self, epoch: u64) -> bool {
        if epoch == 0 {
            return false;
        }
        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        state.epoch = epoch;
        state.permits.clear();
        true
    }

    pub fn revoke_all(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.epoch = 0;
            state.permits.clear();
        }
    }

    pub fn issue(
        &self,
        epoch: u64,
        credential: UdpAssociationCredential,
        association: UdpAssociationId,
        backend_port: u16,
        ttl: Duration,
    ) -> bool {
        if backend_port == 0 || ttl.is_zero() {
            return false;
        }
        let Some(expires) = Instant::now().checked_add(ttl) else {
            return false;
        };
        self.state
            .lock()
            .map(|mut state| {
                if state.epoch != epoch {
                    return false;
                }
                state
                    .permits
                    .insert(
                        credential.id,
                        UdpAssociationPermit {
                            association,
                            secret: credential.secret,
                            backend_port,
                            expires,
                            peer: None,
                        },
                    )
                    .is_none()
            })
            .unwrap_or(false)
    }
}

impl Default for UdpAssociationRegistry {
    fn default() -> Self {
        Self::new()
    }
}

/// The proxy owner rejects unauthenticated, expired, replayed, wrong-source and stale-epoch
/// packets here. Transport neither stores credentials nor parses a proxy protocol.
pub trait UdpDatagramAuthorizer: Send + Sync + 'static {
    fn authorize(&self, peer: SocketAddr, datagram: &[u8]) -> Option<AuthorizedUdpDatagram>;
}

impl UdpDatagramAuthorizer for UdpAssociationRegistry {
    fn authorize(&self, peer: SocketAddr, datagram: &[u8]) -> Option<AuthorizedUdpDatagram> {
        if datagram.len() <= ASSOCIATION_HEADER_BYTES || &datagram[..4] != ASSOCIATION_MAGIC {
            return None;
        }
        let mut id = [0_u8; 16];
        id.copy_from_slice(&datagram[4..20]);
        let supplied_secret = &datagram[20..ASSOCIATION_HEADER_BYTES];
        let mut state = self.state.lock().ok()?;
        if state.epoch == 0 {
            return None;
        }
        let permit = state.permits.get_mut(&id)?;
        if Instant::now() >= permit.expires || !constant_time_eq(&permit.secret, supplied_secret) {
            return None;
        }
        match permit.peer {
            Some(bound) if bound != peer => return None,
            Some(_) => {}
            None => permit.peer = Some(peer),
        }
        AuthorizedUdpDatagram::enveloped(permit.association, permit.backend_port)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshUdpIngressError {
    InvalidEndpoint,
    InvalidPort,
    BindFailed,
    SocketConfigurationFailed,
    ThreadUnavailable,
}

struct Association {
    peer: SocketAddr,
    backend: UdpSocket,
    stop: Arc<AtomicBool>,
    response_worker: JoinHandle<()>,
    window_started: Instant,
    packets_in_window: u32,
    last_activity: Instant,
}

impl Association {
    fn stop(self) {
        self.stop.store(true, Ordering::Release);
        let _ = self.response_worker.join();
    }
}

/// A single exact-address listener for one admitted Mesh endpoint generation.
pub struct MeshUdpIngressRuntime {
    endpoint: Ipv4Addr,
    port: u16,
    stop: Arc<AtomicBool>,
    associations: Arc<Mutex<HashMap<UdpAssociationId, Association>>>,
    worker: Option<JoinHandle<()>>,
}

impl MeshUdpIngressRuntime {
    pub fn start(
        endpoint: Ipv4Addr,
        port: u16,
        budget: UdpIngressBudget,
        authorizer: Arc<dyn UdpDatagramAuthorizer>,
    ) -> Result<Self, MeshUdpIngressError> {
        if endpoint.is_unspecified() || endpoint.is_multicast() || endpoint == Ipv4Addr::BROADCAST {
            return Err(MeshUdpIngressError::InvalidEndpoint);
        }
        if port == 0 {
            return Err(MeshUdpIngressError::InvalidPort);
        }
        let socket = UdpSocket::bind(SocketAddr::V4(SocketAddrV4::new(endpoint, port)))
            .map_err(|_| MeshUdpIngressError::BindFailed)?;
        socket
            .set_read_timeout(Some(POLL))
            .map_err(|_| MeshUdpIngressError::SocketConfigurationFailed)?;
        let responses = socket
            .try_clone()
            .map_err(|_| MeshUdpIngressError::SocketConfigurationFailed)?;
        let stop = Arc::new(AtomicBool::new(false));
        let associations = Arc::new(Mutex::new(HashMap::new()));
        let worker_stop = Arc::clone(&stop);
        let worker_associations = Arc::clone(&associations);
        let worker = thread::Builder::new()
            .name(format!("mish-mesh-udp-{port}"))
            .spawn(move || {
                udp_loop(
                    socket,
                    responses,
                    worker_stop,
                    worker_associations,
                    budget,
                    authorizer,
                )
            })
            .map_err(|_| MeshUdpIngressError::ThreadUnavailable)?;
        Ok(Self {
            endpoint,
            port,
            stop,
            associations,
            worker: Some(worker),
        })
    }

    pub const fn endpoint(&self) -> Ipv4Addr {
        self.endpoint
    }
    pub const fn port(&self) -> u16 {
        self.port
    }
    pub fn is_healthy(&self) -> bool {
        !self.stop.load(Ordering::Acquire)
            && self
                .worker
                .as_ref()
                .is_some_and(|worker| !worker.is_finished())
    }
    pub fn active_associations(&self) -> usize {
        self.associations
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .len()
    }

    pub fn stop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
        let associations =
            std::mem::take(&mut *self.associations.lock().unwrap_or_else(|p| p.into_inner()));
        for association in associations.into_values() {
            association.stop();
        }
    }
}

impl Drop for MeshUdpIngressRuntime {
    fn drop(&mut self) {
        self.stop();
    }
}

fn udp_loop(
    socket: UdpSocket,
    response_socket: UdpSocket,
    stop: Arc<AtomicBool>,
    associations: Arc<Mutex<HashMap<UdpAssociationId, Association>>>,
    budget: UdpIngressBudget,
    authorizer: Arc<dyn UdpDatagramAuthorizer>,
) {
    let mut buffer = vec![0_u8; budget.max_datagram_bytes];
    while !stop.load(Ordering::Acquire) {
        let (count, peer) = match socket.recv_from(&mut buffer) {
            Ok(received) => received,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                prune_idle(&associations);
                continue;
            }
            Err(_) => return,
        };
        let Some(authorized) = authorizer.authorize(peer, &buffer[..count]) else {
            continue;
        };
        if authorized.payload_offset >= count {
            continue;
        }
        let now = Instant::now();
        let mut state = associations.lock().unwrap_or_else(|p| p.into_inner());
        let at_capacity = state.len() >= budget.max_associations;
        if let Entry::Vacant(entry) = state.entry(authorized.association) {
            if at_capacity {
                continue;
            }
            let Some(association) = new_association(
                peer,
                authorized.loopback_backend_port,
                &response_socket,
                &stop,
            ) else {
                continue;
            };
            entry.insert(association);
        }
        let Some(association) = state.get_mut(&authorized.association) else {
            continue;
        };
        if association.peer != peer {
            continue;
        }
        if now.duration_since(association.window_started) >= Duration::from_secs(1) {
            association.window_started = now;
            association.packets_in_window = 0;
        }
        if association.packets_in_window >= budget.packets_per_second {
            continue;
        }
        association.packets_in_window += 1;
        association.last_activity = now;
        let _ = association
            .backend
            .send(&buffer[authorized.payload_offset..count]);
    }
}

fn new_association(
    peer: SocketAddr,
    backend_port: u16,
    response_socket: &UdpSocket,
    parent_stop: &Arc<AtomicBool>,
) -> Option<Association> {
    let backend = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).ok()?;
    backend
        .connect(SocketAddr::new(
            IpAddr::V4(Ipv4Addr::LOCALHOST),
            backend_port,
        ))
        .ok()?;
    backend.set_read_timeout(Some(POLL)).ok()?;
    let reader = backend.try_clone().ok()?;
    let responses = response_socket.try_clone().ok()?;
    let stop = Arc::new(AtomicBool::new(false));
    let worker_stop = Arc::clone(&stop);
    let parent = Arc::clone(parent_stop);
    let response_worker = thread::Builder::new()
        .name("mish-mesh-udp-response".to_owned())
        .spawn(move || {
            let mut response = [0_u8; MAX_UDP_DATAGRAM];
            while !parent.load(Ordering::Acquire) && !worker_stop.load(Ordering::Acquire) {
                match reader.recv(&mut response) {
                    Ok(count) => {
                        let _ = responses.send_to(&response[..count], peer);
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                        ) => {}
                    Err(_) => return,
                }
            }
        })
        .ok()?;
    Some(Association {
        peer,
        backend,
        stop,
        response_worker,
        window_started: Instant::now(),
        packets_in_window: 0,
        last_activity: Instant::now(),
    })
}

fn prune_idle(associations: &Mutex<HashMap<UdpAssociationId, Association>>) {
    let now = Instant::now();
    let expired = {
        let mut state = associations.lock().unwrap_or_else(|p| p.into_inner());
        let ids = state
            .iter()
            .filter_map(|(id, association)| {
                (now.duration_since(association.last_activity) >= IDLE).then_some(*id)
            })
            .collect::<Vec<_>>();
        ids.into_iter()
            .filter_map(|id| state.remove(&id))
            .collect::<Vec<_>>()
    };
    for association in expired {
        association.stop();
    }
}

fn all_zero(bytes: &[u8]) -> bool {
    bytes.iter().all(|byte| *byte == 0)
}

/// Avoid an early-exit secret comparison at this trust boundary. This does not replace a
/// platform-keystore-backed credential issuer; it only makes verification deterministic.
fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut different = 0_u8;
    for (left, right) in left.iter().zip(right) {
        different |= left ^ right;
    }
    different == 0
}
