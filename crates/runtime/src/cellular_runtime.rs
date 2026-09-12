//! Vendor-neutral Cellular Egress runtime coordination.
//!
//! This module composes one `mish-cellular` natural-owner instance, one bounded root-policy
//! effect gate, and one private loopback bridge generation. It owns runtime coordination only;
//! cellular admission/currentness remains owned by `CellularEgress` and DNS execution is injected
//! through the `CellularDnsResolver` port.

use crate::{CellularDnsResolver, CellularOutboundRuntimeConnector};
use mish_cellular::{
    CellularAdmissionSnapshot, CellularAdmissionState, CellularEgress, NetworkHandle,
    NetworkObservation, ObservationSequence,
};
use mish_cellular_egress_bridge::{
    BridgeCredentials, BridgeListener, CellularOutboundConnector, ConnectTarget,
    OutboundConnectError,
};
use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const MAX_BRIDGE_SESSIONS: usize = 128;
const BRIDGE_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const BRIDGE_OPERATION_TIMEOUT_MAX_MS: u64 = 120_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularRuntimeError {
    InvalidOperationTimeout,
    BridgeAlreadyRunning,
    BridgeConfigurationRejected,
    BridgeBindFailed,
    ConnectorUnavailable,
    ThreadUnavailable,
    StateUnavailable,
    ShutdownTimedOut,
}

pub struct CellularRuntimeCoordinator {
    owner: Arc<Mutex<CellularEgress>>,
    bridge_claimed: Arc<AtomicBool>,
    root_policy_effect_gate: Arc<RootPolicyEffectGate>,
    resolver: Arc<dyn CellularDnsResolver>,
}

impl CellularRuntimeCoordinator {
    pub fn new(resolver: Arc<dyn CellularDnsResolver>) -> Arc<Self> {
        Arc::new(Self {
            owner: Arc::new(Mutex::new(CellularEgress::new())),
            bridge_claimed: Arc::new(AtomicBool::new(false)),
            root_policy_effect_gate: Arc::new(RootPolicyEffectGate::default()),
            resolver,
        })
    }

    pub fn admission_snapshot(&self) -> Result<CellularAdmissionSnapshot, CellularRuntimeError> {
        Ok(self.owner()?.admission())
    }

    pub fn observe_network(
        &self,
        observation: NetworkObservation,
    ) -> Result<CellularAdmissionSnapshot, CellularRuntimeError> {
        let mut owner = self.owner()?;
        if !self.root_policy_effect_gate.set_ready(false) {
            return Err(CellularRuntimeError::StateUnavailable);
        }
        owner.observe(observation);
        Ok(owner.admission())
    }

    pub fn network_lost(
        &self,
        sequence: ObservationSequence,
        network_handle: NetworkHandle,
    ) -> Result<CellularAdmissionSnapshot, CellularRuntimeError> {
        let mut owner = self.owner()?;
        if !self.root_policy_effect_gate.set_ready(false) {
            return Err(CellularRuntimeError::StateUnavailable);
        }
        owner.lost(sequence, network_handle);
        Ok(owner.admission())
    }

    pub fn close_root_policy_gate(&self) -> Result<(), CellularRuntimeError> {
        self.root_policy_effect_gate
            .set_ready(false)
            .then_some(())
            .ok_or(CellularRuntimeError::StateUnavailable)
    }

    pub fn await_root_policy_quiesced(
        &self,
        timeout: Duration,
    ) -> Result<bool, CellularRuntimeError> {
        if timeout.is_zero() || timeout.as_millis() > u128::from(BRIDGE_OPERATION_TIMEOUT_MAX_MS) {
            return Err(CellularRuntimeError::InvalidOperationTimeout);
        }
        self.root_policy_effect_gate
            .wait_quiesced(timeout)
            .ok_or(CellularRuntimeError::StateUnavailable)
    }

    pub fn authorize_root_policy(
        &self,
        sequence: ObservationSequence,
        network_handle: NetworkHandle,
    ) -> Result<bool, CellularRuntimeError> {
        let owner = self.owner()?;
        let snapshot = owner.admission();
        let current = snapshot.state() == CellularAdmissionState::Admitted
            && snapshot.last_sequence() == Some(sequence)
            && snapshot.admitted_network() == Some(network_handle);
        if !current {
            if !self.root_policy_effect_gate.set_ready(false) {
                return Err(CellularRuntimeError::StateUnavailable);
            }
            return Ok(false);
        }
        if !self.root_policy_effect_gate.set_ready(true) {
            return Err(CellularRuntimeError::StateUnavailable);
        }
        Ok(true)
    }

