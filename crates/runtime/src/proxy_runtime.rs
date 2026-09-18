use crate::mesh_serving::MeshExecutionOwner;
use crate::{
    ProxyServingFailure, ProxyServingLifecycle, ProxyServingSnapshot, ProxyServingState,
    RuntimeExecutionError, RuntimeExecutor,
};
use mish_configuration::EXTERNAL_TCP_SESSION_BUDGET;
use mish_proxy::{
    ProxyCredentialMaterial, ProxyOutboundConnector, ProxyProtocol, ProxyServingPlan,
    prepare_proxy_session,
};
use mish_transport::{MeshIngressError, MeshIngressExecutor, MeshPortForward, MeshSessionOwner};
use std::fmt;
use std::net::{Ipv4Addr, SocketAddr, TcpListener as StdTcpListener, TcpStream as StdTcpStream};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::copy_bidirectional;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{Semaphore, watch};
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::timeout;

const CONTROL_SESSION_RESERVE: usize = 1;
const MAX_NATIVE_PROXY_SESSIONS: usize = EXTERNAL_TCP_SESSION_BUDGET + CONTROL_SESSION_RESERVE;
const ACCEPT_POLL_TIMEOUT: Duration = Duration::from_millis(200);
const SESSION_SETUP_TIMEOUT: Duration = Duration::from_secs(15);
const START_TIMEOUT: Duration = Duration::from_secs(2);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(20);

const _: () = {
    assert!(MAX_NATIVE_PROXY_SESSIONS >= 64);
    assert!(MAX_NATIVE_PROXY_SESSIONS > EXTERNAL_TCP_SESSION_BUDGET);
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyServingRuntimeError {
    NonLoopbackListen,
    ListenerUnavailable(ProxyProtocol),
    ThreadUnavailable,
    StateUnavailable,
    ShutdownTimedOut,
}

impl ProxyServingRuntimeError {
    /// Convert runtime mechanism failure into the one PRODUCT lifecycle vocabulary before FFI.
    pub const fn lifecycle_failure(self) -> ProxyServingFailure {
        match self {
            Self::NonLoopbackListen => ProxyServingFailure::ProxyConfigurationRejected,
            Self::ListenerUnavailable(ProxyProtocol::Mixed) => {
                ProxyServingFailure::MixedListenerUnavailable
            }
            Self::ListenerUnavailable(ProxyProtocol::Socks5) => {
                ProxyServingFailure::Socks5ListenerUnavailable
            }
            Self::ListenerUnavailable(ProxyProtocol::Http) => {
                ProxyServingFailure::HttpConnectListenerUnavailable
            }
            Self::ThreadUnavailable => ProxyServingFailure::ExecutorUnavailable,
            Self::StateUnavailable => ProxyServingFailure::RuntimeStateUnavailable,
            Self::ShutdownTimedOut => ProxyServingFailure::ShutdownFailed,
        }
    }
}

impl fmt::Display for ProxyServingRuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NonLoopbackListen => {
                formatter.write_str("native proxy runtime must bind loopback only")
            }
            Self::ListenerUnavailable(protocol) => {
                write!(
                    formatter,
                    "native proxy listener is unavailable: {protocol:?}"
                )
            }
            Self::ThreadUnavailable => {
                formatter.write_str("native proxy runtime executor could not start")
            }
            Self::StateUnavailable => {
                formatter.write_str("native proxy runtime state is unavailable")
            }
            Self::ShutdownTimedOut => {
                formatter.write_str("native proxy sessions did not stop within the bounded timeout")
            }
        }
    }
}

impl std::error::Error for ProxyServingRuntimeError {}

fn map_execution_error(error: RuntimeExecutionError) -> ProxyServingRuntimeError {
    match error {
        RuntimeExecutionError::ThreadUnavailable => ProxyServingRuntimeError::ThreadUnavailable,
        RuntimeExecutionError::StateUnavailable => ProxyServingRuntimeError::StateUnavailable,
    }
}

/// One-way terminal event emitted by the Rust runtime owner after startup publication.
pub type ProxyServingTerminalObserver = Arc<dyn Fn(ProxyServingFailure) + Send + Sync + 'static>;

