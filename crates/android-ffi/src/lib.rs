//! Narrow Rust <-> Kotlin / Android composition boundary.
//!
//! Cellular admission remains owned by `mish-cellular`. This boundary also composes the
//! already-approved private loopback Cellular Egress bridge and disposable sing-box config
//! projection without exposing socket, DNS, route-table, root-shell, or vendor JSON mechanics
//! to Android application code.

use mish_cellular::{
    CellularAdmissionReason as OwnerAdmissionReason,
    CellularAdmissionSnapshot as OwnerAdmissionSnapshot,
    CellularAdmissionState as OwnerAdmissionState, CellularEgress, NetworkHandle,
    NetworkObservation, ObservationSequence,
};
use mish_cellular_egress_bridge::{BridgeCredentials, BridgeListener};
use mish_proxy::{ProxyCredentialMaterial, ProxyServingPlan};
use mish_runtime::AndroidCellularOutboundConnector;
use mish_sing_box_adapter::{PrivateSocks5Endpoint, render_product_config};
use std::collections::HashMap;
use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Shutdown, SocketAddr, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

uniffi::setup_scaffolding!();

const MAX_BRIDGE_SESSIONS: usize = 128;
const BRIDGE_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const BRIDGE_OPERATION_TIMEOUT_MAX_MS: u64 = 120_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellularAdmissionState {
    Unknown,
    NotAdmitted,
    Admitted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CellularAdmissionReason {
    NoObservation,
    NotCellular,
    MissingInternetCapability,
    VpnDerivedNetwork,
    NotValidated,
    NetworkLost,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CellularAdmissionView {
    pub state: CellularAdmissionState,
    pub reason: Option<CellularAdmissionReason>,
    pub admitted_network_handle: Option<u64>,
    pub last_sequence: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum CellularBridgeError {
    InvalidObservationSequence,
    InvalidNetworkHandle,
    OwnerUnavailable,
}

impl fmt::Display for CellularBridgeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidObservationSequence => "observation sequence must be non-zero",
            Self::InvalidNetworkHandle => "Android network handle must be non-zero",
            Self::OwnerUnavailable => "Cellular Egress owner state is unavailable",
        })
    }
}

impl std::error::Error for CellularBridgeError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum AndroidRuntimeError {
    InvalidOperationTimeout,
    BridgeAlreadyRunning,
    BridgeConfigurationRejected,
    BridgeBindFailed,
    ConnectorUnavailable,
    ThreadUnavailable,
    BridgeStateUnavailable,
    ShutdownTimedOut,
    InvalidListenAddress,
    ProxyConfigurationRejected,
}

impl fmt::Display for AndroidRuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::InvalidOperationTimeout => {
                "bridge operation timeout is outside the accepted range"
            }
            Self::BridgeAlreadyRunning => {
                "a private bridge already belongs to this owner generation"
            }
            Self::BridgeConfigurationRejected => "private bridge configuration was rejected",
            Self::BridgeBindFailed => "private bridge could not bind loopback",
            Self::ConnectorUnavailable => "cellular outbound connector could not start",
            Self::ThreadUnavailable => "bounded bridge worker thread could not start",
            Self::BridgeStateUnavailable => "private bridge state is unavailable",
            Self::ShutdownTimedOut => {
                "private bridge sessions did not stop within the bounded timeout"
            }
            Self::InvalidListenAddress => "public proxy listen address is invalid",
            Self::ProxyConfigurationRejected => "proxy runtime configuration was rejected",
        })
    }
}

impl std::error::Error for AndroidRuntimeError {}

#[derive(uniffi::Object)]
pub struct CellularController {
    owner: Arc<Mutex<CellularEgress>>,
    bridge_claimed: Arc<AtomicBool>,
}

