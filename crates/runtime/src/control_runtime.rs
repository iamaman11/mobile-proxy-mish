//! MISH-initiated authenticated remote-control transport on the one PRODUCT Tokio runtime.
//!
//! This coordinator owns only the outbound control-session lifecycle, reconnect budget and
//! correlation of one remote ROTATE_IP request to the existing Rotation owner. It never mutates
//! Android radio state itself, never retries a rotation until the IP changes, and never creates a
//! second network/executor/lifecycle owner.

use crate::control_transport::{ControlTransport, ControlTransportError, ControlTransportMessage};
use crate::{
    CellularRequestRearmEffect, RotationRuntimeCoordinator, RotationRuntimeStartError,
    RotationRuntimeTimingSnapshot, RuntimeExecutionError, RuntimeExecutor,
};
use mish_configuration::ControlEndpoint;
use mish_control::{
    ControlDeviceIdentity, RemoteRotationResult, ServerControlMessage, canonical_auth_payload,
    encode_accepted_message, encode_auth_message, encode_result_message,
    p256_der_signature_to_p1363_b64url, parse_server_message,
};
use mish_rotation::{RotationSnapshot, RotationTerminalResult};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::{Duration, Instant};
use tokio::sync::{Notify, watch};
use tokio::task::JoinHandle;
use tokio::time::{MissedTickBehavior, interval, sleep, timeout};

// A reconnect attempt must never monopolize the public 18 s manager budget. CONTROL retries
// continuously, so small per-attempt bounds are both safer and faster across the intentional
// cellular outage caused by Rotation.
const CONTROL_CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const CONTROL_AUTH_TIMEOUT: Duration = Duration::from_secs(3);
const CONTROL_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const CONTROL_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(4);
const CONTROL_HEARTBEAT_REQUEST: &str = "MISH_CONTROL_HEARTBEAT_V1";
const CONTROL_HEARTBEAT_RESPONSE: &str = "MISH_CONTROL_HEARTBEAT_ACK_V1";
const CONTROL_RECONNECT_DELAYS_MS: [u64; 5] = [500, 1_000, 2_000, 3_000, 5_000];
const CONTROL_RECENT_TERMINAL_REQUESTS: usize = 32;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlSessionState {
    Stopped,
    Connecting,
    Authenticating,
    Ready,
    Backoff,
}

/// Read-only monotonic timing evidence for one remote command correlated to one Rotation id.
///
/// The origin is receipt of the first ROTATE_IP command for this request. The record lives inside
/// the already-bounded pending/recent correlation ledger and never drives reconnect or mutation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ControlOperationTimingSnapshot {
    pub operation_id: Option<u64>,
    pub operation_age_ms: Option<u64>,
    pub operation_reserved_ms: Option<u64>,
    pub accepted_sent_ms: Option<u64>,
    pub reconnect_started_ms: Option<u64>,
    pub reconnect_ready_ms: Option<u64>,
    pub rotation_terminal_control_state: Option<ControlSessionState>,
    pub post_terminal_connect_started_ms: Option<u64>,
    pub post_terminal_connect_attempts: u32,
    pub post_terminal_transport_connected_ms: Option<u64>,
    pub post_terminal_transport_connections: u32,
    pub rotation_terminal_ms: Option<u64>,
    pub result_sent_ms: Option<u64>,
    pub result_ack_ms: Option<u64>,
    pub rotation_origin_from_command_ms: Option<u64>,
}

#[derive(Debug, Clone)]
struct ControlOperationTiming {
    origin: Instant,
    snapshot: ControlOperationTimingSnapshot,
}

impl ControlOperationTiming {
    fn new(operation_id: u64, origin: Instant) -> Self {
        let mut timing = Self {
            origin,
            snapshot: ControlOperationTimingSnapshot {
                operation_id: Some(operation_id),
                ..ControlOperationTimingSnapshot::default()
            },
        };
        let _ = timing.mark(operation_id, |snapshot, elapsed_ms| {
            set_timing_once(&mut snapshot.operation_reserved_ms, elapsed_ms);
        });
        timing
    }

    fn snapshot_at(
        &self,
        now: Instant,
        rotation: RotationRuntimeTimingSnapshot,
    ) -> ControlOperationTimingSnapshot {
        let mut snapshot = self.snapshot;
        snapshot.operation_age_ms = Some(elapsed_ms_since(now, self.origin));
        if snapshot.operation_id == rotation.operation_id {
            snapshot.rotation_origin_from_command_ms = snapshot
                .operation_age_ms
                .zip(rotation.operation_age_ms)
                .and_then(|(command_age, rotation_age)| command_age.checked_sub(rotation_age));
        }
        snapshot
    }

    fn mark<F>(&mut self, operation_id: u64, mark: F) -> bool
    where
        F: FnOnce(&mut ControlOperationTimingSnapshot, u64),
    {
        if self.snapshot.operation_id != Some(operation_id) {
            return false;
        }
        let elapsed_ms = elapsed_ms_since(Instant::now(), self.origin);
        mark(&mut self.snapshot, elapsed_ms);
        true
    }
}

