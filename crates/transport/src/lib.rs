//! Transport Reachability natural-owner capability.
//!
//! Owns exact admitted Mesh endpoint facts and the deliberately small TCP ingress that exposes
//! only those exact endpoints to the existing loopback proxy runtime. It does not own proxy
//! protocols, authentication, Cloudflare/VPN configuration, DNS, or public Internet egress.

use std::collections::{BTreeSet, HashMap};
use std::io;
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, SocketAddrV4, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

pub const PRODUCT_PROXY_PORTS: [u16; 3] = [1080, 1081, 3128];
pub const MAX_MESH_SESSIONS: usize = 128;

const ACCEPT_POLL: Duration = Duration::from_millis(20);
const BACKEND_CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const MIN_ACCEPTED_PREFIX: u8 = 8;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshAdmissionState {
    NotAdmitted,
    Admitted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshAdmissionReason {
    NoObservation,
    NoAcceptedAddress,
    MultipleAcceptedAddresses,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MeshAdmissionSnapshot {
    state: MeshAdmissionState,
    reason: Option<MeshAdmissionReason>,
    admitted_endpoint: Option<Ipv4Addr>,
    admission_epoch: Option<u64>,
    last_sequence: Option<u64>,
}

impl MeshAdmissionSnapshot {
    pub fn state(self) -> MeshAdmissionState {
        self.state
    }

    pub fn reason(self) -> Option<MeshAdmissionReason> {
        self.reason
    }

    pub fn admitted_endpoint(self) -> Option<Ipv4Addr> {
        self.admitted_endpoint
    }

    pub fn admission_epoch(self) -> Option<u64> {
        self.admission_epoch
    }

    pub fn last_sequence(self) -> Option<u64> {
        self.last_sequence
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshOwnerError {
    InvalidAcceptedCidr,
    InvalidObservationSequence,
    StaleObservation,
    AdmissionEpochExhausted,
}

#[derive(Debug, Clone, Copy)]
struct Ipv4Cidr {
    network: u32,
    mask: u32,
}

impl Ipv4Cidr {
    fn new(network: Ipv4Addr, prefix: u8) -> Result<Self, MeshOwnerError> {
        if !(MIN_ACCEPTED_PREFIX..=32).contains(&prefix) {
            return Err(MeshOwnerError::InvalidAcceptedCidr);
        }
        let mask = u32::MAX << (32 - prefix);
        let network = u32::from(network);
        if network & mask != network {
            return Err(MeshOwnerError::InvalidAcceptedCidr);
        }
        Ok(Self { network, mask })
    }

    fn contains(self, address: Ipv4Addr) -> bool {
        !address.is_unspecified()
            && !address.is_multicast()
            && address != Ipv4Addr::BROADCAST
            && (u32::from(address) & self.mask) == self.network
    }
}

/// Process-generation owner of the exact currently admitted Mesh endpoint.
///
/// The caller supplies local IPv4 observations. This owner admits only when exactly one distinct
/// local IPv4 lies inside the deployment-approved Mesh CIDR. The exact address is not persisted.
/// Loss removes admission immediately; observing the same address after loss creates a fresh
/// admission epoch, and an address change can never inherit the previous epoch.
pub struct MeshEndpointOwner {
    accepted: Ipv4Cidr,
    snapshot: MeshAdmissionSnapshot,
    next_epoch: u64,
}

impl MeshEndpointOwner {
    pub fn new(accepted_network: Ipv4Addr, accepted_prefix: u8) -> Result<Self, MeshOwnerError> {
        Ok(Self {
            accepted: Ipv4Cidr::new(accepted_network, accepted_prefix)?,
            snapshot: MeshAdmissionSnapshot {
                state: MeshAdmissionState::NotAdmitted,
                reason: Some(MeshAdmissionReason::NoObservation),
                admitted_endpoint: None,
                admission_epoch: None,
                last_sequence: None,
            },
            next_epoch: 0,
        })
    }

    pub fn snapshot(&self) -> MeshAdmissionSnapshot {
        self.snapshot
    }

    pub fn observe_local_ipv4<I>(
        &mut self,
        sequence: u64,
        addresses: I,
    ) -> Result<MeshAdmissionSnapshot, MeshOwnerError>
    where
        I: IntoIterator<Item = Ipv4Addr>,
    {
        if sequence == 0 {
            return Err(MeshOwnerError::InvalidObservationSequence);
        }
        if self
            .snapshot
            .last_sequence
            .is_some_and(|last| sequence <= last)
        {
            return Err(MeshOwnerError::StaleObservation);
        }

        let candidates: BTreeSet<Ipv4Addr> = addresses
            .into_iter()
            .filter(|address| self.accepted.contains(*address))
            .collect();

        let (state, reason, admitted_endpoint) = match candidates.len() {
            0 => (
                MeshAdmissionState::NotAdmitted,
                Some(MeshAdmissionReason::NoAcceptedAddress),
                None,
            ),
            1 => (
                MeshAdmissionState::Admitted,
                None,
                candidates.first().copied(),
            ),
            _ => (
                MeshAdmissionState::NotAdmitted,
                Some(MeshAdmissionReason::MultipleAcceptedAddresses),
                None,
            ),
        };

        let admission_epoch = match admitted_endpoint {
            None => None,
            Some(endpoint) if self.snapshot.admitted_endpoint == Some(endpoint) => {
                self.snapshot.admission_epoch
            }
            Some(_) => {
                self.next_epoch = self
                    .next_epoch
                    .checked_add(1)
                    .ok_or(MeshOwnerError::AdmissionEpochExhausted)?;
                Some(self.next_epoch)
            }
        };

        self.snapshot = MeshAdmissionSnapshot {
            state,
            reason,
            admitted_endpoint,
            admission_epoch,
            last_sequence: Some(sequence),
        };
        Ok(self.snapshot)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MeshIngressError {
    InvalidEndpoint,
    InvalidPortMapping,
    BindFailed,
    ListenerConfigurationFailed,
    ThreadUnavailable,
    ShutdownTimedOut,
}

#[derive(Debug, Clone, Copy)]
struct PortForward {
    ingress_port: u16,
    backend_port: u16,
}

impl PortForward {
    const fn same(port: u16) -> Self {
        Self {
            ingress_port: port,
            backend_port: port,
        }
    }
}

struct SessionSockets {
    client: TcpStream,
    backend: TcpStream,
}

struct SessionState {
    next_id: u64,
    sockets: HashMap<u64, SessionSockets>,
}

struct SessionRegistry {
    max_sessions: usize,
    state: Mutex<SessionState>,
}

impl SessionRegistry {
    fn new(max_sessions: usize) -> Self {
        Self {
            max_sessions,
            state: Mutex::new(SessionState {
                next_id: 0,
                sockets: HashMap::new(),
            }),
        }
    }

    fn at_capacity(&self) -> bool {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .sockets
            .len()
            >= self.max_sessions
    }

    fn register(&self, client: &TcpStream, backend: &TcpStream) -> Option<u64> {
        let client_control = client.try_clone().ok()?;
        let backend_control = backend.try_clone().ok()?;
        let mut state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if state.sockets.len() >= self.max_sessions {
            return None;
        }
        state.next_id = state.next_id.wrapping_add(1);
        if state.next_id == 0 {
            state.next_id = 1;
        }
        let id = state.next_id;
        if state.sockets.contains_key(&id) {
            return None;
        }
        state.sockets.insert(
            id,
            SessionSockets {
                client: client_control,
                backend: backend_control,
            },
        );
        Some(id)
    }

    fn finish(&self, id: u64) {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .sockets
            .remove(&id);
    }

    fn shutdown_all(&self) {
        let state = self
            .state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        for session in state.sockets.values() {
            let _ = session.client.shutdown(Shutdown::Both);
            let _ = session.backend.shutdown(Shutdown::Both);
        }
    }

    fn active_count(&self) -> usize {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .sockets
            .len()
    }
}

/// Exact-address TCP ingress for one owner admission epoch.
///
/// The runtime binds only the exact admitted endpoint. Every accepted stream is forwarded to the
/// corresponding loopback sing-box port. There is no protocol parsing, authentication, UDP,
/// wildcard bind, route mutation, or VPN ownership here.
pub struct MeshIngressRuntime {
    endpoint: Ipv4Addr,
    stop: Arc<AtomicBool>,
    sessions: Arc<SessionRegistry>,
    listeners: Vec<JoinHandle<()>>,
}

impl MeshIngressRuntime {
    pub fn start_product(endpoint: Ipv4Addr) -> Result<Self, MeshIngressError> {
        let mappings = [
            PortForward::same(PRODUCT_PROXY_PORTS[0]),
            PortForward::same(PRODUCT_PROXY_PORTS[1]),
            PortForward::same(PRODUCT_PROXY_PORTS[2]),
        ];
        Self::start_mapped(endpoint, &mappings, MAX_MESH_SESSIONS)
    }

    pub fn endpoint(&self) -> Ipv4Addr {
        self.endpoint
    }

    pub fn is_healthy(&self) -> bool {
        !self.stop.load(Ordering::Acquire)
            && !self.listeners.is_empty()
            && self
                .listeners
                .iter()
                .all(|listener| !listener.is_finished())
    }

    pub fn active_sessions(&self) -> usize {
        self.sessions.active_count()
    }

    pub fn stop(&mut self) -> Result<(), MeshIngressError> {
        self.stop.store(true, Ordering::Release);
        self.sessions.shutdown_all();
        for listener in self.listeners.drain(..) {
            let _ = listener.join();
        }
        self.sessions.shutdown_all();

        let deadline = Instant::now() + SHUTDOWN_TIMEOUT;
        while self.sessions.active_count() != 0 && Instant::now() < deadline {
            thread::sleep(ACCEPT_POLL);
        }
        if self.sessions.active_count() == 0 {
            Ok(())
        } else {
            Err(MeshIngressError::ShutdownTimedOut)
        }
    }

    fn start_mapped(
        endpoint: Ipv4Addr,
        mappings: &[PortForward],
        max_sessions: usize,
    ) -> Result<Self, MeshIngressError> {
        if endpoint.is_unspecified() || endpoint.is_multicast() || endpoint == Ipv4Addr::BROADCAST {
            return Err(MeshIngressError::InvalidEndpoint);
        }
        if mappings.is_empty()
            || max_sessions == 0
            || mappings
                .iter()
                .any(|mapping| mapping.ingress_port == 0 || mapping.backend_port == 0)
        {
            return Err(MeshIngressError::InvalidPortMapping);
        }

        let mut bound = Vec::with_capacity(mappings.len());
        for mapping in mappings.iter().copied() {
            let listener = TcpListener::bind(SocketAddr::V4(SocketAddrV4::new(
                endpoint,
                mapping.ingress_port,
            )))
            .map_err(|_| MeshIngressError::BindFailed)?;
            listener
                .set_nonblocking(true)
                .map_err(|_| MeshIngressError::ListenerConfigurationFailed)?;
            bound.push((listener, mapping));
        }

        let stop = Arc::new(AtomicBool::new(false));
        let sessions = Arc::new(SessionRegistry::new(max_sessions));
        let mut listeners = Vec::with_capacity(bound.len());

        for (listener, mapping) in bound {
            let worker_stop = Arc::clone(&stop);
            let worker_sessions = Arc::clone(&sessions);
            let name = format!("mish-mesh-listener-{}", mapping.ingress_port);
            match thread::Builder::new()
                .name(name)
                .spawn(move || listener_loop(listener, mapping, worker_stop, worker_sessions))
            {
                Ok(worker) => listeners.push(worker),
                Err(_) => {
                    stop.store(true, Ordering::Release);
                    sessions.shutdown_all();
                    for worker in listeners {
                        let _ = worker.join();
                    }
                    return Err(MeshIngressError::ThreadUnavailable);
                }
            }
        }

        Ok(Self {
            endpoint,
            stop,
            sessions,
            listeners,
        })
    }
}

impl Drop for MeshIngressRuntime {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

fn listener_loop(
    listener: TcpListener,
    mapping: PortForward,
    stop: Arc<AtomicBool>,
    sessions: Arc<SessionRegistry>,
) {
    while !stop.load(Ordering::Acquire) {
        match listener.accept() {
            Ok((client, _peer)) => {
                if stop.load(Ordering::Acquire) || sessions.at_capacity() {
                    let _ = client.shutdown(Shutdown::Both);
                    continue;
                }
                let backend_address =
                    SocketAddr::new(IpAddr::V4(Ipv4Addr::LOCALHOST), mapping.backend_port);
                let backend =
                    match TcpStream::connect_timeout(&backend_address, BACKEND_CONNECT_TIMEOUT) {
                        Ok(stream) => stream,
                        Err(_) => {
                            let _ = client.shutdown(Shutdown::Both);
                            continue;
                        }
                    };
                let _ = client.set_nodelay(true);
                let _ = backend.set_nodelay(true);
                let Some(session_id) = sessions.register(&client, &backend) else {
                    let _ = client.shutdown(Shutdown::Both);
                    let _ = backend.shutdown(Shutdown::Both);
                    continue;
                };
                let session_registry = Arc::clone(&sessions);
                let name = format!("mish-mesh-session-{}", mapping.ingress_port);
                if thread::Builder::new()
                    .name(name)
                    .spawn(move || run_session(session_id, client, backend, session_registry))
                    .is_err()
                {
                    sessions.finish(session_id);
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(ACCEPT_POLL);
            }
            Err(_) => return,
        }
    }
}

fn run_session(
    session_id: u64,
    mut client: TcpStream,
    mut backend: TcpStream,
    sessions: Arc<SessionRegistry>,
) {
    let mut client_reader = match client.try_clone() {
        Ok(stream) => stream,
        Err(_) => {
            sessions.finish(session_id);
            return;
        }
    };
    let mut backend_writer = match backend.try_clone() {
        Ok(stream) => stream,
        Err(_) => {
            sessions.finish(session_id);
            return;
        }
    };

    let upstream = thread::Builder::new()
        .name("mish-mesh-copy-upstream".to_owned())
        .spawn(move || {
            let _ = io::copy(&mut client_reader, &mut backend_writer);
            let _ = backend_writer.shutdown(Shutdown::Write);
        });

    if let Ok(upstream) = upstream {
        let _ = io::copy(&mut backend, &mut client);
        let _ = client.shutdown(Shutdown::Write);
        let _ = upstream.join();
    }
    let _ = client.shutdown(Shutdown::Both);
    let _ = backend.shutdown(Shutdown::Both);
    sessions.finish(session_id);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    fn owner() -> MeshEndpointOwner {
        MeshEndpointOwner::new(Ipv4Addr::new(100, 96, 0, 0), 12).expect("valid Mesh range")
    }

    #[test]
    fn admission_requires_exactly_one_address_inside_accepted_range() {
        let mut owner = owner();
        let snapshot = owner
            .observe_local_ipv4(
                1,
                [
                    Ipv4Addr::new(127, 0, 0, 1),
                    Ipv4Addr::new(192, 168, 1, 2),
                    Ipv4Addr::new(100, 96, 4, 8),
                ],
            )
            .expect("observe");
        assert_eq!(snapshot.state(), MeshAdmissionState::Admitted);
        assert_eq!(
            snapshot.admitted_endpoint(),
            Some(Ipv4Addr::new(100, 96, 4, 8))
        );
        assert_eq!(snapshot.admission_epoch(), Some(1));

        let ambiguous = owner
            .observe_local_ipv4(
                2,
                [Ipv4Addr::new(100, 96, 4, 8), Ipv4Addr::new(100, 97, 4, 9)],
            )
            .expect("observe ambiguous");
        assert_eq!(ambiguous.state(), MeshAdmissionState::NotAdmitted);
        assert_eq!(
            ambiguous.reason(),
            Some(MeshAdmissionReason::MultipleAcceptedAddresses)
        );
        assert_eq!(ambiguous.admission_epoch(), None);
    }

    #[test]
    fn loss_and_reappearance_create_a_fresh_epoch_without_caching() {
        let mut owner = owner();
        let first = owner
            .observe_local_ipv4(1, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("first admission");
        let stable = owner
            .observe_local_ipv4(2, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("stable observation");
        assert_eq!(first.admission_epoch(), stable.admission_epoch());

        let lost = owner
            .observe_local_ipv4(3, [Ipv4Addr::new(192, 168, 1, 1)])
            .expect("loss");
        assert_eq!(lost.state(), MeshAdmissionState::NotAdmitted);
        assert_eq!(lost.admission_epoch(), None);

        let returned = owner
            .observe_local_ipv4(4, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("re-admission");
        assert_eq!(returned.state(), MeshAdmissionState::Admitted);
        assert_ne!(returned.admission_epoch(), first.admission_epoch());
    }

    #[test]
    fn address_change_never_inherits_old_epoch() {
        let mut owner = owner();
        let first = owner
            .observe_local_ipv4(1, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("first");
        let changed = owner
            .observe_local_ipv4(2, [Ipv4Addr::new(100, 96, 0, 8)])
            .expect("changed");
        assert_ne!(changed.admitted_endpoint(), first.admitted_endpoint());
        assert_ne!(changed.admission_epoch(), first.admission_epoch());
    }

    #[test]
    fn stale_observation_cannot_replace_current_admission() {
        let mut owner = owner();
        let current = owner
            .observe_local_ipv4(2, [Ipv4Addr::new(100, 96, 0, 7)])
            .expect("current");
        assert_eq!(
            owner.observe_local_ipv4(1, [Ipv4Addr::new(100, 96, 0, 8)]),
            Err(MeshOwnerError::StaleObservation)
        );
        assert_eq!(owner.snapshot(), current);
    }

    #[test]
    fn broad_or_noncanonical_cidr_is_rejected() {
        assert!(matches!(
            MeshEndpointOwner::new(Ipv4Addr::UNSPECIFIED, 0),
            Err(MeshOwnerError::InvalidAcceptedCidr)
        ));
        assert!(matches!(
            MeshEndpointOwner::new(Ipv4Addr::new(100, 96, 1, 0), 12),
            Err(MeshOwnerError::InvalidAcceptedCidr)
        ));
    }

    #[test]
    fn mapped_ingress_forwards_bidirectionally_and_stops_cleanly() {
        let backend = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("backend bind");
        let backend_port = backend.local_addr().expect("backend address").port();
        let reserve = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("reserve ingress");
        let ingress_port = reserve.local_addr().expect("ingress address").port();
        drop(reserve);

        let backend_worker = thread::spawn(move || {
            let (mut stream, _) = backend.accept().expect("backend accept");
            let mut payload = [0_u8; 4];
            stream.read_exact(&mut payload).expect("backend read");
            assert_eq!(&payload, b"ping");
            stream.write_all(b"pong").expect("backend write");
        });

        let mapping = [PortForward {
            ingress_port,
            backend_port,
        }];
        let mut runtime = MeshIngressRuntime::start_mapped(Ipv4Addr::LOCALHOST, &mapping, 4)
            .expect("start mapped ingress");
        assert!(runtime.is_healthy());

        let mut client =
            TcpStream::connect((Ipv4Addr::LOCALHOST, ingress_port)).expect("connect ingress");
        client.write_all(b"ping").expect("client write");
        let mut response = [0_u8; 4];
        client.read_exact(&mut response).expect("client read");
        assert_eq!(&response, b"pong");
        drop(client);
        backend_worker.join().expect("backend worker");
        runtime.stop().expect("clean stop");
    }
}