#[uniffi::export]
impl CellularController {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            owner: Arc::new(Mutex::new(CellularEgress::new())),
            bridge_claimed: Arc::new(AtomicBool::new(false)),
        })
    }

    pub fn admission_snapshot(&self) -> Result<CellularAdmissionView, CellularBridgeError> {
        Ok(map_snapshot(self.owner()?.admission()))
    }

    pub fn observe_network(
        &self,
        sequence: u64,
        network_handle: u64,
        is_cellular: bool,
        has_internet: bool,
        is_validated: bool,
        is_not_vpn: bool,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        let sequence = ObservationSequence::new(sequence)
            .ok_or(CellularBridgeError::InvalidObservationSequence)?;
        let network_handle =
            NetworkHandle::new(network_handle).ok_or(CellularBridgeError::InvalidNetworkHandle)?;
        let observation = NetworkObservation::new(
            sequence,
            network_handle,
            is_cellular,
            has_internet,
            is_validated,
            is_not_vpn,
        );
        let mut owner = self.owner()?;
        owner.observe(observation);
        Ok(map_snapshot(owner.admission()))
    }

    pub fn network_lost(
        &self,
        sequence: u64,
        network_handle: u64,
    ) -> Result<CellularAdmissionView, CellularBridgeError> {
        let sequence = ObservationSequence::new(sequence)
            .ok_or(CellularBridgeError::InvalidObservationSequence)?;
        let network_handle =
            NetworkHandle::new(network_handle).ok_or(CellularBridgeError::InvalidNetworkHandle)?;
        let mut owner = self.owner()?;
        owner.lost(sequence, network_handle);
        Ok(map_snapshot(owner.admission()))
    }

    pub fn start_bridge(
        &self,
        username: String,
        password: String,
        operation_timeout_ms: u64,
    ) -> Result<Arc<CellularBridgeRuntime>, AndroidRuntimeError> {
        CellularBridgeRuntime::start(
            Arc::clone(&self.owner),
            Arc::clone(&self.bridge_claimed),
            username,
            password,
            operation_timeout_ms,
        )
    }
}

impl CellularController {
    fn owner(&self) -> Result<MutexGuard<'_, CellularEgress>, CellularBridgeError> {
        self.owner
            .lock()
            .map_err(|_| CellularBridgeError::OwnerUnavailable)
    }
}

#[derive(uniffi::Object)]
pub struct CellularBridgeRuntime {
    port: u16,
    wake_address: SocketAddr,
    stop_requested: Arc<AtomicBool>,
    healthy: Arc<AtomicBool>,
    active_sessions: Arc<AtomicUsize>,
    clients: Arc<Mutex<HashMap<u64, TcpStream>>>,
    accept_thread: Mutex<Option<JoinHandle<()>>>,
    bridge_claimed: Arc<AtomicBool>,
}

impl CellularBridgeRuntime {
    fn start(
        owner: Arc<Mutex<CellularEgress>>,
        bridge_claimed: Arc<AtomicBool>,
        username: String,
        password: String,
        operation_timeout_ms: u64,
    ) -> Result<Arc<Self>, AndroidRuntimeError> {
        if operation_timeout_ms == 0 || operation_timeout_ms > BRIDGE_OPERATION_TIMEOUT_MAX_MS {
            return Err(AndroidRuntimeError::InvalidOperationTimeout);
        }
        if bridge_claimed
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err(AndroidRuntimeError::BridgeAlreadyRunning);
        }

        let result = (|| {
            let credentials = BridgeCredentials::new(username, password)
                .map_err(|_| AndroidRuntimeError::BridgeConfigurationRejected)?;
            let listener = Arc::new(
                BridgeListener::bind(IpAddr::V4(Ipv4Addr::LOCALHOST), 0, credentials)
                    .map_err(|_| AndroidRuntimeError::BridgeBindFailed)?,
            );
            let wake_address = listener
                .local_addr()
                .map_err(|_| AndroidRuntimeError::BridgeStateUnavailable)?;
            let connector = AndroidCellularOutboundConnector::new(
                owner,
                Duration::from_millis(operation_timeout_ms),
            )
            .map_err(|_| AndroidRuntimeError::ConnectorUnavailable)?;

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
            let accept_connector = connector.clone();

            let accept_thread = thread::Builder::new()
                .name("mish-cellular-bridge-accept".to_owned())
                .spawn(move || {
                    bridge_accept_loop(
                        accept_listener,
                        accept_connector,
                        accept_stop,
                        accept_healthy,
                        accept_active,
                        accept_clients,
                        accept_sequence,
                    )
                })
                .map_err(|_| AndroidRuntimeError::ThreadUnavailable)?;

            Ok(Arc::new(Self {
                port: wake_address.port(),
                wake_address,
                stop_requested,
                healthy,
                active_sessions,
                clients,
                accept_thread: Mutex::new(Some(accept_thread)),
                bridge_claimed: Arc::clone(&bridge_claimed),
            }))
        })();

