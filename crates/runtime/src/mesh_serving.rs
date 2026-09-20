use mish_transport::{MeshIngressError, MeshPortForward, MeshSessionOwner};
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener as StdTcpListener};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};
use tokio::io::copy_bidirectional;
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Handle;
use tokio::sync::watch;
use tokio::task::JoinSet;
use tokio::time::timeout;

const MESH_ACCEPT_POLL_TIMEOUT: Duration = Duration::from_millis(200);
const MESH_BACKEND_CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const MESH_START_TIMEOUT: Duration = Duration::from_secs(2);
const MESH_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(5);

fn block_on_mesh_drain<F>(handle: &Handle, future: F) -> F::Output
where
    F: std::future::Future,
{
    // Native readiness/Mesh composition can request a stop from a task already executing on the
    // one PRODUCT multi-thread Tokio runtime. Handle::block_on directly from that worker panics.
    // block_in_place is the Tokio-supported bridge for this bounded synchronous owner effect and
    // lets the scheduler move unrelated PRODUCT work to another worker while we drain exactly this
    // Mesh generation.
    if Handle::try_current().is_ok() {
        tokio::task::block_in_place(|| handle.block_on(future))
    } else {
        handle.block_on(future)
    }
}

fn wait_for_mesh_startup(
    startup_rx: &mpsc::Receiver<()>,
    expected_listeners: usize,
) -> Result<(), MeshIngressError> {
    let wait = || {
        let deadline = Instant::now() + MESH_START_TIMEOUT;
        for _ in 0..expected_listeners {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() || startup_rx.recv_timeout(remaining).is_err() {
                return Err(MeshIngressError::ExecutorUnavailable);
            }
        }
        Ok(())
    };

    // Readiness can publish READY from a task already running on the one PRODUCT Tokio runtime.
    // A plain recv_timeout there can occupy one worker while another PRODUCT task occupies the
    // second worker, starving the listener tasks whose startup acknowledgement this thread awaits.
    // block_in_place hands this bounded wait to Tokio's blocking boundary so listener tasks can run
    // on a replacement worker without creating a second runtime or PRODUCT scheduler.
    if Handle::try_current().is_ok() {
        tokio::task::block_in_place(wait)
    } else {
        wait()
    }
}

/// Cross-owner runtime composition policy for realizing public Mesh ingress.
///
/// Android supplies current owner projections and executes the platform effect, but it must not
/// independently decide when Proxy Serving + Readiness + Mesh admission are sufficient to expose
/// public ingress.
pub const fn mesh_ingress_serving_allowed(
    proxy_running: bool,
    readiness_ready: bool,
    mesh_admitted: bool,
    admission_epoch_present: bool,
) -> bool {
    proxy_running && readiness_ready && mesh_admitted && admission_epoch_present
}

struct MeshExecutionGeneration {
    stop: watch::Sender<bool>,
    listeners: JoinSet<()>,
    expected_listeners: usize,
    live_listeners: Arc<AtomicUsize>,
    sessions: Arc<MeshSessionOwner>,
}

/// Concrete Mesh execution state retained by the process-wide Runtime owner.
///
/// It owns no admission policy and no external capacity. Transport supplies one already-authorized
/// generation plus its session owner; this type binds/listens, retains async tasks, relays bytes and
/// drains everything on revocation.
pub(crate) struct MeshExecutionOwner {
    generation: Mutex<Option<MeshExecutionGeneration>>,
}

impl MeshExecutionOwner {
    pub(crate) fn new() -> Self {
        Self {
            generation: Mutex::new(None),
        }
    }

