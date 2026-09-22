//! MISH-initiated authenticated remote-control transport on the one PRODUCT Tokio runtime.
//!
//! This coordinator owns only the outbound control-session lifecycle, reconnect budget and
//! correlation of one remote ROTATE_IP request to the existing Rotation owner. It never mutates
//! Android radio state itself, never retries a rotation until the IP changes, and never creates a
//! second network/executor/lifecycle owner.

use crate::tls_client::ProductTlsClient;
use crate::{
    CellularRequestRearmEffect, CellularRuntimeCoordinator, RotationRuntimeCoordinator,
    RotationRuntimeStartError, RuntimeExecutionError, RuntimeExecutor,
};
use mish_configuration::ControlEndpoint;
use mish_control::{
    ControlDeviceIdentity, RemoteRotationResult, ServerControlMessage, canonical_auth_payload,
    encode_accepted_message, encode_auth_message, encode_result_message, parse_server_message,
    p256_der_signature_to_p1363_b64url, websocket_client_key, websocket_expected_accept,
    websocket_masking_key, CONTROL_WIRE_MAX_BYTES,
};
use mish_proxy::ProxyConnectTarget;
use mish_rotation::{RotationSnapshot, RotationTerminalResult};
use std::io;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{Notify, watch};
use tokio::task::JoinHandle;
use tokio::time::{Instant, sleep, timeout};
use tokio_rustls::client::TlsStream;