        if result.is_err() {
            bridge_claimed.store(false, Ordering::Release);
        }
        result
    }

    fn stop_internal(&self) -> Result<(), AndroidRuntimeError> {
        self.stop_requested.store(true, Ordering::Release);
        let _ = TcpStream::connect_timeout(&self.wake_address, Duration::from_millis(200));

        if let Ok(clients) = self.clients.lock() {
            for stream in clients.values() {
                let _ = stream.shutdown(Shutdown::Both);
            }
        } else {
            return Err(AndroidRuntimeError::BridgeStateUnavailable);
        }

        let handle = self
            .accept_thread
            .lock()
            .map_err(|_| AndroidRuntimeError::BridgeStateUnavailable)?
            .take();
        if let Some(handle) = handle {
            handle
                .join()
                .map_err(|_| AndroidRuntimeError::BridgeStateUnavailable)?;
        }

        let deadline = Instant::now() + BRIDGE_SHUTDOWN_TIMEOUT;
        while self.active_sessions.load(Ordering::Acquire) != 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        if self.active_sessions.load(Ordering::Acquire) != 0 {
            return Err(AndroidRuntimeError::ShutdownTimedOut);
        }

        self.clients
            .lock()
            .map_err(|_| AndroidRuntimeError::BridgeStateUnavailable)?
            .clear();
        self.healthy.store(false, Ordering::Release);
        self.bridge_claimed.store(false, Ordering::Release);
        Ok(())
    }
}

#[uniffi::export]
impl CellularBridgeRuntime {
    pub fn port(&self) -> u16 {
        self.port
    }

    pub fn is_healthy(&self) -> bool {
        self.healthy.load(Ordering::Acquire) && !self.stop_requested.load(Ordering::Acquire)
    }

    pub fn active_sessions(&self) -> u32 {
        self.active_sessions
            .load(Ordering::Acquire)
            .min(u32::MAX as usize) as u32
    }

    pub fn stop(&self) -> Result<(), AndroidRuntimeError> {
        self.stop_internal()
    }
}

impl Drop for CellularBridgeRuntime {
    fn drop(&mut self) {
        let _ = self.stop_internal();
    }
}

fn bridge_accept_loop(
    listener: Arc<BridgeListener>,
    connector: AndroidCellularOutboundConnector,
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
            if let Ok(mut tracked_clients) = clients.lock() {
                if let Some(stream) = tracked_clients.remove(&session_id) {
                    let _ = stream.shutdown(Shutdown::Both);
                }
            }
            active_sessions.fetch_sub(1, Ordering::AcqRel);
            healthy.store(false, Ordering::Release);
            stop_requested.store(true, Ordering::Release);
        }
    }
    healthy.store(false, Ordering::Release);
}

#[uniffi::export]
pub fn render_proxy_runtime_config(
    listen_address: String,
    public_username: String,
    public_password: String,
    bridge_port: u16,
    bridge_username: String,
    bridge_password: String,
) -> Result<String, AndroidRuntimeError> {
    let listen_address = listen_address
        .parse::<IpAddr>()
        .map_err(|_| AndroidRuntimeError::InvalidListenAddress)?;
    let public_credentials = ProxyCredentialMaterial::new(public_username, public_password)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let plan = ProxyServingPlan::canonical(listen_address, public_credentials)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    let egress = PrivateSocks5Endpoint::new(
        IpAddr::V4(Ipv4Addr::LOCALHOST),
        bridge_port,
        bridge_username,
        bridge_password,
    )
    .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)?;
    render_product_config(&plan, &egress)
        .map_err(|_| AndroidRuntimeError::ProxyConfigurationRejected)
}