fn set_timing_once(slot: &mut Option<u64>, elapsed_ms: u64) {
    if slot.is_none() {
        *slot = Some(elapsed_ms);
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControlRuntimeSnapshot {
    pub state: ControlSessionState,
    pub reconnect_attempts: u32,
    pub reconnect_count: u64,
    pub next_delay_ms: u64,
    pub session_age_ms: Option<u64>,
    pub application_heartbeat_count: u64,
    pub payload_tx_bytes: u64,
    pub payload_rx_bytes: u64,
    pub last_tx_age_ms: Option<u64>,
    pub last_rx_age_ms: Option<u64>,
    pub pending_operation: bool,
    pub pending_operation_id: Option<u64>,
    pub last_terminal_result: Option<RemoteRotationResult>,
    pub operation_timing: ControlOperationTimingSnapshot,
    pub rotation_timing: RotationRuntimeTimingSnapshot,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlRuntimeStartError {
    AlreadyStarted,
    InvalidIdentity,
    ExecutorUnavailable,
    StateUnavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlAuthSignError {
    KeystoreUnavailable,
    SignFailed,
}

/// Narrow platform signing effect. Android Keystore retains the non-exportable private key;
/// Rust owns the canonical bytes and wire/auth policy.
pub trait ControlAuthSigner: Send + Sync + 'static {
    fn sign_control_auth(&self, payload: &[u8]) -> Result<Vec<u8>, ControlAuthSignError>;
}

#[derive(Debug, Clone)]
struct PendingRemoteOperation {
    request_id: String,
    operation_id: Option<u64>,
    result: Option<RemoteRotationResult>,
    timing: ControlOperationTiming,
}

struct ControlState {
    session_state: ControlSessionState,
    reconnect_attempts: u32,
    reconnect_count: u64,
    next_delay_ms: u64,
    session_ready_at: Option<Instant>,
    application_heartbeat_count: u64,
    payload_tx_bytes: u64,
    payload_rx_bytes: u64,
    last_tx_at: Option<Instant>,
    last_rx_at: Option<Instant>,
    pending: Option<PendingRemoteOperation>,
    recent_terminal: VecDeque<PendingRemoteOperation>,
    last_terminal_result: Option<RemoteRotationResult>,
    device_id: Option<String>,
    task: Option<JoinHandle<()>>,
    cancel: Option<watch::Sender<bool>>,
    closed: bool,
}

pub struct ControlRuntimeCoordinator {
    executor: Arc<RuntimeExecutor>,
    rotation: Arc<RotationRuntimeCoordinator>,
    endpoint: ControlEndpoint,
    result_changed: Arc<Notify>,
    state: Mutex<ControlState>,
}

impl ControlRuntimeCoordinator {
    pub fn new(
        executor: Arc<RuntimeExecutor>,
        rotation: Arc<RotationRuntimeCoordinator>,
    ) -> Result<Arc<Self>, RuntimeExecutionError> {
        let endpoint =
            ControlEndpoint::deployment().map_err(|_| RuntimeExecutionError::StateUnavailable)?;
        let coordinator = Arc::new(Self {
            executor,
            rotation: Arc::clone(&rotation),
            endpoint,
            result_changed: Arc::new(Notify::new()),
            state: Mutex::new(ControlState {
                session_state: ControlSessionState::Stopped,
                reconnect_attempts: 0,
                reconnect_count: 0,
                next_delay_ms: CONTROL_RECONNECT_DELAYS_MS[0],
                session_ready_at: None,
                application_heartbeat_count: 0,
                payload_tx_bytes: 0,
                payload_rx_bytes: 0,
                last_tx_at: None,
                last_rx_at: None,
                pending: None,
                recent_terminal: VecDeque::new(),
                last_terminal_result: None,
                device_id: None,
                task: None,
                cancel: None,
                closed: false,
            }),
        });

        let weak: Weak<Self> = Arc::downgrade(&coordinator);
        rotation.add_internal_observer(Arc::new(move |snapshot| {
            if let Some(coordinator) = weak.upgrade() {
                coordinator.observe_rotation(snapshot);
            }
        }));
        Ok(coordinator)
    }

    pub fn snapshot(&self) -> ControlRuntimeSnapshot {
        let now = Instant::now();
        // Tokio Instant and std Instant share the same monotonic clock; convert explicitly
        // so both owner snapshots are sampled against one observation instant.
        let rotation_timing = self.rotation.timing_snapshot_at(now.into());
        self.state()
            .map(|state| {
                let operation_timing = state
                    .pending
                    .as_ref()
                    .or_else(|| state.recent_terminal.front())
                    .map(|operation| operation.timing.snapshot_at(now, rotation_timing))
                    .unwrap_or_default();
                ControlRuntimeSnapshot {
                    state: state.session_state,
                    reconnect_attempts: state.reconnect_attempts,
                    reconnect_count: state.reconnect_count,
                    next_delay_ms: state.next_delay_ms,
                    session_age_ms: state.session_ready_at.map(|at| elapsed_ms_since(now, at)),
                    application_heartbeat_count: state.application_heartbeat_count,
                    payload_tx_bytes: state.payload_tx_bytes,
                    payload_rx_bytes: state.payload_rx_bytes,
                    last_tx_age_ms: state.last_tx_at.map(|at| elapsed_ms_since(now, at)),
                    last_rx_age_ms: state.last_rx_at.map(|at| elapsed_ms_since(now, at)),
                    pending_operation: state.pending.is_some(),
                    pending_operation_id: state
                        .pending
                        .as_ref()
                        .and_then(|pending| pending.operation_id),
                    last_terminal_result: state.last_terminal_result,
                    operation_timing,
                    rotation_timing,
                }
            })
            .unwrap_or(ControlRuntimeSnapshot {
                state: ControlSessionState::Stopped,
                reconnect_attempts: 0,
                reconnect_count: 0,
                next_delay_ms: CONTROL_RECONNECT_DELAYS_MS[0],
                session_age_ms: None,
                application_heartbeat_count: 0,
                payload_tx_bytes: 0,
                payload_rx_bytes: 0,
                last_tx_age_ms: None,
                last_rx_age_ms: None,
                pending_operation: false,
                pending_operation_id: None,
                last_terminal_result: None,
                operation_timing: ControlOperationTimingSnapshot::default(),
                rotation_timing,
            })
    }

    pub fn start(
        self: &Arc<Self>,
        public_key_spki: Vec<u8>,
        signer: Arc<dyn ControlAuthSigner>,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
    ) -> Result<String, ControlRuntimeStartError> {
        let identity = ControlDeviceIdentity::from_public_key_spki(public_key_spki)
            .map_err(|_| ControlRuntimeStartError::InvalidIdentity)?;

        let cancel_rx = {
            let mut state = self
                .state_mut()
                .map_err(|_| ControlRuntimeStartError::StateUnavailable)?;
            if state.closed {
                return Err(ControlRuntimeStartError::StateUnavailable);
            }
            if state.task.as_ref().is_some_and(|task| !task.is_finished()) {
                if state.device_id.as_deref() == Some(identity.device_id()) {
                    return Ok(identity.device_id().to_owned());
                }
                return Err(ControlRuntimeStartError::AlreadyStarted);
            }
            let (cancel_tx, cancel_rx) = watch::channel(false);
            state.cancel = Some(cancel_tx);
            state.device_id = Some(identity.device_id().to_owned());
            state.session_state = ControlSessionState::Connecting;
            state.reconnect_attempts = 0;
            state.reconnect_count = 0;
            state.next_delay_ms = CONTROL_RECONNECT_DELAYS_MS[0];
            state.session_ready_at = None;
            state.application_heartbeat_count = 0;
            state.payload_tx_bytes = 0;
            state.payload_rx_bytes = 0;
            state.last_tx_at = None;
            state.last_rx_at = None;
            cancel_rx
        };

        let owner = Arc::clone(self);
        let device_id = identity.device_id().to_owned();
        let task = self
            .executor
            .spawn(async move {
                owner
                    .run_loop(identity, signer, cellular_request_rearm, cancel_rx)
                    .await;
            })
            .map_err(|_| ControlRuntimeStartError::ExecutorUnavailable)?;

        let mut state = self
            .state_mut()
            .map_err(|_| ControlRuntimeStartError::StateUnavailable)?;
        state.task = Some(task);
        Ok(device_id)
    }

    pub async fn shutdown(self: &Arc<Self>) -> bool {
        let (cancel, task) = {
            let Ok(mut state) = self.state.lock() else {
                return false;
            };
            if state.closed {
                return true;
            }
            state.closed = true;
            state.session_state = ControlSessionState::Stopped;
            state.pending = None;
            (state.cancel.take(), state.task.take())
        };

        if let Some(cancel) = cancel {
            let _ = cancel.send(true);
        }
        self.result_changed.notify_one();

        let Some(mut task) = task else {
            return true;
        };
        if timeout(CONTROL_SHUTDOWN_TIMEOUT, &mut task).await.is_ok() {
            true
        } else {
            task.abort();
            let _ = task.await;
            false
        }
    }

    async fn run_loop(
        self: Arc<Self>,
        identity: ControlDeviceIdentity,
        signer: Arc<dyn ControlAuthSigner>,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
        mut cancel: watch::Receiver<bool>,
    ) {
        let mut failures = 0_u32;
        loop {
            if *cancel.borrow() || self.is_closed() {
                break;
            }
            self.publish_connection_state(ControlSessionState::Connecting, failures, 0);
            self.record_post_terminal_connect_attempt();

            let result = self
                .connect_and_run(
                    &identity,
                    Arc::clone(&signer),
                    Arc::clone(&cellular_request_rearm),
                    &mut cancel,
                )
                .await;
            if matches!(result, Err(ControlRunError::Cancelled)) {
                break;
            }
            if *cancel.borrow() || self.is_closed() {
                break;
            }

            let last_session_state = self
                .state()
                .map(|state| state.session_state)
                .unwrap_or(ControlSessionState::Connecting);
            failures = next_reconnect_failure_count(failures, last_session_state);
            let delay_ms = reconnect_delay_ms(failures);
            self.record_reconnect();
            self.publish_connection_state(ControlSessionState::Backoff, failures, delay_ms);
            tokio::select! {
                changed = cancel.changed() => {
                    if changed.is_err() || *cancel.borrow() {
                        break;
                    }
                }
                // Rotation terminal is a concrete owner event after the intentional radio outage.
                // Do not spend the remaining public response budget sleeping on a backoff that was
                // accumulated while the network was intentionally unavailable. The same CONTROL
                // task immediately retries; if that retry still fails, the normal bounded sequence
                // restarts at 500 ms. No Rotation retry or second scheduler is introduced.
                _ = self.result_changed.notified() => {
                    failures = 0;
                }
                _ = sleep(Duration::from_millis(delay_ms)) => {}
            }
        }
        self.publish_connection_state(
            ControlSessionState::Stopped,
            0,
            CONTROL_RECONNECT_DELAYS_MS[0],
        );
    }

    async fn connect_and_run(
        self: &Arc<Self>,
        identity: &ControlDeviceIdentity,
        signer: Arc<dyn ControlAuthSigner>,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
        cancel: &mut watch::Receiver<bool>,
    ) -> Result<(), ControlRunError> {
        let mut transport = tokio::select! {
            changed = cancel.changed() => {
                if changed.is_err() || *cancel.borrow() {
                    return Err(ControlRunError::Cancelled);
                }
                return Err(ControlRunError::Transport);
            }
            result = ControlTransport::connect(
                self.endpoint.hostname(),
                self.endpoint.port(),
                self.endpoint.path(),
                identity.device_id(),
                CONTROL_CONNECT_TIMEOUT,
            ) => result.map_err(ControlRunError::from)?,
        };
        self.record_post_terminal_transport_connected();

        self.publish_connection_state(ControlSessionState::Authenticating, 0, 0);
        self.authenticate(&mut transport, identity, signer).await?;
        self.publish_connection_state(ControlSessionState::Ready, 0, 0);
        self.send_pending_result_if_terminal(&mut transport).await?;

        // Session liveness belongs to this existing native control task. A tiny application-level
        // heartbeat rides the already-open WSS; Cloudflare auto-responds while the Durable Object
        // remains hibernated. If one complete 4 s interval passes without its ACK, the session is
        // stale and this same owner returns to the existing reconnect loop.
        let mut heartbeat = interval(CONTROL_HEARTBEAT_INTERVAL);
        heartbeat.set_missed_tick_behavior(MissedTickBehavior::Delay);
        heartbeat.tick().await;
        let mut heartbeat_outstanding = false;

        loop {
            if *cancel.borrow() {
                return Err(ControlRunError::Cancelled);
            }
            tokio::select! {
                changed = cancel.changed() => {
                    if changed.is_err() || *cancel.borrow() {
                        return Err(ControlRunError::Cancelled);
                    }
                }
                _ = self.result_changed.notified() => {
                    self.send_pending_result_if_terminal(&mut transport).await?;
                }
                _ = heartbeat.tick() => {
                    if heartbeat_outstanding {
                        return Err(ControlRunError::Transport);
                    }
                    self.write_text_observed(&mut transport, CONTROL_HEARTBEAT_REQUEST).await?;
                    heartbeat_outstanding = true;
                }
                message = self.read_message_observed(&mut transport) => {
                    match message? {
                        ControlTransportMessage::Text(text)
                            if text == CONTROL_HEARTBEAT_RESPONSE =>
                        {
                            heartbeat_outstanding = false;
                            self.record_heartbeat();
                        }
                        ControlTransportMessage::Text(text) => {
                            self.handle_server_message(
                                &mut transport,
                                &text,
                                Arc::clone(&cellular_request_rearm),
                            ).await?;
                        }
                        ControlTransportMessage::Closed => return Err(ControlRunError::Transport),
                    }
                }
            }
        }
    }

    async fn authenticate(
        &self,
        transport: &mut ControlTransport,
        identity: &ControlDeviceIdentity,
        signer: Arc<dyn ControlAuthSigner>,
    ) -> Result<(), ControlRunError> {
        let challenge = timeout(CONTROL_AUTH_TIMEOUT, self.read_message_observed(transport))
            .await
            .map_err(|_| ControlRunError::Authentication)??;
        let nonce = match challenge {
            ControlTransportMessage::Text(text) => {
                match parse_server_message(&text).map_err(|_| ControlRunError::Protocol)? {
                    ServerControlMessage::Challenge { nonce } => nonce,
                    _ => return Err(ControlRunError::Protocol),
                }
            }
            ControlTransportMessage::Closed => return Err(ControlRunError::Transport),
        };

        let payload = canonical_auth_payload(identity.device_id(), &nonce)
            .map_err(|_| ControlRunError::Protocol)?;
        let signature_der = signer
            .sign_control_auth(&payload)
            .map_err(|_| ControlRunError::Authentication)?;
        let signature = p256_der_signature_to_p1363_b64url(&signature_der)
            .map_err(|_| ControlRunError::Authentication)?;
        let auth = encode_auth_message(identity.device_id(), &signature)
            .map_err(|_| ControlRunError::Protocol)?;
        self.write_text_observed(transport, &auth).await?;

        let ready = timeout(CONTROL_AUTH_TIMEOUT, self.read_message_observed(transport))
            .await
            .map_err(|_| ControlRunError::Authentication)??;
        match ready {
            ControlTransportMessage::Text(text)
                if matches!(parse_server_message(&text), Ok(ServerControlMessage::Ready)) =>
            {
                Ok(())
            }
            _ => Err(ControlRunError::Authentication),
        }
    }

    async fn handle_server_message(
        self: &Arc<Self>,
        transport: &mut ControlTransport,
        text: &str,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
    ) -> Result<(), ControlRunError> {
        match parse_server_message(text).map_err(|_| ControlRunError::Protocol)? {
            ServerControlMessage::RotateIp { request_id } => {
                self.handle_rotate_ip(transport, request_id, cellular_request_rearm)
                    .await
            }
            ServerControlMessage::ResultAck { request_id } => {
                self.ack_result(&request_id);
                Ok(())
            }
            ServerControlMessage::Challenge { .. } | ServerControlMessage::Ready => {
                Err(ControlRunError::Protocol)
            }
        }
    }

    async fn handle_rotate_ip(
        self: &Arc<Self>,
        transport: &mut ControlTransport,
        request_id: String,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
    ) -> Result<(), ControlRunError> {
        let command_received_at = Instant::now();
        let (active, recent) = self
            .state()
            .map(|state| {
                (
                    state.pending.clone(),
                    state
                        .recent_terminal
                        .iter()
                        .find(|item| item.request_id == request_id)
                        .cloned(),
                )
            })
            .map_err(|_| ControlRunError::State)?;

        if let Some(existing) = active {
            if existing.request_id == request_id {
                self.send_known_operation(transport, &existing).await?;
                return Ok(());
            }
            let rejected = encode_result_message(&request_id, RemoteRotationResult::Rejected, None)
                .map_err(|_| ControlRunError::Protocol)?;
            self.write_text_observed(transport, &rejected).await?;
            return Ok(());
        }

        if let Some(existing) = recent {
            self.send_known_operation(transport, &existing).await?;
            return Ok(());
        }

        // Reserve an operation id only after PRODUCT preconditions have passed. prepare() owns
        // no timer/network/radio effect, so a rejected/busy request cannot mutate Cellular.
        let operation_id = match self.rotation.prepare(Arc::clone(&cellular_request_rearm)) {
            Ok(operation_id) => operation_id,
            Err(error) => {
                let result = map_rotation_start_error(error);
                let rejected = encode_result_message(&request_id, result, None)
                    .map_err(|_| ControlRunError::Protocol)?;
                self.write_text_observed(transport, &rejected).await?;
                if let Ok(mut state) = self.state.lock() {
                    state.last_terminal_result = Some(result);
                }
                return Ok(());
            }
        };

        {
            let mut state = self.state_mut().map_err(|_| ControlRunError::State)?;
            if state.pending.is_some() {
                self.rotation.fail_prepared_before_mutation(operation_id);
                return Err(ControlRunError::State);
            }
            state.pending = Some(PendingRemoteOperation {
                request_id: request_id.clone(),
                operation_id: Some(operation_id),
                result: None,
                timing: ControlOperationTiming::new(operation_id, command_received_at),
            });
        }

        // Acceptance is externally visible before the existing Rotation owner may start even the
        // first public-IP probe. A failed write aborts the prepared operation without mutation.
        let accepted = encode_accepted_message(&request_id, operation_id)
            .map_err(|_| ControlRunError::Protocol)?;
        if let Err(error) = self.write_text_observed(transport, &accepted).await {
            self.rotation.fail_prepared_before_mutation(operation_id);
            if let Ok(mut state) = self.state.lock() {
                mark_acceptance_delivery_failed(&mut state, &request_id, operation_id);
            }
            return Err(error);
        }
        self.mark_pending_timing(operation_id, |timing, elapsed_ms| {
            set_timing_once(&mut timing.accepted_sent_ms, elapsed_ms);
        });

        if let Err(error) = self.rotation.activate_prepared(operation_id) {
            self.rotation.fail_prepared_before_mutation(operation_id);
            let result = map_rotation_start_error(error);
            if let Ok(mut state) = self.state.lock()
                && let Some(pending) = state.pending.as_mut()
                && pending.request_id == request_id
            {
                pending.result = Some(result);
                state.last_terminal_result = Some(result);
            }
            self.result_changed.notify_one();
        }
        Ok(())
    }

    async fn send_known_operation(
        &self,
        transport: &mut ControlTransport,
        operation: &PendingRemoteOperation,
    ) -> Result<(), ControlRunError> {
        let Some(operation_id) = operation.operation_id else {
            return Err(ControlRunError::State);
        };
        let accepted = encode_accepted_message(&operation.request_id, operation_id)
            .map_err(|_| ControlRunError::Protocol)?;
        self.write_text_observed(transport, &accepted).await?;
        self.mark_pending_timing(operation_id, |timing, elapsed_ms| {
            set_timing_once(&mut timing.accepted_sent_ms, elapsed_ms);
        });
        if let Some(result) = operation.result {
            let message = encode_result_message(&operation.request_id, result, Some(operation_id))
                .map_err(|_| ControlRunError::Protocol)?;
            self.write_text_observed(transport, &message).await?;
            self.mark_pending_timing(operation_id, |timing, elapsed_ms| {
                set_timing_once(&mut timing.result_sent_ms, elapsed_ms);
            });
        }
        Ok(())
    }

    async fn send_pending_result_if_terminal(
        &self,
        transport: &mut ControlTransport,
    ) -> Result<(), ControlRunError> {
        let pending = self.state().ok().and_then(|state| state.pending.clone());
        let Some(pending) = pending else {
            return Ok(());
        };
        let Some(result) = pending.result else {
            return Ok(());
        };
        let message = encode_result_message(&pending.request_id, result, pending.operation_id)
            .map_err(|_| ControlRunError::Protocol)?;
        self.write_text_observed(transport, &message).await?;
        if let Some(operation_id) = pending.operation_id {
            self.mark_pending_timing(operation_id, |timing, elapsed_ms| {
                set_timing_once(&mut timing.result_sent_ms, elapsed_ms);
            });
        }
        Ok(())
    }

    fn ack_result(&self, request_id: &str) {
        if let Ok(mut state) = self.state.lock()
            && state.pending.as_ref().is_some_and(|pending| {
                pending.request_id == request_id
                    && pending.operation_id.is_some()
                    && pending.result.is_some()
            })
            && let Some(mut completed) = state.pending.take()
        {
            if let Some(operation_id) = completed.operation_id {
                let _ = completed.timing.mark(operation_id, |timing, elapsed_ms| {
                    set_timing_once(&mut timing.result_ack_ms, elapsed_ms);
                });
            }
            state
                .recent_terminal
                .retain(|item| item.request_id != request_id);
            state.recent_terminal.push_front(completed);
            while state.recent_terminal.len() > CONTROL_RECENT_TERMINAL_REQUESTS {
                state.recent_terminal.pop_back();
            }
        }
    }

    fn observe_rotation(&self, snapshot: RotationSnapshot) {
        let Some(operation_id) = snapshot.operation_id else {
            return;
        };
        let Some(terminal) = snapshot.terminal_result else {
            return;
        };
        let result = match terminal {
            RotationTerminalResult::Changed => RemoteRotationResult::Changed,
            RotationTerminalResult::Unchanged => RemoteRotationResult::Unchanged,
            RotationTerminalResult::Failed => RemoteRotationResult::Failed,
        };
        let changed = if let Ok(mut state) = self.state.lock() {
            let terminal_control_state = state.session_state;
            if let Some(pending) = state.pending.as_mut()
                && pending.operation_id == Some(operation_id)
                && pending.result.is_none()
            {
                pending.result = Some(result);
                if let Some(operation_id) = pending.operation_id {
                    let _ = pending.timing.mark(operation_id, |timing, elapsed_ms| {
                        set_timing_once(&mut timing.rotation_terminal_ms, elapsed_ms);
                        if timing.rotation_terminal_control_state.is_none() {
                            timing.rotation_terminal_control_state = Some(terminal_control_state);
                        }
                    });
                }
                state.last_terminal_result = Some(result);
                true
            } else {
                false
            }
        } else {
            false
        };
        if changed {
            self.result_changed.notify_one();
        }
    }

    async fn write_text_observed(
        &self,
        transport: &mut ControlTransport,
        text: &str,
    ) -> Result<(), ControlRunError> {
        transport.write_text(text).await?;
        if let Ok(mut state) = self.state.lock() {
            state.payload_tx_bytes = state.payload_tx_bytes.saturating_add(text.len() as u64);
            state.last_tx_at = Some(Instant::now());
        }
        Ok(())
    }

    async fn read_message_observed(
        &self,
        transport: &mut ControlTransport,
    ) -> Result<ControlTransportMessage, ControlRunError> {
        let message = transport.read_message().await?;
        if let ControlTransportMessage::Text(text) = &message
            && let Ok(mut state) = self.state.lock()
        {
            state.payload_rx_bytes = state.payload_rx_bytes.saturating_add(text.len() as u64);
            state.last_rx_at = Some(Instant::now());
        }
        Ok(message)
    }

    fn record_heartbeat(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.application_heartbeat_count = state.application_heartbeat_count.saturating_add(1);
        }
    }

    fn record_reconnect(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.reconnect_count = state.reconnect_count.saturating_add(1);
            if let Some(pending) = state.pending.as_mut()
                && let Some(operation_id) = pending.operation_id
            {
                let _ = pending.timing.mark(operation_id, |timing, elapsed_ms| {
                    set_timing_once(&mut timing.reconnect_started_ms, elapsed_ms);
                });
            }
        }
    }

    fn record_post_terminal_connect_attempt(&self) {
        if let Ok(mut state) = self.state.lock()
            && let Some(pending) = state.pending.as_mut()
            && pending.result.is_some()
            && let Some(operation_id) = pending.operation_id
        {
            let _ = pending.timing.mark(operation_id, |timing, elapsed_ms| {
                set_timing_once(&mut timing.post_terminal_connect_started_ms, elapsed_ms);
                timing.post_terminal_connect_attempts =
                    timing.post_terminal_connect_attempts.saturating_add(1);
            });
        }
    }

    fn record_post_terminal_transport_connected(&self) {
        if let Ok(mut state) = self.state.lock()
            && let Some(pending) = state.pending.as_mut()
            && pending.result.is_some()
            && let Some(operation_id) = pending.operation_id
        {
            let _ = pending.timing.mark(operation_id, |timing, elapsed_ms| {
                set_timing_once(
                    &mut timing.post_terminal_transport_connected_ms,
                    elapsed_ms,
                );
                timing.post_terminal_transport_connections = timing
                    .post_terminal_transport_connections
                    .saturating_add(1);
            });
        }
    }

    fn publish_connection_state(
        &self,
        session_state: ControlSessionState,
        reconnect_attempts: u32,
        next_delay_ms: u64,
    ) {
        if let Ok(mut state) = self.state.lock() {
            if state.closed && session_state != ControlSessionState::Stopped {
                return;
            }
            if session_state == ControlSessionState::Ready
                && state.session_state != ControlSessionState::Ready
            {
                state.session_ready_at = Some(Instant::now());
                if let Some(pending) = state.pending.as_mut()
                    && let Some(operation_id) = pending.operation_id
                    && pending.timing.snapshot.reconnect_started_ms.is_some()
                {
                    let _ = pending.timing.mark(operation_id, |timing, elapsed_ms| {
                        set_timing_once(&mut timing.reconnect_ready_ms, elapsed_ms);
                    });
                }
            } else if session_state != ControlSessionState::Ready {
                state.session_ready_at = None;
            }
            state.session_state = session_state;
            state.reconnect_attempts = reconnect_attempts;
            state.next_delay_ms = next_delay_ms;
        }
    }

    fn mark_pending_timing<F>(&self, operation_id: u64, mark: F)
    where
        F: FnOnce(&mut ControlOperationTimingSnapshot, u64),
    {
        if let Ok(mut state) = self.state.lock()
            && let Some(pending) = state.pending.as_mut()
            && pending.operation_id == Some(operation_id)
        {
            let _ = pending.timing.mark(operation_id, mark);
        }
    }

    fn is_closed(&self) -> bool {
        self.state().map(|state| state.closed).unwrap_or(true)
    }

    fn state(&self) -> Result<MutexGuard<'_, ControlState>, ()> {
        self.state.lock().map_err(|_| ())
    }

    fn state_mut(&self) -> Result<MutexGuard<'_, ControlState>, ()> {
        self.state()
    }
}