const CONTROL_CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const CONTROL_AUTH_TIMEOUT: Duration = Duration::from_secs(10);
const CONTROL_HEARTBEAT_INTERVAL: Duration = Duration::from_secs(300);
const CONTROL_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);
const CONTROL_HTTP_HEADER_MAX_BYTES: usize = 8_192;
const CONTROL_RECONNECT_DELAYS_MS: [u64; 5] = [1_000, 5_000, 15_000, 30_000, 60_000];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ControlSessionState {
    Stopped,
    Connecting,
    Authenticating,
    Ready,
    Backoff,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ControlRuntimeSnapshot {
    pub state: ControlSessionState,
    pub reconnect_attempts: u32,
    pub next_delay_ms: u64,
    pub pending_operation: bool,
    pub pending_operation_id: Option<u64>,
    pub last_terminal_result: Option<RemoteRotationResult>,
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
}

struct ControlState {
    session_state: ControlSessionState,
    reconnect_attempts: u32,
    next_delay_ms: u64,
    pending: Option<PendingRemoteOperation>,
    last_terminal_result: Option<RemoteRotationResult>,
    device_id: Option<String>,
    task: Option<JoinHandle<()>>,
    cancel: Option<watch::Sender<bool>>,
    closed: bool,
}

pub struct ControlRuntimeCoordinator {
    executor: Arc<RuntimeExecutor>,
    cellular: Arc<CellularRuntimeCoordinator>,
    rotation: Arc<RotationRuntimeCoordinator>,
    endpoint: ControlEndpoint,
    result_changed: Arc<Notify>,
    state: Mutex<ControlState>,
}

impl ControlRuntimeCoordinator {
    pub fn new(
        executor: Arc<RuntimeExecutor>,
        cellular: Arc<CellularRuntimeCoordinator>,
        rotation: Arc<RotationRuntimeCoordinator>,
    ) -> Result<Arc<Self>, RuntimeExecutionError> {
        let endpoint =
            ControlEndpoint::deployment().map_err(|_| RuntimeExecutionError::StateUnavailable)?;
        let coordinator = Arc::new(Self {
            executor,
            cellular,
            rotation: Arc::clone(&rotation),
            endpoint,
            result_changed: Arc::new(Notify::new()),
            state: Mutex::new(ControlState {
                session_state: ControlSessionState::Stopped,
                reconnect_attempts: 0,
                next_delay_ms: CONTROL_RECONNECT_DELAYS_MS[0],
                pending: None,
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
        self.state()
            .map(|state| ControlRuntimeSnapshot {
                state: state.session_state,
                reconnect_attempts: state.reconnect_attempts,
                next_delay_ms: state.next_delay_ms,
                pending_operation: state.pending.is_some(),
                pending_operation_id: state.pending.as_ref().and_then(|pending| pending.operation_id),
                last_terminal_result: state.last_terminal_result,
            })
            .unwrap_or(ControlRuntimeSnapshot {
                state: ControlSessionState::Stopped,
                reconnect_attempts: 0,
                next_delay_ms: CONTROL_RECONNECT_DELAYS_MS[0],
                pending_operation: false,
                pending_operation_id: None,
                last_terminal_result: None,
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
            state.next_delay_ms = CONTROL_RECONNECT_DELAYS_MS[0];
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
        self.result_changed.notify_waiters();

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

            failures = failures.saturating_add(1);
            let delay_ms = reconnect_delay_ms(failures);
            self.publish_connection_state(ControlSessionState::Backoff, failures, delay_ms);
            tokio::select! {
                changed = cancel.changed() => {
                    if changed.is_err() || *cancel.borrow() {
                        break;
                    }
                }
                _ = sleep(Duration::from_millis(delay_ms)) => {}
            }
        }
        self.publish_connection_state(ControlSessionState::Stopped, 0, CONTROL_RECONNECT_DELAYS_MS[0]);
    }

    async fn connect_and_run(
        self: &Arc<Self>,
        identity: &ControlDeviceIdentity,
        signer: Arc<dyn ControlAuthSigner>,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
        cancel: &mut watch::Receiver<bool>,
    ) -> Result<(), ControlRunError> {
        let connector = self
            .cellular
            .outbound_connector(CONTROL_CONNECT_TIMEOUT)
            .map_err(|_| ControlRunError::Network)?;
        let target = ProxyConnectTarget::domain(self.endpoint.hostname(), self.endpoint.port())
            .map_err(|_| ControlRunError::Network)?;
        let socket = tokio::task::spawn_blocking(move || connector.connect(&target))
            .await
            .map_err(|_| ControlRunError::Network)?
            .map_err(|_| ControlRunError::Network)?;
        socket
            .set_nonblocking(true)
            .map_err(|_| ControlRunError::Network)?;
        let tcp = TcpStream::from_std(socket).map_err(|_| ControlRunError::Network)?;

        let tls = ProductTlsClient::new().map_err(|_| ControlRunError::Tls)?;
        let tls_stream = tokio::select! {
            changed = cancel.changed() => {
                if changed.is_err() || *cancel.borrow() {
                    return Err(ControlRunError::Cancelled);
                }
                return Err(ControlRunError::Network);
            }
            result = tls.connect(tcp, self.endpoint.hostname(), CONTROL_CONNECT_TIMEOUT) => {
                result.map_err(|_| ControlRunError::Tls)?
            }
        };

        let mut websocket = ControlWebSocket::connect(
            tls_stream,
            self.endpoint.hostname(),
            self.endpoint.path(),
            identity.device_id(),
        )
        .await?;

        self.publish_connection_state(ControlSessionState::Authenticating, 0, 0);
        self.authenticate(&mut websocket, identity, signer).await?;
        self.publish_connection_state(ControlSessionState::Ready, 0, 0);
        self.send_pending_result_if_terminal(&mut websocket).await?;

        loop {
            if *cancel.borrow() {
                return Err(ControlRunError::Cancelled);
            }
            let heartbeat = sleep(CONTROL_HEARTBEAT_INTERVAL);
            tokio::pin!(heartbeat);
            tokio::select! {
                changed = cancel.changed() => {
                    if changed.is_err() || *cancel.borrow() {
                        return Err(ControlRunError::Cancelled);
                    }
                }
                _ = self.result_changed.notified() => {
                    self.send_pending_result_if_terminal(&mut websocket).await?;
                }
                _ = &mut heartbeat => {
                    websocket.write_text("PING").await?;
                }
                message = websocket.read_message() => {
                    match message? {
                        WebSocketMessage::Text(text) if text == "PONG" => {}
                        WebSocketMessage::Text(text) => {
                            self.handle_server_message(
                                &mut websocket,
                                &text,
                                Arc::clone(&cellular_request_rearm),
                            ).await?;
                        }
                        WebSocketMessage::Close => return Err(ControlRunError::WebSocket),
                    }
                }
            }
        }
    }

    async fn authenticate(
        &self,
        websocket: &mut ControlWebSocket,
        identity: &ControlDeviceIdentity,
        signer: Arc<dyn ControlAuthSigner>,
    ) -> Result<(), ControlRunError> {
        let challenge = timeout(CONTROL_AUTH_TIMEOUT, websocket.read_message())
            .await
            .map_err(|_| ControlRunError::Authentication)??;
        let nonce = match challenge {
            WebSocketMessage::Text(text) => match parse_server_message(&text)
                .map_err(|_| ControlRunError::Protocol)?
            {
                ServerControlMessage::Challenge { nonce } => nonce,
                _ => return Err(ControlRunError::Protocol),
            },
            WebSocketMessage::Close => return Err(ControlRunError::WebSocket),
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
        websocket.write_text(&auth).await?;

        let ready = timeout(CONTROL_AUTH_TIMEOUT, websocket.read_message())
            .await
            .map_err(|_| ControlRunError::Authentication)??;
        match ready {
            WebSocketMessage::Text(text)
                if matches!(
                    parse_server_message(&text),
                    Ok(ServerControlMessage::Ready)
                ) =>
            {
                Ok(())
            }
            _ => Err(ControlRunError::Authentication),
        }
    }

    async fn handle_server_message(
        self: &Arc<Self>,
        websocket: &mut ControlWebSocket,
        text: &str,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
    ) -> Result<(), ControlRunError> {
        match parse_server_message(text).map_err(|_| ControlRunError::Protocol)? {
            ServerControlMessage::RotateIp { request_id } => {
                self.handle_rotate_ip(websocket, request_id, cellular_request_rearm)
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
        websocket: &mut ControlWebSocket,
        request_id: String,
        cellular_request_rearm: Arc<dyn CellularRequestRearmEffect>,
    ) -> Result<(), ControlRunError> {
        let existing = self
            .state()
            .ok()
            .and_then(|state| state.pending.clone());

        if let Some(existing) = existing {
            if existing.request_id == request_id {
                let accepted =
                    encode_accepted_message(&request_id).map_err(|_| ControlRunError::Protocol)?;
                websocket.write_text(&accepted).await?;
                if let Some(result) = existing.result {
                    let message = encode_result_message(
                        &request_id,
                        result,
                        existing.operation_id,
                    )
                    .map_err(|_| ControlRunError::Protocol)?;
                    websocket.write_text(&message).await?;
                }
                return Ok(());
            }
            let rejected = encode_result_message(
                &request_id,
                RemoteRotationResult::Rejected,
                None,
            )
            .map_err(|_| ControlRunError::Protocol)?;
            websocket.write_text(&rejected).await?;
            return Ok(());
        }

        // The server receives ACCEPTED before PRODUCT starts the mutation. If the control
        // transport breaks after this flush, the same request_id is never auto-redelivered.
        let accepted =
            encode_accepted_message(&request_id).map_err(|_| ControlRunError::Protocol)?;
        websocket.write_text(&accepted).await?;

        {
            let mut state = self.state_mut().map_err(|_| ControlRunError::State)?;
            if state.pending.is_some() {
                return Err(ControlRunError::State);
            }
            state.pending = Some(PendingRemoteOperation {
                request_id: request_id.clone(),
                operation_id: None,
                result: None,
            });
        }

        match self.rotation.start(cellular_request_rearm) {
            Ok(operation_id) => {
                if let Ok(mut state) = self.state.lock()
                    && let Some(pending) = state.pending.as_mut()
                    && pending.request_id == request_id
                {
                    pending.operation_id = Some(operation_id);
                }
            }
            Err(error) => {
                let result = map_rotation_start_error(error);
                if let Ok(mut state) = self.state.lock()
                    && let Some(pending) = state.pending.as_mut()
                    && pending.request_id == request_id
                {
                    pending.result = Some(result);
                    state.last_terminal_result = Some(result);
                }
                self.result_changed.notify_waiters();
            }
        }
        Ok(())
    }

    async fn send_pending_result_if_terminal(
        &self,
        websocket: &mut ControlWebSocket,
    ) -> Result<(), ControlRunError> {
        let pending = self.state().ok().and_then(|state| state.pending.clone());
        let Some(pending) = pending else {
            return Ok(());
        };
        let Some(result) = pending.result else {
            return Ok(());
        };
        let message =
            encode_result_message(&pending.request_id, result, pending.operation_id)
                .map_err(|_| ControlRunError::Protocol)?;
        websocket.write_text(&message).await
    }

    fn ack_result(&self, request_id: &str) {
        if let Ok(mut state) = self.state.lock()
            && state.pending.as_ref().is_some_and(|pending| {
                pending.request_id == request_id && pending.result.is_some()
            })
        {
            state.pending = None;
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
        let changed = if let Ok(mut state) = self.state.lock()
            && let Some(pending) = state.pending.as_mut()
            && pending.operation_id == Some(operation_id)
            && pending.result.is_none()
        {
            pending.result = Some(result);
            state.last_terminal_result = Some(result);
            true
        } else {
            false
        };
        if changed {
            self.result_changed.notify_waiters();
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
            state.session_state = session_state;
            state.reconnect_attempts = reconnect_attempts;
            state.next_delay_ms = next_delay_ms;
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
    Network,
    Tls,
    WebSocket,
    Authentication,
    Protocol,
    State,
}

impl From<io::Error> for ControlRunError {
    fn from(_error: io::Error) -> Self {
        Self::WebSocket
    }
}

type ControlTlsStream = TlsStream<TcpStream>;

struct ControlWebSocket {
    stream: ControlTlsStream,
}

enum WebSocketMessage {
    Text(String),
    Close,
}

impl ControlWebSocket {
    async fn connect(
        mut stream: ControlTlsStream,
        host: &str,
        path: &str,
        device_id: &str,
    ) -> Result<Self, ControlRunError> {
        let client_key = websocket_client_key().map_err(|_| ControlRunError::WebSocket)?;
        let expected_accept =
            websocket_expected_accept(&client_key).map_err(|_| ControlRunError::WebSocket)?;
        let request = format!(
            "GET {path}?device_id={device_id} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {client_key}\r\nSec-WebSocket-Version: 13\r\nUser-Agent: mobile-proxy-mish-control/1\r\n\r\n"
        );
        timeout(CONTROL_CONNECT_TIMEOUT, stream.write_all(request.as_bytes()))
            .await
            .map_err(|_| ControlRunError::WebSocket)??;
        timeout(CONTROL_CONNECT_TIMEOUT, stream.flush())
            .await
            .map_err(|_| ControlRunError::WebSocket)??;

        let deadline = Instant::now() + CONTROL_CONNECT_TIMEOUT;
        let mut header = Vec::with_capacity(512);
        while !header.ends_with(b"\r\n\r\n") {
            if header.len() >= CONTROL_HTTP_HEADER_MAX_BYTES {
                return Err(ControlRunError::WebSocket);
            }
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                return Err(ControlRunError::WebSocket);
            }
            let mut byte = [0_u8; 1];
            timeout(remaining, stream.read_exact(&mut byte))
                .await
                .map_err(|_| ControlRunError::WebSocket)??;
            header.push(byte[0]);
        }
        validate_upgrade_response(&header, &expected_accept)?;
        Ok(Self { stream })
    }

    async fn write_text(&mut self, text: &str) -> Result<(), ControlRunError> {
        if text.len() > CONTROL_WIRE_MAX_BYTES {
            return Err(ControlRunError::Protocol);
        }
        self.write_frame(0x1, text.as_bytes()).await
    }

    async fn read_message(&mut self) -> Result<WebSocketMessage, ControlRunError> {
        loop {
            let mut fixed = [0_u8; 2];
            self.stream.read_exact(&mut fixed).await?;
            let fin = fixed[0] & 0x80 != 0;
            let opcode = fixed[0] & 0x0f;
            let masked = fixed[1] & 0x80 != 0;
            if !fin || masked {
                return Err(ControlRunError::Protocol);
            }

            let mut length = u64::from(fixed[1] & 0x7f);
            if length == 126 {
                let mut extended = [0_u8; 2];
                self.stream.read_exact(&mut extended).await?;
                length = u64::from(u16::from_be_bytes(extended));
            } else if length == 127 {
                let mut extended = [0_u8; 8];
                self.stream.read_exact(&mut extended).await?;
                length = u64::from_be_bytes(extended);
            }
            let max = if matches!(opcode, 0x8..=0xA) {
                125
            } else {
                CONTROL_WIRE_MAX_BYTES
            };
            let length = usize::try_from(length).map_err(|_| ControlRunError::Protocol)?;
            if length > max {
                return Err(ControlRunError::Protocol);
            }

            let mut payload = vec![0_u8; length];
            self.stream.read_exact(&mut payload).await?;
            match opcode {
                0x1 => {
                    let text =
                        String::from_utf8(payload).map_err(|_| ControlRunError::Protocol)?;
                    return Ok(WebSocketMessage::Text(text));
                }
                0x8 => return Ok(WebSocketMessage::Close),
                0x9 => {
                    self.write_frame(0xA, &payload).await?;
                }
                0xA => {}
                _ => return Err(ControlRunError::Protocol),
            }
        }
    }

    async fn write_frame(&mut self, opcode: u8, payload: &[u8]) -> Result<(), ControlRunError> {
        if payload.len() > CONTROL_WIRE_MAX_BYTES {
            return Err(ControlRunError::Protocol);
        }
        let mask = websocket_masking_key().map_err(|_| ControlRunError::WebSocket)?;
        let mut frame = Vec::with_capacity(payload.len() + 14);
        frame.push(0x80 | opcode);
        if payload.len() <= 125 {
            frame.push(0x80 | u8::try_from(payload.len()).map_err(|_| ControlRunError::Protocol)?);
        } else {
            frame.push(0x80 | 126);
            let length = u16::try_from(payload.len()).map_err(|_| ControlRunError::Protocol)?;
            frame.extend_from_slice(&length.to_be_bytes());
        }
        frame.extend_from_slice(&mask);
        for (index, byte) in payload.iter().copied().enumerate() {
            frame.push(byte ^ mask[index % 4]);
        }
        self.stream.write_all(&frame).await?;
        self.stream.flush().await?;
        Ok(())
    }
}

fn validate_upgrade_response(
    header: &[u8],
    expected_accept: &str,
) -> Result<(), ControlRunError> {
    let text = std::str::from_utf8(header).map_err(|_| ControlRunError::WebSocket)?;
    let mut lines = text.split("\r\n");
    let status = lines.next().ok_or(ControlRunError::WebSocket)?;
    let mut status_parts = status.split_whitespace();
    if status_parts.next() != Some("HTTP/1.1") || status_parts.next() != Some("101") {
        return Err(ControlRunError::WebSocket);
    }

    let mut upgrade = false;
    let mut connection = false;
    let mut accept = false;
    for line in lines {
        if line.is_empty() {
            continue;
        }
        let Some((name, value)) = line.split_once(':') else {
            return Err(ControlRunError::WebSocket);
        };
        let name = name.trim().to_ascii_lowercase();
        let value = value.trim();
        match name.as_str() {
            "upgrade" => upgrade = value.eq_ignore_ascii_case("websocket"),
            "connection" => {
                connection = value
                    .split(',')
                    .any(|token| token.trim().eq_ignore_ascii_case("upgrade"));
            }
            "sec-websocket-accept" => accept = value == expected_accept,
            _ => {}
        }
    }
    if upgrade && connection && accept {
        Ok(())
    } else {
        Err(ControlRunError::WebSocket)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconnect_backoff_is_bounded() {
        assert_eq!(reconnect_delay_ms(1), 1_000);
        assert_eq!(reconnect_delay_ms(2), 5_000);
        assert_eq!(reconnect_delay_ms(3), 15_000);
        assert_eq!(reconnect_delay_ms(4), 30_000);
        assert_eq!(reconnect_delay_ms(5), 60_000);
        assert_eq!(reconnect_delay_ms(u32::MAX), 60_000);
    }

    #[test]
    fn upgrade_validation_requires_exact_accept_and_upgrade_headers() {
        let valid = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: abc\r\n\r\n";
        assert_eq!(validate_upgrade_response(valid, "abc"), Ok(()));
        assert_eq!(
            validate_upgrade_response(valid, "wrong"),
            Err(ControlRunError::WebSocket)
        );
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