    pub fn start_private_bridge(
        &self,
        username: String,
        password: String,
        operation_timeout: Duration,
    ) -> Result<Arc<CellularPrivateBridgeRuntime>, CellularRuntimeError> {
        if operation_timeout.is_zero()
            || operation_timeout.as_millis() > u128::from(BRIDGE_OPERATION_TIMEOUT_MAX_MS)
        {
            return Err(CellularRuntimeError::InvalidOperationTimeout);
        }
        if self
            .bridge_claimed
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(CellularRuntimeError::BridgeAlreadyRunning);
        }

        let result = CellularPrivateBridgeRuntime::start(
            Arc::clone(&self.owner),
            Arc::clone(&self.bridge_claimed),
            Arc::clone(&self.root_policy_effect_gate),
            Arc::clone(&self.resolver),
            username,
            password,
            operation_timeout,
        );
        if result.is_err() {
            self.bridge_claimed.store(false, Ordering::Release);
        }
        result
    }

    fn owner(&self) -> Result<MutexGuard<'_, CellularEgress>, CellularRuntimeError> {
        self.owner
            .lock()
            .map_err(|_| CellularRuntimeError::StateUnavailable)
    }
}

#[derive(Default)]
struct RootPolicyEffectGate {
    state: Mutex<RootPolicyEffectGateState>,
    quiesced: Condvar,
}

#[derive(Default)]
struct RootPolicyEffectGateState {
    ready: bool,
    in_flight: usize,
}

impl RootPolicyEffectGate {
    fn set_ready(&self, ready: bool) -> bool {
        let Ok(mut state) = self.state.lock() else {
            return false;
        };
        state.ready = ready;
        if !ready && state.in_flight == 0 {
            self.quiesced.notify_all();
        }
        true
    }

    fn acquire(self: &Arc<Self>) -> Option<RootPolicyEffectPermit> {
        let mut state = self.state.lock().ok()?;
        if !state.ready {
            return None;
        }
        state.in_flight = state.in_flight.checked_add(1)?;
        drop(state);
        Some(RootPolicyEffectPermit {
            gate: Arc::clone(self),
        })
    }

    fn wait_quiesced(&self, timeout: Duration) -> Option<bool> {
        let state = self.state.lock().ok()?;
        let (state, _) = self
            .quiesced
            .wait_timeout_while(state, timeout, |state| state.in_flight != 0)
            .ok()?;
        Some(state.in_flight == 0)
    }
}

struct RootPolicyEffectPermit {
    gate: Arc<RootPolicyEffectGate>,
}

impl Drop for RootPolicyEffectPermit {
    fn drop(&mut self) {
        if let Ok(mut state) = self.gate.state.lock() {
            if state.in_flight == 0 {
                return;
            }
            state.in_flight -= 1;
            if state.in_flight == 0 {
                self.gate.quiesced.notify_all();
            }
        }
    }
}

#[derive(Clone)]
struct RootPolicyGatedConnector {
    inner: CellularOutboundRuntimeConnector,
    effect_gate: Arc<RootPolicyEffectGate>,
}

impl CellularOutboundConnector for RootPolicyGatedConnector {
    fn connect(&self, target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
        let _permit = self
            .effect_gate
            .acquire()
            .ok_or(OutboundConnectError::Unavailable)?;
        self.inner.connect(target)
    }
}

pub struct CellularPrivateBridgeRuntime {
    port: u16,
    wake_address: SocketAddr,
    stop_requested: Arc<AtomicBool>,
    healthy: Arc<AtomicBool>,
    active_sessions: Arc<AtomicUsize>,
    clients: Arc<Mutex<HashMap<u64, TcpStream>>>,
    accept_thread: Mutex<Option<JoinHandle<()>>>,
    bridge_claimed: Arc<AtomicBool>,
    claim_released: AtomicBool,
}