struct ProxyServingOwnerStateInner {
    lifecycle: ProxyServingLifecycle,
    observer: Option<ProxyServingTerminalObserver>,
    notified: bool,
}

struct ProxyServingOwnerState {
    shutdown: watch::Sender<bool>,
    inner: Mutex<ProxyServingOwnerStateInner>,
}

impl ProxyServingOwnerState {
    fn new(shutdown: watch::Sender<bool>) -> Self {
        let mut lifecycle = ProxyServingLifecycle::new();
        let started = lifecycle.request_start();
        debug_assert!(started);
        Self {
            shutdown,
            inner: Mutex::new(ProxyServingOwnerStateInner {
                lifecycle,
                observer: None,
                notified: false,
            }),
        }
    }

    fn set_observer(&self, observer: ProxyServingTerminalObserver) {
        let notification = {
            let mut state = self
                .inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            state.observer = Some(observer);
            if state.notified {
                None
            } else if let (Some(failure), Some(observer)) =
                (state.lifecycle.snapshot().failure(), state.observer.clone())
            {
                state.notified = true;
                Some((observer, failure))
            } else {
                None
            }
        };
        notify_terminal_observer(notification);
    }

    fn mark_running(&self) -> bool {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .lifecycle
            .mark_running()
    }

    fn mark_stopped(&self) {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .lifecycle
            .mark_stopped();
    }

    fn publish_failure(&self, failure: ProxyServingFailure) {
        let notification = {
            let mut state = self
                .inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.lifecycle.snapshot().failure().is_none() {
                state.lifecycle.mark_failed(failure);
            }
            if state.notified {
                None
            } else if let (Some(failure), Some(observer)) =
                (state.lifecycle.snapshot().failure(), state.observer.clone())
            {
                state.notified = true;
                Some((observer, failure))
            } else {
                None
            }
        };

        let _ = self.shutdown.send(true);
        notify_terminal_observer(notification);
    }

    fn snapshot(&self) -> ProxyServingSnapshot {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .lifecycle
            .snapshot()
    }

    fn failure(&self) -> Option<ProxyServingFailure> {
        self.snapshot().failure()
    }

    fn is_failed(&self) -> bool {
        self.snapshot().state() == ProxyServingState::Failed
    }
}

fn notify_terminal_observer(
    notification: Option<(ProxyServingTerminalObserver, ProxyServingFailure)>,
) {
    if let Some((observer, failure)) = notification {
        let _ = catch_unwind(AssertUnwindSafe(|| observer(failure)));
    }
}

/// Single in-process execution owner for canonical Proxy Serving and admitted Mesh work.
///
/// `mish-proxy` remains the owner of protocol/authentication/target semantics. `mish-transport`
/// remains the owner of Mesh endpoint/epoch/capacity/active-session facts. The injected connector
/// remains the owner of Cellular admission/currentness, exact-network DNS and outbound sockets.
/// Tokio is deliberately confined to this runtime layer.
///
/// Every Proxy accept/session task and every Mesh listener/session task is retained under this
/// runtime generation. The process-generation RuntimeExecutor owns the only Tokio runtime; this
/// component owns only its serving tasks. Shutdown therefore drains Mesh and Proxy tasks without
/// destroying the process executor.
pub struct ProxyServingRuntime {
    listener_count: usize,
    shutdown: watch::Sender<bool>,
    executor: Arc<RuntimeExecutor>,
    accept_tasks: Mutex<Vec<JoinHandle<()>>>,
    mesh_execution: MeshExecutionOwner,
    stopping: Arc<AtomicBool>,
    owner_state: Arc<ProxyServingOwnerState>,
    live_acceptors: Arc<AtomicUsize>,
    active_sessions: Arc<AtomicUsize>,
}