    pub(crate) fn start(
        &self,
        handle: &Handle,
        endpoint: Ipv4Addr,
        mappings: &[MeshPortForward],
        sessions: Arc<MeshSessionOwner>,
    ) -> Result<(), MeshIngressError> {
        if endpoint.is_unspecified() || endpoint.is_multicast() || endpoint == Ipv4Addr::BROADCAST {
            return Err(MeshIngressError::InvalidEndpoint);
        }
        if mappings.is_empty()
            || mappings
                .iter()
                .any(|mapping| mapping.ingress_port() == 0 || mapping.backend_port() == 0)
        {
            return Err(MeshIngressError::InvalidPortMapping);
        }

        {
            let state = self
                .generation
                .lock()
                .map_err(|_| MeshIngressError::ExecutorUnavailable)?;
            if state.is_some() {
                return Err(MeshIngressError::ExecutorUnavailable);
            }
        }

        // Bind every exact Mesh coordinate before publishing any task. A partial listener set can
        // therefore never become an observable generation.
        let mut bound = Vec::with_capacity(mappings.len());
        for mapping in mappings.iter().copied() {
            let listener = StdTcpListener::bind(SocketAddr::V4(SocketAddrV4::new(
                endpoint,
                mapping.ingress_port(),
            )))
            .map_err(|_| MeshIngressError::BindFailed)?;
            listener
                .set_nonblocking(true)
                .map_err(|_| MeshIngressError::ListenerConfigurationFailed)?;
            bound.push((listener, mapping));
        }

        let mut async_bound = Vec::with_capacity(bound.len());
        {
            let _enter = handle.enter();
            for (listener, mapping) in bound {
                let listener = TcpListener::from_std(listener)
                    .map_err(|_| MeshIngressError::ListenerConfigurationFailed)?;
                async_bound.push((listener, mapping));
            }
        }

        let (stop, stop_rx) = watch::channel(false);
        let live_listeners = Arc::new(AtomicUsize::new(0));
        let expected_listeners = async_bound.len();
        let (startup_tx, startup_rx) = mpsc::sync_channel(expected_listeners);
        let mut listeners = JoinSet::new();
        for (listener, mapping) in async_bound {
            listeners.spawn_on(
                mesh_listener_loop(
                    listener,
                    mapping,
                    stop_rx.clone(),
                    Arc::clone(&sessions),
                    Arc::clone(&live_listeners),
                    startup_tx.clone(),
                ),
                handle,
            );
        }
        drop(startup_tx);

        {
            let mut state = self
                .generation
                .lock()
                .map_err(|_| MeshIngressError::ExecutorUnavailable)?;
            *state = Some(MeshExecutionGeneration {
                stop,
                listeners,
                expected_listeners,
                live_listeners,
                sessions,
            });
        }

        // Every listener must explicitly acknowledge that its Tokio task is live. This replaces
        // startup polling with one bounded, deterministic publication barrier.
        if let Err(start_error) = wait_for_mesh_startup(&startup_rx, expected_listeners) {
            return match self.stop(Some(handle)) {
                Ok(()) => Err(start_error),
                Err(cleanup_error) => Err(cleanup_error),
            };
        }

        if self.is_healthy() {
            Ok(())
        } else {
            match self.stop(Some(handle)) {
                Ok(()) => Err(MeshIngressError::ExecutorUnavailable),
                Err(cleanup_error) => Err(cleanup_error),
            }
        }
    }

    pub(crate) fn stop(&self, handle: Option<&Handle>) -> Result<(), MeshIngressError> {
        let mut generation = {
            let mut state = self
                .generation
                .lock()
                .map_err(|_| MeshIngressError::ExecutorUnavailable)?;
            state.take()
        };
        let Some(mut generation) = generation.take() else {
            return Ok(());
        };

        generation.sessions.revoke();
        let _ = generation.stop.send(true);

        let Some(handle) = handle else {
            return Err(MeshIngressError::ExecutorUnavailable);
        };

        // Let each retained listener observe the stop signal and drain its own retained session
        // JoinSet. Aborting the outer listener first would drop that nested JoinSet before its
        // explicit abort+join path can run, making active-session cleanup scheduler-dependent.
        let drained = block_on_mesh_drain(handle, async {
            timeout(MESH_SHUTDOWN_TIMEOUT, async {
                while generation.listeners.join_next().await.is_some() {}
            })
            .await
            .is_ok()
        });

        if !drained {
            // Keep listener handles retained rather than silently detaching them. The enclosing
            // process runtime may retry drain or destroy the Tokio generation fail-closed.
            let mut state = self
                .generation
                .lock()
                .map_err(|_| MeshIngressError::ExecutorUnavailable)?;
            *state = Some(generation);
            return Err(MeshIngressError::ShutdownTimedOut);
        }

        if generation.sessions.active_sessions() == 0 {
            Ok(())
        } else {
            Err(MeshIngressError::ShutdownTimedOut)
        }
    }