impl CellularPrivateBridgeRuntime {
    #[allow(clippy::too_many_arguments)]
    fn start(
        owner: Arc<Mutex<CellularEgress>>,
        bridge_claimed: Arc<AtomicBool>,
        root_policy_effect_gate: Arc<RootPolicyEffectGate>,
        resolver: Arc<dyn CellularDnsResolver>,
        username: String,
        password: String,
        operation_timeout: Duration,
    ) -> Result<Arc<Self>, CellularRuntimeError> {
        let credentials = BridgeCredentials::new(username, password)
            .map_err(|_| CellularRuntimeError::BridgeConfigurationRejected)?;
        let listener = Arc::new(
            BridgeListener::bind(IpAddr::V4(Ipv4Addr::LOCALHOST), 0, credentials)
                .map_err(|_| CellularRuntimeError::BridgeBindFailed)?,
        );
        let wake_address = listener
            .local_addr()
            .map_err(|_| CellularRuntimeError::StateUnavailable)?;
        let inner = CellularOutboundRuntimeConnector::new(owner, operation_timeout, resolver)
            .map_err(|_| CellularRuntimeError::ConnectorUnavailable)?;
        let connector = RootPolicyGatedConnector {
            inner,
            effect_gate: root_policy_effect_gate,
        };

        let stop_requested = Arc::new(AtomicBool::new(false));
        let healthy = Arc::new(AtomicBool::new(true));
        let active_sessions = Arc::new(AtomicUsize::new(0));
        let clients = Arc::new(Mutex::new(HashMap::new()));
        let session_sequence = Arc::new(AtomicU64::new(1));

        let accept_listener = Arc::clone(&listener);
        let accept_stop = Arc::clone(&stop_requested);
        let accept_healthy = Arc::clone(&healthy);
        let accept_active = Arc::clone(&active_sessions);
        let accept_clients = Arc::clone(&clients);
        let accept_sequence = Arc::clone(&session_sequence);
        let accept_thread = thread::Builder::new()
            .name("mish-cellular-bridge-accept".to_owned())
            .spawn(move || {
                bridge_accept_loop(
                    accept_listener,
                    connector,
                    accept_stop,
                    accept_healthy,
                    accept_active,
                    accept_clients,
                    accept_sequence,
                )
            })
            .map_err(|_| CellularRuntimeError::ThreadUnavailable)?;

        Ok(Arc::new(Self {
            port: wake_address.port(),
            wake_address,
            stop_requested,
            healthy,
            active_sessions,
            clients,
            accept_thread: Mutex::new(Some(accept_thread)),
            bridge_claimed,
            claim_released: AtomicBool::new(false),
        }))
    }

    pub const fn port(&self) -> u16 {
        self.port
    }

    pub fn is_healthy(&self) -> bool {
        self.healthy.load(Ordering::Acquire) && !self.stop_requested.load(Ordering::Acquire)
    }

    pub fn active_sessions(&self) -> usize {
        self.active_sessions.load(Ordering::Acquire)
    }

    pub fn stop(&self) -> Result<(), CellularRuntimeError> {
        self.stop_internal()
    }

    fn stop_internal(&self) -> Result<(), CellularRuntimeError> {
        self.stop_requested.store(true, Ordering::Release);
        let _ = TcpStream::connect_timeout(&self.wake_address, Duration::from_millis(200));

        if let Ok(clients) = self.clients.lock() {
            for stream in clients.values() {
                let _ = stream.shutdown(Shutdown::Both);
            }
        } else {
            return Err(CellularRuntimeError::StateUnavailable);
        }

        let handle = self
            .accept_thread
            .lock()
            .map_err(|_| CellularRuntimeError::StateUnavailable)?
            .take();
        if let Some(handle) = handle {
            handle
                .join()
                .map_err(|_| CellularRuntimeError::StateUnavailable)?;
        }

        let deadline = Instant::now() + BRIDGE_SHUTDOWN_TIMEOUT;
        while self.active_sessions.load(Ordering::Acquire) != 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        if self.active_sessions.load(Ordering::Acquire) != 0 {
            return Err(CellularRuntimeError::ShutdownTimedOut);
        }

        self.clients
            .lock()
            .map_err(|_| CellularRuntimeError::StateUnavailable)?
            .clear();
        self.healthy.store(false, Ordering::Release);
        if self
            .claim_released
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
        {
            self.bridge_claimed.store(false, Ordering::Release);
        }
        Ok(())
    }
}

impl Drop for CellularPrivateBridgeRuntime {
    fn drop(&mut self) {
        let _ = self.stop_internal();
    }
}