fn map_snapshot(snapshot: OwnerAdmissionSnapshot) -> CellularAdmissionView {
    CellularAdmissionView {
        state: match snapshot.state() {
            OwnerAdmissionState::Unknown => CellularAdmissionState::Unknown,
            OwnerAdmissionState::NotAdmitted => CellularAdmissionState::NotAdmitted,
            OwnerAdmissionState::Admitted => CellularAdmissionState::Admitted,
        },
        reason: snapshot.reason().map(|reason| match reason {
            OwnerAdmissionReason::NoObservation => CellularAdmissionReason::NoObservation,
            OwnerAdmissionReason::NotCellular => CellularAdmissionReason::NotCellular,
            OwnerAdmissionReason::MissingInternetCapability => {
                CellularAdmissionReason::MissingInternetCapability
            }
            OwnerAdmissionReason::VpnDerivedNetwork => CellularAdmissionReason::VpnDerivedNetwork,
            OwnerAdmissionReason::NotValidated => CellularAdmissionReason::NotValidated,
            OwnerAdmissionReason::NetworkLost => CellularAdmissionReason::NetworkLost,
        }),
        admitted_network_handle: snapshot.admitted_network().map(NetworkHandle::raw),
        last_sequence: snapshot.last_sequence().map(ObservationSequence::raw),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn foreign_controller_starts_unknown() {
        let controller = CellularController::new();
        assert_eq!(
            controller.admission_snapshot().expect("snapshot"),
            CellularAdmissionView {
                state: CellularAdmissionState::Unknown,
                reason: Some(CellularAdmissionReason::NoObservation),
                admitted_network_handle: None,
                last_sequence: None,
            }
        );
    }

    #[test]
    fn foreign_observation_delegates_admission_to_natural_owner() {
        let controller = CellularController::new();
        let view = controller
            .observe_network(1, 42, true, true, true, true)
            .expect("valid observation");
        assert_eq!(view.state, CellularAdmissionState::Admitted);
        assert_eq!(view.reason, None);
        assert_eq!(view.admitted_network_handle, Some(42));
        assert_eq!(view.last_sequence, Some(1));
    }

    #[test]
    fn vpn_derived_observation_is_rejected_by_natural_owner() {
        let controller = CellularController::new();
        let view = controller
            .observe_network(1, 42, true, true, true, false)
            .expect("valid observation");
        assert_eq!(view.state, CellularAdmissionState::NotAdmitted);
        assert_eq!(
            view.reason,
            Some(CellularAdmissionReason::VpnDerivedNetwork)
        );
        assert_eq!(view.admitted_network_handle, None);
    }

    #[test]
    fn foreign_loss_fails_closed_through_natural_owner() {
        let controller = CellularController::new();
        controller
            .observe_network(1, 42, true, true, true, true)
            .expect("valid observation");
        let view = controller.network_lost(2, 42).expect("valid loss event");
        assert_eq!(view.state, CellularAdmissionState::NotAdmitted);
        assert_eq!(view.reason, Some(CellularAdmissionReason::NetworkLost));
        assert_eq!(view.admitted_network_handle, None);
        assert_eq!(view.last_sequence, Some(2));
    }

    #[test]
    fn zero_foreign_values_are_rejected_before_owner_mutation() {
        let controller = CellularController::new();
        assert_eq!(
            controller.observe_network(0, 42, true, true, true, true),
            Err(CellularBridgeError::InvalidObservationSequence)
        );
        assert_eq!(
            controller.observe_network(1, 0, true, true, true, true),
            Err(CellularBridgeError::InvalidNetworkHandle)
        );
        assert_eq!(
            controller.admission_snapshot().expect("snapshot").state,
            CellularAdmissionState::Unknown
        );
    }

    #[test]
    fn one_owner_allows_only_one_private_bridge_and_releases_claim_on_stop() {
        let controller = CellularController::new();
        let bridge = controller
            .start_bridge("private-user".into(), "private-secret".into(), 1_000)
            .expect("start bridge");
        assert!(bridge.port() > 0);
        assert!(bridge.is_healthy());
        assert!(matches!(
            controller.start_bridge("other".into(), "secret".into(), 1_000),
            Err(AndroidRuntimeError::BridgeAlreadyRunning)
        ));
        bridge.stop().expect("bounded stop");
        assert!(!bridge.is_healthy());

        let replacement = controller
            .start_bridge("replacement".into(), "secret".into(), 1_000)
            .expect("restart after exact stop");
        replacement.stop().expect("stop replacement");
    }

    #[test]
    fn rendered_proxy_runtime_is_loopback_only_and_has_no_direct_fallback() {
        let rendered = render_proxy_runtime_config(
            "127.0.0.1".into(),
            "public-user".into(),
            "public-secret".into(),
            19080,
            "private-user".into(),
            "private-secret".into(),
        )
        .expect("render proxy runtime");
        for port in [1080, 1081, 3128] {
            assert!(rendered.contains(&format!("\"listen_port\": {port}")));
        }
        assert!(rendered.contains("\"listen\": \"127.0.0.1\""));
        assert!(!rendered.contains("\"type\": \"direct\""));
        assert!(matches!(
            render_proxy_runtime_config(
                "0.0.0.0".into(),
                "public-user".into(),
                "public-secret".into(),
                19080,
                "private-user".into(),
                "private-secret".into(),
            ),
            Err(AndroidRuntimeError::ProxyConfigurationRejected)
        ));
    }
}
