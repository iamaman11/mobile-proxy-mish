use crate::ProxyServingFailure;
use mish_configuration::EXTERNAL_TCP_SESSION_BUDGET;
use mish_proxy::{
    ProxyCredentialMaterial, ProxyOutboundConnector, ProxyProtocol, ProxyServingPlan,
    prepare_proxy_session,
};
use std::fmt;
use std::net::{SocketAddr, TcpListener as StdTcpListener, TcpStream as StdTcpStream};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::copy_bidirectional;
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::{Semaphore, watch};
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::timeout;

const CONTROL_SESSION_RESERVE: usize = 1;
const MAX_NATIVE_PROXY_SESSIONS: usize = EXTERNAL_TCP_SESSION_BUDGET + CONTROL_SESSION_RESERVE;
const IO_WORKER_THREADS: usize = 2;
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

/// One-way terminal event emitted by the Rust runtime owner after startup publication.
pub type ProxyServingTerminalObserver = Arc<dyn Fn(ProxyServingFailure) + Send + Sync + 'static>;

#[derive(Default)]
struct TerminalStateInner {
    failure: Option<ProxyServingFailure>,
    observer: Option<ProxyServingTerminalObserver>,
    notified: bool,
}

struct TerminalState {
    shutdown: watch::Sender<bool>,
    inner: Mutex<TerminalStateInner>,
}