fn bridge_accept_loop(
    listener: Arc<BridgeListener>,
    connector: RootPolicyGatedConnector,
    stop_requested: Arc<AtomicBool>,
    healthy: Arc<AtomicBool>,
    active_sessions: Arc<AtomicUsize>,
    clients: Arc<Mutex<HashMap<u64, TcpStream>>>,
    session_sequence: Arc<AtomicU64>,
) {
    while !stop_requested.load(Ordering::Acquire) {
        let (client, _) = match listener.accept() {
            Ok(pair) => pair,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                healthy.store(false, Ordering::Release);
                break;
            }
        };
        if stop_requested.load(Ordering::Acquire) {
            let _ = client.shutdown(Shutdown::Both);
            break;
        }

        if active_sessions
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
                (current < MAX_BRIDGE_SESSIONS).then_some(current + 1)
            })
            .is_err()
        {
            let _ = client.shutdown(Shutdown::Both);
            continue;
        }

        let tracked = match client.try_clone() {
            Ok(stream) => stream,
            Err(_) => {
                active_sessions.fetch_sub(1, Ordering::AcqRel);
                healthy.store(false, Ordering::Release);
                stop_requested.store(true, Ordering::Release);
                continue;
            }
        };
        let session_id = session_sequence.fetch_add(1, Ordering::AcqRel);
        if let Ok(mut tracked_clients) = clients.lock() {
            tracked_clients.insert(session_id, tracked);
        } else {
            active_sessions.fetch_sub(1, Ordering::AcqRel);
            healthy.store(false, Ordering::Release);
            stop_requested.store(true, Ordering::Release);
            let _ = client.shutdown(Shutdown::Both);
            continue;
        }

        let session_listener = Arc::clone(&listener);
        let session_connector = connector.clone();
        let session_clients = Arc::clone(&clients);
        let session_active = Arc::clone(&active_sessions);
        let spawn = thread::Builder::new()
            .name(format!("mish-cellular-bridge-{session_id}"))
            .spawn(move || {
                let _ = session_listener.serve_session(client, &session_connector);
                if let Ok(mut tracked_clients) = session_clients.lock() {
                    tracked_clients.remove(&session_id);
                }
                session_active.fetch_sub(1, Ordering::AcqRel);
            });
        if spawn.is_err() {
            if let Ok(mut tracked_clients) = clients.lock()
                && let Some(stream) = tracked_clients.remove(&session_id)
            {
                let _ = stream.shutdown(Shutdown::Both);
            }
            active_sessions.fetch_sub(1, Ordering::AcqRel);
            healthy.store(false, Ordering::Release);
            stop_requested.store(true, Ordering::Release);
        }
    }
    healthy.store(false, Ordering::Release);
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular::{CellularAdmissionReason, NetworkObservation};
    use std::net::Ipv4Addr;

    fn sequence(raw: u64) -> ObservationSequence {
        ObservationSequence::new(raw).expect("sequence")
    }

    fn handle(raw: u64) -> NetworkHandle {
        NetworkHandle::new(raw).expect("handle")
    }

    fn coordinator() -> Arc<CellularRuntimeCoordinator> {
        CellularRuntimeCoordinator::new(Arc::new(|_, _| {
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        }))
    }

    #[test]
    fn admission_and_loss_delegate_to_one_cellular_owner() {
        let runtime = coordinator();
        let admitted = runtime
            .observe_network(NetworkObservation::new(
                sequence(1),
                handle(42),
                true,
                true,
                true,
                true,
            ))
            .expect("observe");
        assert_eq!(admitted.state(), CellularAdmissionState::Admitted);
        let lost = runtime.network_lost(sequence(2), handle(42)).expect("loss");
        assert_eq!(lost.state(), CellularAdmissionState::NotAdmitted);
        assert_eq!(lost.reason(), Some(CellularAdmissionReason::NetworkLost));
    }

    #[test]
    fn root_policy_gate_is_default_closed_and_generation_checked() {
        let runtime = coordinator();
        runtime
            .observe_network(NetworkObservation::new(
                sequence(1),
                handle(42),
                true,
                true,
                true,
                true,
            ))
            .expect("observe");
        assert!(
            runtime
                .authorize_root_policy(sequence(1), handle(42))
                .expect("authorize")
        );
        runtime.network_lost(sequence(2), handle(42)).expect("loss");
        assert!(
            !runtime
                .authorize_root_policy(sequence(1), handle(42))
                .expect("stale")
        );
    }

    #[test]
    fn one_owner_generation_allows_only_one_private_bridge() {
        let runtime = coordinator();
        let first = runtime
            .start_private_bridge(
                "first-user".into(),
                "first-secret".into(),
                Duration::from_secs(1),
            )
            .expect("first bridge");
        assert!(first.port() > 0);
        assert_eq!(
            runtime
                .start_private_bridge(
                    "second-user".into(),
                    "second-secret".into(),
                    Duration::from_secs(1),
                )
                .err(),
            Some(CellularRuntimeError::BridgeAlreadyRunning)
        );
        first.stop().expect("stop");
        let replacement = runtime
            .start_private_bridge(
                "replacement-user".into(),
                "replacement-secret".into(),
                Duration::from_secs(1),
            )
            .expect("replacement");
        replacement.stop().expect("stop replacement");
    }
}