fn elapsed_ms_since(now: Instant, then: Instant) -> u64 {
    u64::try_from(now.saturating_duration_since(then).as_millis()).unwrap_or(u64::MAX)
}

fn mark_acceptance_delivery_failed(
    state: &mut ControlState,
    request_id: &str,
    operation_id: u64,
) -> bool {
    let Some(pending) = state.pending.as_mut() else {
        return false;
    };
    if pending.request_id != request_id
        || pending.operation_id != Some(operation_id)
        || pending.result.is_some()
    {
        return false;
    }

    pending.result = Some(RemoteRotationResult::Rejected);
    state.last_terminal_result = Some(RemoteRotationResult::Rejected);
    true
}

fn next_reconnect_failure_count(
    previous_failures: u32,
    last_session_state: ControlSessionState,
) -> u32 {
    if last_session_state == ControlSessionState::Ready {
        1
    } else {
        previous_failures.saturating_add(1)
    }
}

fn reconnect_delay_ms(failures: u32) -> u64 {
    let index = usize::try_from(failures.saturating_sub(1))
        .unwrap_or(usize::MAX)
        .min(CONTROL_RECONNECT_DELAYS_MS.len() - 1);
    CONTROL_RECONNECT_DELAYS_MS[index]
}

const fn map_rotation_start_error(_error: RotationRuntimeStartError) -> RemoteRotationResult {
    RemoteRotationResult::Rejected
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ControlRunError {
    Cancelled,
    Transport,
    Authentication,
    Protocol,
    State,
}

impl From<ControlTransportError> for ControlRunError {
    fn from(error: ControlTransportError) -> Self {
        match error {
            ControlTransportError::Protocol => Self::Protocol,
            ControlTransportError::Network
            | ControlTransportError::Tls
            | ControlTransportError::WebSocket => Self::Transport,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_accepted_delivery_keeps_terminal_correlation_for_reconnect() {
        let mut state = ControlState {
            session_state: ControlSessionState::Ready,
            reconnect_attempts: 0,
            reconnect_count: 0,
            next_delay_ms: 0,
            session_ready_at: Some(Instant::now()),
            application_heartbeat_count: 0,
            payload_tx_bytes: 0,
            payload_rx_bytes: 0,
            last_tx_at: None,
            last_rx_at: None,
            pending: Some(PendingRemoteOperation {
                request_id: "req_1".to_owned(),
                operation_id: Some(7),
                result: None,
                timing: ControlOperationTiming::new(7, Instant::now()),
            }),
            recent_terminal: VecDeque::new(),
            last_terminal_result: None,
            device_id: None,
            task: None,
            cancel: None,
            closed: false,
        };

        assert!(mark_acceptance_delivery_failed(&mut state, "req_1", 7));
        let pending = state.pending.as_ref().expect("pending correlation");
        assert_eq!(pending.operation_id, Some(7));
        assert_eq!(pending.result, Some(RemoteRotationResult::Rejected));
        assert_eq!(
            state.last_terminal_result,
            Some(RemoteRotationResult::Rejected)
        );
    }

    #[test]
    fn operation_timing_is_bounded_and_rejects_stale_operation_updates() {
        let origin = Instant::now();
        let mut timing = ControlOperationTiming::new(7, origin);
        assert!(!timing.mark(8, |snapshot, elapsed_ms| {
            snapshot.accepted_sent_ms = Some(elapsed_ms);
        }));
        assert!(timing.snapshot.accepted_sent_ms.is_none());

        assert!(timing.mark(7, |snapshot, elapsed_ms| {
            set_timing_once(&mut snapshot.accepted_sent_ms, elapsed_ms);
        }));
        assert!(timing.snapshot.accepted_sent_ms.is_some());
        assert_eq!(timing.snapshot.operation_id, Some(7));
    }

    #[test]
    fn control_liveness_is_owned_by_the_existing_native_session_task() {
        assert_eq!(CONTROL_HEARTBEAT_INTERVAL, Duration::from_secs(4));
        assert_eq!(CONTROL_HEARTBEAT_REQUEST, "MISH_CONTROL_HEARTBEAT_V1");
        assert_eq!(CONTROL_HEARTBEAT_RESPONSE, "MISH_CONTROL_HEARTBEAT_ACK_V1");
    }

    #[test]
    fn reconnect_failure_count_resets_after_ready_session() {
        assert_eq!(
            next_reconnect_failure_count(4, ControlSessionState::Ready),
            1
        );
        assert_eq!(
            next_reconnect_failure_count(4, ControlSessionState::Connecting),
            5
        );
        assert_eq!(
            next_reconnect_failure_count(u32::MAX, ControlSessionState::Authenticating),
            u32::MAX
        );
    }

    #[test]
    fn reconnect_backoff_is_bounded() {
        assert_eq!(reconnect_delay_ms(1), 500);
        assert_eq!(reconnect_delay_ms(2), 1_000);
        assert_eq!(reconnect_delay_ms(3), 2_000);
        assert_eq!(reconnect_delay_ms(4), 3_000);
        assert_eq!(reconnect_delay_ms(5), 5_000);
        assert_eq!(reconnect_delay_ms(u32::MAX), 5_000);
    }

    #[test]
    fn every_rotation_start_error_maps_to_rejected_without_retrying_mutation() {
        for error in [
            RotationRuntimeStartError::RuntimeNotRunning,
            RotationRuntimeStartError::AlreadyInProgress,
            RotationRuntimeStartError::NoCurrentCellular,
            RotationRuntimeStartError::RootPolicyUnavailable,
            RotationRuntimeStartError::CredentialUnavailable,
            RotationRuntimeStartError::ExecutorUnavailable,
            RotationRuntimeStartError::StateUnavailable,
        ] {
            assert_eq!(
                map_rotation_start_error(error),
                RemoteRotationResult::Rejected
            );
        }
    }
}