impl ProxyServingRuntime {
    pub fn start(
        executor: Arc<RuntimeExecutor>,
        plan: ProxyServingPlan,
        connector: Arc<dyn ProxyOutboundConnector>,
    ) -> Result<Arc<Self>, ProxyServingRuntimeError> {
        if !plan.listen_address().is_loopback() {
            return Err(ProxyServingRuntimeError::NonLoopbackListen);
        }

        // Bind every canonical coordinate before publishing any executor task. Partial listener
        // availability therefore never becomes an observable runtime generation.
        let mut bound = Vec::with_capacity(plan.listeners().len());
        for listener in plan.listeners() {
            let socket = SocketAddr::new(plan.listen_address(), listener.port);
            let tcp = StdTcpListener::bind(socket)
                .map_err(|_| ProxyServingRuntimeError::ListenerUnavailable(listener.protocol))?;
            tcp.set_nonblocking(true)
                .map_err(|_| ProxyServingRuntimeError::ListenerUnavailable(listener.protocol))?;
            bound.push((listener.protocol, tcp));
        }

        let handle = executor.handle().map_err(map_execution_error)?;
        let (shutdown, shutdown_rx) = watch::channel(false);
        let owner_state = Arc::new(ProxyServingOwnerState::new(shutdown.clone()));
        let stopping = Arc::new(AtomicBool::new(false));
        let live_acceptors = Arc::new(AtomicUsize::new(0));
        let active_sessions = Arc::new(AtomicUsize::new(0));
        let session_budget = Arc::new(Semaphore::new(MAX_NATIVE_PROXY_SESSIONS));
        let credentials = Arc::new(plan.credentials().clone());
        let listener_count = bound.len();
        let mut accept_tasks = Vec::with_capacity(listener_count);

        {
            let _enter = handle.enter();
            for (protocol, listener) in bound {
                let listener = TcpListener::from_std(listener)
                    .map_err(|_| ProxyServingRuntimeError::ListenerUnavailable(protocol))?;
                accept_tasks.push(handle.spawn(accept_loop(
                    protocol,
                    listener,
                    Arc::clone(&credentials),
                    Arc::clone(&connector),
                    Arc::clone(&session_budget),
                    shutdown_rx.clone(),
                    Arc::clone(&owner_state),
                    Arc::clone(&stopping),
                    Arc::clone(&live_acceptors),
                    Arc::clone(&active_sessions),
                )));
            }
        }

        let owner = Arc::new(Self {
            listener_count,
            shutdown,
            executor,
            accept_tasks: Mutex::new(accept_tasks),
            mesh_execution: MeshExecutionOwner::new(),
            stopping,
            owner_state,
            live_acceptors,
            active_sessions,
        });
        let deadline = Instant::now() + START_TIMEOUT;
        while !owner.is_healthy() && Instant::now() < deadline {
            if owner.owner_state.is_failed() {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        if !owner.is_healthy() {
            let _ = owner.stop_internal();
            return Err(ProxyServingRuntimeError::ThreadUnavailable);
        }
        if !owner.owner_state.mark_running() {
            let _ = owner.stop_internal();
            return Err(ProxyServingRuntimeError::StateUnavailable);
        }
        Ok(owner)
    }

    pub fn set_terminal_observer(&self, observer: ProxyServingTerminalObserver) {
        self.owner_state.set_observer(observer);
    }

    pub fn snapshot(&self) -> ProxyServingSnapshot {
        self.owner_state.snapshot()
    }

    pub fn terminal_failure(&self) -> Option<ProxyServingFailure> {
        self.owner_state.failure()
    }

    pub fn is_healthy(&self) -> bool {
        !self.stopping.load(Ordering::Acquire)
            && !self.owner_state.is_failed()
            && self.live_acceptors.load(Ordering::Acquire) == self.listener_count
    }

    pub fn active_sessions(&self) -> usize {
        self.active_sessions.load(Ordering::Acquire)
    }

    pub fn stop(&self) -> Result<(), ProxyServingRuntimeError> {
        self.stop_internal()
    }

    fn stop_internal(&self) -> Result<(), ProxyServingRuntimeError> {
        self.stopping.store(true, Ordering::Release);
        let mesh_clean = self.stop_ingress().is_ok();
        let _ = self.shutdown.send(true);

        let accept_tasks = match self.accept_tasks.lock() {
            Ok(mut tasks) => tasks.drain(..).collect::<Vec<_>>(),
            Err(_) => {
                self.owner_state
                    .publish_failure(ProxyServingFailure::RuntimeStateUnavailable);
                return Err(ProxyServingRuntimeError::StateUnavailable);
            }
        };
        let joined_cleanly = self
            .executor
            .block_on(async move {
                timeout(SHUTDOWN_TIMEOUT, async move {
                    for task in accept_tasks {
                        let _ = task.await;
                    }
                })
                .await
                .is_ok()
            })
            .map_err(map_execution_error)?;

        if !mesh_clean || !joined_cleanly || self.active_sessions.load(Ordering::Acquire) != 0 {
            self.owner_state
                .publish_failure(ProxyServingFailure::ShutdownFailed);
            return Err(ProxyServingRuntimeError::ShutdownTimedOut);
        }
        self.owner_state.mark_stopped();
        Ok(())
    }
}

impl MeshIngressExecutor for ProxyServingRuntime {
    fn start_ingress(
        &self,
        endpoint: Ipv4Addr,
        mappings: &[MeshPortForward],
        sessions: Arc<MeshSessionOwner>,
    ) -> Result<(), MeshIngressError> {
        if !self.is_healthy() {
            return Err(MeshIngressError::ExecutorUnavailable);
        }
        let handle = self
            .executor
            .handle()
            .map_err(|_| MeshIngressError::ExecutorUnavailable)?;
        self.mesh_execution
            .start(&handle, endpoint, mappings, sessions)
    }

    fn stop_ingress(&self) -> Result<(), MeshIngressError> {
        if !self.mesh_execution.is_running() {
            return Ok(());
        }
        let handle = self
            .executor
            .handle()
            .map_err(|_| MeshIngressError::ExecutorUnavailable)?;
        self.mesh_execution.stop(Some(&handle))
    }

    fn ingress_healthy(&self) -> bool {
        self.is_healthy() && self.mesh_execution.is_healthy()
    }
}

impl Drop for ProxyServingRuntime {
    fn drop(&mut self) {
        let _ = self.stop_internal();
    }
}

#[allow(clippy::too_many_arguments)]
async fn accept_loop(
    protocol: ProxyProtocol,
    listener: TcpListener,
    credentials: Arc<ProxyCredentialMaterial>,
    connector: Arc<dyn ProxyOutboundConnector>,
    session_budget: Arc<Semaphore>,
    shutdown: watch::Receiver<bool>,
    owner_state: Arc<ProxyServingOwnerState>,
    stopping: Arc<AtomicBool>,
    live_acceptors: Arc<AtomicUsize>,
    active_sessions: Arc<AtomicUsize>,
) {
    let _acceptor = AcceptorGuard::new(
        Arc::clone(&live_acceptors),
        Arc::clone(&stopping),
        Arc::clone(&owner_state),
    );
    let mut sessions = JoinSet::new();

    loop {
        while sessions.try_join_next().is_some() {}
        if *shutdown.borrow() {
            break;
        }

        let accepted = match timeout(ACCEPT_POLL_TIMEOUT, listener.accept()).await {
            Ok(accepted) => accepted,
            Err(_) => continue,
        };
        let (client, _) = match accepted {
            Ok(pair) => pair,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => {
                if !stopping.load(Ordering::Acquire) {
                    owner_state.publish_failure(ProxyServingFailure::ServingUnhealthy);
                }
                break;
            }
        };

        let permit = match Arc::clone(&session_budget).try_acquire_owned() {
            Ok(permit) => permit,
            Err(_) => {
                drop(client);
                continue;
            }
        };

        active_sessions.fetch_add(1, Ordering::AcqRel);
        let credentials = Arc::clone(&credentials);
        let connector = Arc::clone(&connector);
        let session_active = Arc::clone(&active_sessions);
        sessions.spawn(async move {
            let _permit = permit;
            let _count = SessionCountGuard(session_active);
            serve_session(protocol, client, credentials, connector).await;
        });
    }

    sessions.abort_all();
    while sessions.join_next().await.is_some() {}
}

async fn serve_session(
    protocol: ProxyProtocol,
    client: TcpStream,
    credentials: Arc<ProxyCredentialMaterial>,
    connector: Arc<dyn ProxyOutboundConnector>,
) {
    let client = match client.into_std() {
        Ok(client) => client,
        Err(_) => return,
    };
    let prepared = tokio::task::spawn_blocking(move || {
        prepare_blocking_session(protocol, client, credentials.as_ref(), connector.as_ref())
    })
    .await;
    let (client, upstream) = match prepared {
        Ok(Ok(streams)) => streams,
        Ok(Err(())) | Err(_) => return,
    };

    let mut client = match TcpStream::from_std(client) {
        Ok(stream) => stream,
        Err(_) => return,
    };
    let mut upstream = match TcpStream::from_std(upstream) {
        Ok(stream) => stream,
        Err(_) => return,
    };
    let _ = copy_bidirectional(&mut client, &mut upstream).await;
}

fn prepare_blocking_session(
    protocol: ProxyProtocol,
    client: StdTcpStream,
    credentials: &ProxyCredentialMaterial,
    connector: &dyn ProxyOutboundConnector,
) -> Result<(StdTcpStream, StdTcpStream), ()> {
    client.set_nonblocking(false).map_err(|_| ())?;
    client
        .set_read_timeout(Some(SESSION_SETUP_TIMEOUT))
        .map_err(|_| ())?;
    client
        .set_write_timeout(Some(SESSION_SETUP_TIMEOUT))
        .map_err(|_| ())?;

    let prepared =
        prepare_proxy_session(protocol, client, credentials, connector).map_err(|_| ())?;
    let (client, upstream) = prepared.into_streams();
    client.set_read_timeout(None).map_err(|_| ())?;
    client.set_write_timeout(None).map_err(|_| ())?;
    upstream.set_read_timeout(None).map_err(|_| ())?;
    upstream.set_write_timeout(None).map_err(|_| ())?;
    client.set_nonblocking(true).map_err(|_| ())?;
    upstream.set_nonblocking(true).map_err(|_| ())?;
    Ok((client, upstream))
}

struct AcceptorGuard {
    live_acceptors: Arc<AtomicUsize>,
    stopping: Arc<AtomicBool>,
    owner_state: Arc<ProxyServingOwnerState>,
}

impl AcceptorGuard {
    fn new(
        live_acceptors: Arc<AtomicUsize>,
        stopping: Arc<AtomicBool>,
        owner_state: Arc<ProxyServingOwnerState>,
    ) -> Self {
        live_acceptors.fetch_add(1, Ordering::AcqRel);
        Self {
            live_acceptors,
            stopping,
            owner_state,
        }
    }
}

impl Drop for AcceptorGuard {
    fn drop(&mut self) {
        self.live_acceptors.fetch_sub(1, Ordering::AcqRel);
        if !self.stopping.load(Ordering::Acquire) && !self.owner_state.is_failed() {
            self.owner_state
                .publish_failure(ProxyServingFailure::ServingUnhealthy);
        }
    }
}

struct SessionCountGuard(Arc<AtomicUsize>);

impl Drop for SessionCountGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_proxy::{ProxyConnectTarget, ProxyOutboundConnectError};

    struct RejectingConnector;

    impl ProxyOutboundConnector for RejectingConnector {
        fn connect(
            &self,
            _target: &ProxyConnectTarget,
        ) -> Result<StdTcpStream, ProxyOutboundConnectError> {
            Err(ProxyOutboundConnectError::Unavailable)
        }
    }

    #[test]
    fn non_loopback_plan_is_rejected_before_listener_effects() {
        let plan = ProxyServingPlan::canonical(
            "192.0.2.10".parse().expect("address"),
            ProxyCredentialMaterial::new("user", "password").expect("credentials"),
        )
        .expect("explicit non-wildcard plan");
        let error = match ProxyServingRuntime::start(plan, Arc::new(RejectingConnector)) {
            Ok(runtime) => {
                let _ = runtime.stop();
                panic!("non-loopback plan must fail");
            }
            Err(error) => error,
        };
        assert_eq!(error, ProxyServingRuntimeError::NonLoopbackListen);
        assert_eq!(
            error.lifecycle_failure(),
            ProxyServingFailure::ProxyConfigurationRejected
        );
    }

    #[test]
    fn runtime_error_mapping_is_exact_and_owner_owned() {
        assert_eq!(
            ProxyServingRuntimeError::ListenerUnavailable(ProxyProtocol::Mixed).lifecycle_failure(),
            ProxyServingFailure::MixedListenerUnavailable
        );
        assert_eq!(
            ProxyServingRuntimeError::ListenerUnavailable(ProxyProtocol::Socks5)
                .lifecycle_failure(),
            ProxyServingFailure::Socks5ListenerUnavailable
        );
        assert_eq!(
            ProxyServingRuntimeError::ListenerUnavailable(ProxyProtocol::Http).lifecycle_failure(),
            ProxyServingFailure::HttpConnectListenerUnavailable
        );
        assert_eq!(
            ProxyServingRuntimeError::ThreadUnavailable.lifecycle_failure(),
            ProxyServingFailure::ExecutorUnavailable
        );
        assert_eq!(
            ProxyServingRuntimeError::StateUnavailable.lifecycle_failure(),
            ProxyServingFailure::RuntimeStateUnavailable
        );
        assert_eq!(
            ProxyServingRuntimeError::ShutdownTimedOut.lifecycle_failure(),
            ProxyServingFailure::ShutdownFailed
        );
    }

    #[test]
    fn unexpected_acceptor_exit_is_owned_and_notified_by_rust_once() {
        let (shutdown, _) = watch::channel(false);
        let owner_state = Arc::new(ProxyServingOwnerState::new(shutdown));
        assert!(owner_state.mark_running());
        let stopping = Arc::new(AtomicBool::new(false));
        let live_acceptors = Arc::new(AtomicUsize::new(0));
        let observations = Arc::new(Mutex::new(Vec::new()));
        let observations_for_callback = Arc::clone(&observations);
        owner_state.set_observer(Arc::new(move |failure| {
            observations_for_callback
                .lock()
                .expect("observations")
                .push(failure);
        }));

        {
            let _guard = AcceptorGuard::new(
                Arc::clone(&live_acceptors),
                Arc::clone(&stopping),
                Arc::clone(&owner_state),
            );
            assert_eq!(live_acceptors.load(Ordering::Acquire), 1);
        }

        assert_eq!(owner_state.snapshot().state(), ProxyServingState::Failed);
        assert_eq!(
            owner_state.failure(),
            Some(ProxyServingFailure::ServingUnhealthy)
        );
        assert_eq!(live_acceptors.load(Ordering::Acquire), 0);
        assert_eq!(
            observations.lock().expect("observations").as_slice(),
            &[ProxyServingFailure::ServingUnhealthy]
        );
        owner_state.publish_failure(ProxyServingFailure::ServingUnhealthy);
        assert_eq!(observations.lock().expect("observations").len(), 1);
    }

    #[test]
    fn explicit_stop_does_not_publish_terminal_failure() {
        let (shutdown, _) = watch::channel(false);
        let owner_state = Arc::new(ProxyServingOwnerState::new(shutdown));
        assert!(owner_state.mark_running());
        let stopping = Arc::new(AtomicBool::new(true));
        let live_acceptors = Arc::new(AtomicUsize::new(0));
        {
            let _guard = AcceptorGuard::new(
                Arc::clone(&live_acceptors),
                Arc::clone(&stopping),
                Arc::clone(&owner_state),
            );
        }
        assert_eq!(owner_state.failure(), None);
        assert_eq!(owner_state.snapshot().state(), ProxyServingState::Running);
    }

    #[test]
    fn start_owns_all_canonical_loopback_listeners_and_lifecycle() {
        let credentials =
            ProxyCredentialMaterial::new("runtime-user", "runtime-password").expect("credentials");
        let plan = ProxyServingPlan::canonical(Ipv4Addr::LOCALHOST.into(), credentials)
            .expect("canonical plan");
        let runtime =
            ProxyServingRuntime::start(plan, Arc::new(RejectingConnector)).expect("runtime");
        assert!(runtime.is_healthy());
        assert_eq!(runtime.snapshot().state(), ProxyServingState::Running);
        assert_eq!(runtime.snapshot().failure(), None);
        runtime.stop().expect("stop");
        assert!(!runtime.is_healthy());
        assert_eq!(runtime.snapshot().state(), ProxyServingState::Stopped);
        assert_eq!(runtime.snapshot().failure(), None);
        assert_eq!(runtime.active_sessions(), 0);
    }
}