impl TerminalState {
    fn new(shutdown: watch::Sender<bool>) -> Self {
        Self {
            shutdown,
            inner: Mutex::new(TerminalStateInner::default()),
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
            } else if let (Some(failure), Some(observer)) = (state.failure, state.observer.clone())
            {
                state.notified = true;
                Some((observer, failure))
            } else {
                None
            }
        };
        notify_terminal_observer(notification);
    }

    fn publish(&self, failure: ProxyServingFailure) {
        let notification = {
            let mut state = self
                .inner
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if state.failure.is_none() {
                state.failure = Some(failure);
            }
            if state.notified {
                None
            } else if let (Some(failure), Some(observer)) = (state.failure, state.observer.clone())
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

    fn failure(&self) -> Option<ProxyServingFailure> {
        self.inner
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .failure
    }

    fn is_failed(&self) -> bool {
        self.failure().is_some()
    }
}

fn notify_terminal_observer(
    notification: Option<(ProxyServingTerminalObserver, ProxyServingFailure)>,
) {
    if let Some((observer, failure)) = notification {
        let _ = catch_unwind(AssertUnwindSafe(|| observer(failure)));
    }
}

/// Single in-process execution owner for all canonical proxy listeners and long-lived relays.
///
/// `mish-proxy` remains the owner of protocol/authentication/target semantics. The injected
/// connector remains the owner of Cellular admission/currentness, exact-network DNS and outbound
/// socket effects. Tokio is deliberately confined to this runtime layer.
///
/// Every accept task is retained by this owner. Every accepted session is retained by the
/// corresponding accept task's `JoinSet`. Shutdown therefore has one explicit ownership tree:
/// signal -> stop admission -> abort/drain sessions -> join acceptors -> destroy Tokio runtime.
/// Unexpected acceptor loss is terminal owner state: Rust records the failure, closes admission,
/// drains session trees and emits one typed observation to the platform boundary.
pub struct ProxyServingRuntime {
    listener_count: usize,
    shutdown: watch::Sender<bool>,
    runtime: Mutex<Option<Runtime>>,
    accept_tasks: Mutex<Vec<JoinHandle<()>>>,
    stopping: Arc<AtomicBool>,
    terminal: Arc<TerminalState>,
    live_acceptors: Arc<AtomicUsize>,
    active_sessions: Arc<AtomicUsize>,
}

impl ProxyServingRuntime {
    pub fn start(
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

        let runtime = Builder::new_multi_thread()
            .worker_threads(IO_WORKER_THREADS)
            .thread_name("mish-proxy-io")
            .enable_io()
            .enable_time()
            .build()
            .map_err(|_| ProxyServingRuntimeError::ThreadUnavailable)?;
        let (shutdown, shutdown_rx) = watch::channel(false);
        let terminal = Arc::new(TerminalState::new(shutdown.clone()));
        let stopping = Arc::new(AtomicBool::new(false));
        let live_acceptors = Arc::new(AtomicUsize::new(0));
        let active_sessions = Arc::new(AtomicUsize::new(0));
        let session_budget = Arc::new(Semaphore::new(MAX_NATIVE_PROXY_SESSIONS));
        let credentials = Arc::new(plan.credentials().clone());
        let listener_count = bound.len();
        let mut accept_tasks = Vec::with_capacity(listener_count);

        {
            let _enter = runtime.enter();
            for (protocol, listener) in bound {
                let listener = TcpListener::from_std(listener)
                    .map_err(|_| ProxyServingRuntimeError::ListenerUnavailable(protocol))?;
                accept_tasks.push(runtime.spawn(accept_loop(
                    protocol,
                    listener,
                    Arc::clone(&credentials),
                    Arc::clone(&connector),
                    Arc::clone(&session_budget),
                    shutdown_rx.clone(),
                    Arc::clone(&terminal),
                    Arc::clone(&stopping),
                    Arc::clone(&live_acceptors),
                    Arc::clone(&active_sessions),
                )));
            }
        }

        let owner = Arc::new(Self {
            listener_count,
            shutdown,
            runtime: Mutex::new(Some(runtime)),
            accept_tasks: Mutex::new(accept_tasks),
            stopping,
            terminal,
            live_acceptors,
            active_sessions,
        });
        let deadline = Instant::now() + START_TIMEOUT;
        while !owner.is_healthy() && Instant::now() < deadline {
            if owner.terminal.is_failed() {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        if !owner.is_healthy() {
            let _ = owner.stop();
            return Err(ProxyServingRuntimeError::ThreadUnavailable);
        }
        Ok(owner)
    }

    pub fn set_terminal_observer(&self, observer: ProxyServingTerminalObserver) {
        self.terminal.set_observer(observer);
    }

    pub fn terminal_failure(&self) -> Option<ProxyServingFailure> {
        self.terminal.failure()
    }

    pub fn is_healthy(&self) -> bool {
        !self.stopping.load(Ordering::Acquire)
            && !self.terminal.is_failed()
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
        let _ = self.shutdown.send(true);

        let accept_tasks = self
            .accept_tasks
            .lock()
            .map_err(|_| ProxyServingRuntimeError::StateUnavailable)?
            .drain(..)
            .collect::<Vec<_>>();
        let runtime = self
            .runtime
            .lock()
            .map_err(|_| ProxyServingRuntimeError::StateUnavailable)?
            .take();

        let mut joined_cleanly = true;
        if let Some(runtime) = runtime {
            joined_cleanly = runtime.block_on(async move {
                timeout(SHUTDOWN_TIMEOUT, async move {
                    for task in accept_tasks {
                        let _ = task.await;
                    }
                })
                .await
                .is_ok()
            });
            runtime.shutdown_timeout(SHUTDOWN_TIMEOUT);
        }

        if !joined_cleanly || self.active_sessions.load(Ordering::Acquire) != 0 {
            return Err(ProxyServingRuntimeError::ShutdownTimedOut);
        }
        Ok(())
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
    terminal: Arc<TerminalState>,
    stopping: Arc<AtomicBool>,
    live_acceptors: Arc<AtomicUsize>,
    active_sessions: Arc<AtomicUsize>,
) {
    let _acceptor = AcceptorGuard::new(
        Arc::clone(&live_acceptors),
        Arc::clone(&stopping),
        Arc::clone(&terminal),
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
                terminal.publish(ProxyServingFailure::ServingUnhealthy);
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
    terminal: Arc<TerminalState>,
}

impl AcceptorGuard {
    fn new(
        live_acceptors: Arc<AtomicUsize>,
        stopping: Arc<AtomicBool>,
        terminal: Arc<TerminalState>,
    ) -> Self {
        live_acceptors.fetch_add(1, Ordering::AcqRel);
        Self {
            live_acceptors,
            stopping,
            terminal,
        }
    }
}

impl Drop for AcceptorGuard {
    fn drop(&mut self) {
        self.live_acceptors.fetch_sub(1, Ordering::AcqRel);
        if !self.stopping.load(Ordering::Acquire) && !self.terminal.is_failed() {
            self.terminal.publish(ProxyServingFailure::ServingUnhealthy);
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
    use std::net::Ipv4Addr;

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
        let terminal = Arc::new(TerminalState::new(shutdown));
        let stopping = Arc::new(AtomicBool::new(false));
        let live_acceptors = Arc::new(AtomicUsize::new(0));
        let observations = Arc::new(Mutex::new(Vec::new()));
        let observations_for_callback = Arc::clone(&observations);
        terminal.set_observer(Arc::new(move |failure| {
            observations_for_callback
                .lock()
                .expect("observations")
                .push(failure);
        }));

        {
            let _guard = AcceptorGuard::new(
                Arc::clone(&live_acceptors),
                Arc::clone(&stopping),
                Arc::clone(&terminal),
            );
            assert_eq!(live_acceptors.load(Ordering::Acquire), 1);
        }

        assert_eq!(
            terminal.failure(),
            Some(ProxyServingFailure::ServingUnhealthy)
        );
        assert_eq!(live_acceptors.load(Ordering::Acquire), 0);
        assert_eq!(
            observations.lock().expect("observations").as_slice(),
            &[ProxyServingFailure::ServingUnhealthy]
        );
        terminal.publish(ProxyServingFailure::ServingUnhealthy);
        assert_eq!(observations.lock().expect("observations").len(), 1);
    }

    #[test]
    fn explicit_stop_does_not_publish_terminal_failure() {
        let (shutdown, _) = watch::channel(false);
        let terminal = Arc::new(TerminalState::new(shutdown));
        let stopping = Arc::new(AtomicBool::new(true));
        let live_acceptors = Arc::new(AtomicUsize::new(0));
        {
            let _guard = AcceptorGuard::new(
                Arc::clone(&live_acceptors),
                Arc::clone(&stopping),
                Arc::clone(&terminal),
            );
        }
        assert_eq!(terminal.failure(), None);
    }

    #[test]
    fn start_owns_all_canonical_loopback_listeners_in_one_runtime() {
        let credentials =
            ProxyCredentialMaterial::new("runtime-user", "runtime-password").expect("credentials");
        let plan = ProxyServingPlan::canonical(Ipv4Addr::LOCALHOST.into(), credentials)
            .expect("canonical plan");
        let runtime =
            ProxyServingRuntime::start(plan, Arc::new(RejectingConnector)).expect("runtime");
        assert!(runtime.is_healthy());
        runtime.stop().expect("stop");
        assert!(!runtime.is_healthy());
        assert_eq!(runtime.active_sessions(), 0);
    }
}