    pub(crate) fn is_healthy(&self) -> bool {
        self.generation
            .lock()
            .ok()
            .and_then(|state| {
                state.as_ref().map(|generation| {
                    generation.sessions.is_accepting()
                        && generation.expected_listeners != 0
                        && generation.live_listeners.load(Ordering::Acquire)
                            == generation.expected_listeners
                })
            })
            .unwrap_or(false)
    }

    pub(crate) fn is_running(&self) -> bool {
        self.generation
            .lock()
            .map(|state| state.is_some())
            .unwrap_or(true)
    }
}

async fn mesh_listener_loop(
    listener: TcpListener,
    mapping: MeshPortForward,
    stop: watch::Receiver<bool>,
    sessions: Arc<MeshSessionOwner>,
    live_listeners: Arc<AtomicUsize>,
    startup_ready: mpsc::SyncSender<()>,
) {
    let _listener_guard = MeshListenerGuard::new(live_listeners);
    if startup_ready.try_send(()).is_err() {
        return;
    }
    drop(startup_ready);

    let mut session_tasks = JoinSet::new();
    loop {
        while session_tasks.try_join_next().is_some() {}
        if *stop.borrow() || !sessions.is_accepting() {
            break;
        }

        let accepted = match timeout(MESH_ACCEPT_POLL_TIMEOUT, listener.accept()).await {
            Ok(accepted) => accepted,
            Err(_) => continue,
        };
        let (client, _) = match accepted {
            Ok(pair) => pair,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        if *stop.borrow() || !sessions.is_accepting() {
            drop(client);
            break;
        }

        let Some(lease) = sessions.try_admit() else {
            // Capacity is decided at the Mesh edge. No backend socket is opened for overflow.
            drop(client);
            continue;
        };
        session_tasks.spawn(async move {
            let lease = lease;
            if !lease.is_current() {
                return;
            }
            serve_mesh_session(client, mapping.backend_port()).await;
        });
    }

    session_tasks.abort_all();
    while session_tasks.join_next().await.is_some() {}
}

async fn serve_mesh_session(mut client: TcpStream, backend_port: u16) {
    let backend = timeout(
        MESH_BACKEND_CONNECT_TIMEOUT,
        TcpStream::connect(SocketAddr::V4(SocketAddrV4::new(
            Ipv4Addr::LOCALHOST,
            backend_port,
        ))),
    )
    .await;
    let mut backend = match backend {
        Ok(Ok(stream)) => stream,
        Ok(Err(_)) | Err(_) => return,
    };

    let _ = client.set_nodelay(true);
    let _ = backend.set_nodelay(true);
    let _ = copy_bidirectional(&mut client, &mut backend).await;
}

struct MeshListenerGuard(Arc<AtomicUsize>);

impl MeshListenerGuard {
    fn new(live: Arc<AtomicUsize>) -> Self {
        live.fetch_add(1, Ordering::AcqRel);
        Self(live)
    }
}

impl Drop for MeshListenerGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_transport::{MAX_MESH_SESSIONS, MeshSessionOwner};
    use std::io::{Read, Write};
    use std::net::{TcpListener as StdBackendListener, TcpStream as StdClient};
    use std::sync::mpsc;
    use std::thread;

    const TEST_TIMEOUT: Duration = Duration::from_secs(3);

    fn test_runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_io()
            .enable_time()
            .build()
            .expect("test runtime")
    }

    fn reserve_port() -> u16 {
        let listener = StdBackendListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("reserve port");
        listener.local_addr().expect("address").port()
    }

    fn wait_until(deadline: Instant, mut predicate: impl FnMut() -> bool) {
        while Instant::now() < deadline {
            if predicate() {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        assert!(predicate(), "condition did not become true before deadline");
    }

    #[test]
    fn ingress_requires_every_current_owner_fact() {
        assert!(mesh_ingress_serving_allowed(true, true, true, true));

        for facts in [
            (false, true, true, true),
            (true, false, true, true),
            (true, true, false, true),
            (true, true, true, false),
        ] {
            assert!(!mesh_ingress_serving_allowed(
                facts.0, facts.1, facts.2, facts.3
            ));
        }
    }

    #[test]
    fn bidirectional_relay_forwards_bytes_on_existing_runtime_generation() {
        let runtime = test_runtime();
        let execution = MeshExecutionOwner::new();
        let sessions = MeshSessionOwner::product_generation();
        let backend = StdBackendListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("backend");
        let backend_port = backend.local_addr().expect("backend address").port();
        let ingress_port = reserve_port();

        let backend_thread = thread::spawn(move || {
            let (mut stream, _) = backend.accept().expect("backend session");
            stream
                .set_read_timeout(Some(TEST_TIMEOUT))
                .expect("backend read timeout");
            stream
                .set_write_timeout(Some(TEST_TIMEOUT))
                .expect("backend write timeout");
            let mut request = [0_u8; 4];
            stream.read_exact(&mut request).expect("backend read");
            assert_eq!(&request, b"ping");
            stream.write_all(b"pong").expect("backend write");
        });

        execution
            .start(
                runtime.handle(),
                Ipv4Addr::LOCALHOST,
                &[MeshPortForward::new(ingress_port, backend_port)],
                Arc::clone(&sessions),
            )
            .expect("start Mesh execution");

        let mut client =
            StdClient::connect((Ipv4Addr::LOCALHOST, ingress_port)).expect("Mesh client");
        client
            .set_read_timeout(Some(TEST_TIMEOUT))
            .expect("client read timeout");
        client
            .set_write_timeout(Some(TEST_TIMEOUT))
            .expect("client write timeout");
        client.write_all(b"ping").expect("client write");
        let mut response = [0_u8; 4];
        client.read_exact(&mut response).expect("client read");
        assert_eq!(&response, b"pong");

        drop(client);
        backend_thread.join().expect("backend thread");
        wait_until(Instant::now() + TEST_TIMEOUT, || {
            sessions.active_sessions() == 0
        });
        execution
            .stop(Some(runtime.handle()))
            .expect("clean Mesh stop");
    }

    #[test]
    fn session_above_transport_budget_is_rejected_before_backend_without_evicting_existing_sessions()
    {
        let runtime = test_runtime();
        let execution = MeshExecutionOwner::new();
        let sessions = MeshSessionOwner::product_generation();
        let backend = StdBackendListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("backend");
        let backend_port = backend.local_addr().expect("backend address").port();
        let ingress_port = reserve_port();

        let (accepted_tx, accepted_rx) = mpsc::channel();
        let (verify_tx, verify_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let backend_thread = thread::spawn(move || {
            let mut sockets = Vec::with_capacity(MAX_MESH_SESSIONS);
            for _ in 0..MAX_MESH_SESSIONS {
                let (stream, _) = backend.accept().expect("supported backend session");
                sockets.push(stream);
            }
            accepted_tx.send(sockets.len()).expect("accepted count");
            verify_rx.recv().expect("overflow probe");
            backend.set_nonblocking(true).expect("nonblocking backend");
            let deadline = Instant::now() + Duration::from_millis(500);
            let mut overflow_reached_backend = false;
            while Instant::now() < deadline {
                match backend.accept() {
                    Ok((_stream, _)) => {
                        overflow_reached_backend = true;
                        break;
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("backend overflow observation failed: {error}"),
                }
            }
            release_rx.recv().expect("release backend sessions");
            drop(sockets);
            overflow_reached_backend
        });

        execution
            .start(
                runtime.handle(),
                Ipv4Addr::LOCALHOST,
                &[MeshPortForward::new(ingress_port, backend_port)],
                Arc::clone(&sessions),
            )
            .expect("start Mesh execution");
        assert!(execution.is_healthy());

        let mut clients = Vec::with_capacity(MAX_MESH_SESSIONS);
        for _ in 0..MAX_MESH_SESSIONS {
            let client = StdClient::connect((Ipv4Addr::LOCALHOST, ingress_port))
                .expect("supported Mesh client");
            client
                .set_read_timeout(Some(TEST_TIMEOUT))
                .expect("read timeout");
            clients.push(client);
        }
        assert_eq!(
            accepted_rx
                .recv_timeout(TEST_TIMEOUT)
                .expect("backend count"),
            MAX_MESH_SESSIONS
        );
        wait_until(Instant::now() + TEST_TIMEOUT, || {
            sessions.active_sessions() == MAX_MESH_SESSIONS
        });

        let mut overflow = StdClient::connect((Ipv4Addr::LOCALHOST, ingress_port))
            .expect("overflow TCP handshake");
        overflow
            .set_read_timeout(Some(TEST_TIMEOUT))
            .expect("overflow timeout");
        let mut byte = [0_u8; 1];
        let closed = match overflow.read(&mut byte) {
            Ok(0) => true,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::ConnectionReset
                        | std::io::ErrorKind::ConnectionAborted
                        | std::io::ErrorKind::BrokenPipe
                ) =>
            {
                true
            }
            Ok(_) => false,
            Err(error) => panic!("overflow session did not fail closed: {error}"),
        };
        assert!(
            closed,
            "Mesh session above the Transport-owned budget remained usable"
        );
        assert_eq!(sessions.active_sessions(), MAX_MESH_SESSIONS);

        verify_tx.send(()).expect("verify overflow");
        release_tx.send(()).expect("release backend");
        assert!(!backend_thread.join().expect("backend thread"));

        drop(overflow);
        drop(clients);
        wait_until(Instant::now() + TEST_TIMEOUT, || {
            sessions.active_sessions() == 0
        });
        execution
            .stop(Some(runtime.handle()))
            .expect("clean Mesh stop");
        assert!(!execution.is_running());
    }

    #[test]
    fn backend_failure_releases_transport_session_lease() {
        let runtime = test_runtime();
        let execution = MeshExecutionOwner::new();
        let sessions = MeshSessionOwner::product_generation();
        let backend_port = reserve_port();
        let ingress_port = reserve_port();

        execution
            .start(
                runtime.handle(),
                Ipv4Addr::LOCALHOST,
                &[MeshPortForward::new(ingress_port, backend_port)],
                Arc::clone(&sessions),
            )
            .expect("start Mesh execution");
        let _client = StdClient::connect((Ipv4Addr::LOCALHOST, ingress_port)).expect("client");
        wait_until(Instant::now() + TEST_TIMEOUT, || {
            sessions.active_sessions() == 0
        });
        execution.stop(Some(runtime.handle())).expect("stop");
    }

    #[test]
    fn mesh_start_from_product_tokio_worker_does_not_starve_listener_startup() {
        let runtime = test_runtime();
        let execution = Arc::new(MeshExecutionOwner::new());
        let ingress_port = reserve_port();
        let backend_port = reserve_port();
        let (blocker_started_tx, blocker_started_rx) = mpsc::sync_channel(1);

        let blocker = runtime.spawn(async move {
            blocker_started_tx.send(()).expect("signal blocker");
            // Intentionally occupy the second worker longer than the Mesh startup deadline.
            // The start path must use Tokio's blocking boundary so listener tasks get a replacement
            // worker instead of timing out and leaving a half-published execution generation.
            thread::sleep(MESH_START_TIMEOUT + Duration::from_secs(1));
        });
        blocker_started_rx
            .recv_timeout(Duration::from_secs(1))
            .expect("blocker started");

        let owned = Arc::clone(&execution);
        let handle = runtime.handle().clone();
        let start = runtime.spawn(async move {
            let sessions = MeshSessionOwner::product_generation();
            owned.start(
                &handle,
                Ipv4Addr::LOCALHOST,
                &[MeshPortForward::new(ingress_port, backend_port)],
                sessions,
            )
        });

        let start_result = runtime
            .block_on(start)
            .expect("Tokio worker must not panic while starting Mesh");
        assert_eq!(start_result, Ok(()));
        assert!(execution.is_running());
        assert!(execution.is_healthy());

        execution
            .stop(Some(runtime.handle()))
            .expect("clean Mesh stop after worker startup");
        runtime.block_on(blocker).expect("blocker join");
    }

    #[test]
    fn mesh_stop_from_product_tokio_worker_does_not_panic_or_poison_execution_state() {
        let runtime = test_runtime();
        let execution = Arc::new(MeshExecutionOwner::new());
        let sessions = MeshSessionOwner::product_generation();
        let backend_port = reserve_port();
        let ingress_port = reserve_port();

        execution
            .start(
                runtime.handle(),
                Ipv4Addr::LOCALHOST,
                &[MeshPortForward::new(ingress_port, backend_port)],
                Arc::clone(&sessions),
            )
            .expect("start Mesh execution");

        let owned = Arc::clone(&execution);
        let handle = runtime.handle().clone();
        let stop = runtime.spawn(async move { owned.stop(Some(&handle)) });
        let stop_result = runtime
            .block_on(stop)
            .expect("Tokio worker must not panic while stopping Mesh");
        assert_eq!(stop_result, Ok(()));
        assert!(!execution.is_running());
        assert!(!execution.is_healthy());
        assert_eq!(sessions.active_sessions(), 0);
    }

    #[test]
    fn cancellation_drains_sessions_and_same_runtime_can_start_a_fresh_mesh_generation() {
        let runtime = test_runtime();
        let execution = MeshExecutionOwner::new();
        let backend = StdBackendListener::bind((Ipv4Addr::LOCALHOST, 0)).expect("backend");
        let backend_port = backend.local_addr().expect("backend address").port();
        let ingress_port = reserve_port();
        let sessions = MeshSessionOwner::product_generation();

        let (accepted_tx, accepted_rx) = mpsc::channel();
        let backend_thread = thread::spawn(move || {
            let (socket, _) = backend.accept().expect("backend session");
            accepted_tx.send(()).expect("accepted");
            thread::sleep(TEST_TIMEOUT);
            drop(socket);
        });

        execution
            .start(
                runtime.handle(),
                Ipv4Addr::LOCALHOST,
                &[MeshPortForward::new(ingress_port, backend_port)],
                Arc::clone(&sessions),
            )
            .expect("first generation");
        let client = StdClient::connect((Ipv4Addr::LOCALHOST, ingress_port)).expect("client");
        accepted_rx
            .recv_timeout(TEST_TIMEOUT)
            .expect("backend accepted");
        wait_until(Instant::now() + TEST_TIMEOUT, || {
            sessions.active_sessions() == 1
        });

        execution
            .stop(Some(runtime.handle()))
            .expect("cancel generation");
        assert_eq!(sessions.active_sessions(), 0);
        assert!(!execution.is_healthy());
        drop(client);

        let next_sessions = MeshSessionOwner::product_generation();
        execution
            .start(
                runtime.handle(),
                Ipv4Addr::LOCALHOST,
                &[MeshPortForward::new(ingress_port, backend_port)],
                Arc::clone(&next_sessions),
            )
            .expect("fresh generation on same process runtime");
        assert!(execution.is_healthy());
        execution.stop(Some(runtime.handle())).expect("second stop");
        assert_eq!(next_sessions.active_sessions(), 0);
        backend_thread.join().expect("backend thread");
    }
}
