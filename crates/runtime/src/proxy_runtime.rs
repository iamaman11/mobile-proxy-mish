use mish_cellular_egress_bridge::{
    CellularOutboundConnector as ProxyOutboundConnector, ProxyCredentialMaterial, ProxyProtocol,
    ProxyServingPlan, serve_session as serve_proxy_session,
};
use mish_configuration::EXTERNAL_TCP_SESSION_BUDGET;
use std::collections::HashMap;
use std::fmt;
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const CONTROL_SESSION_RESERVE: usize = 1;
const MAX_NATIVE_PROXY_SESSIONS: usize = EXTERNAL_TCP_SESSION_BUDGET + CONTROL_SESSION_RESERVE;
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(20);
const WAKE_TIMEOUT: Duration = Duration::from_millis(200);

const _: () = {
    assert!(MAX_NATIVE_PROXY_SESSIONS >= 64);
    assert!(MAX_NATIVE_PROXY_SESSIONS > EXTERNAL_TCP_SESSION_BUDGET);
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyServingRuntimeError {
    NonLoopbackListen,
    BindFailed,
    ThreadUnavailable,
    StateUnavailable,
    ShutdownTimedOut,
}

impl fmt::Display for ProxyServingRuntimeError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::NonLoopbackListen => "native proxy runtime must bind loopback only",
            Self::BindFailed => "native proxy runtime could not bind canonical listeners",
            Self::ThreadUnavailable => "native proxy runtime accept worker could not start",
            Self::StateUnavailable => "native proxy runtime state is unavailable",
            Self::ShutdownTimedOut => {
                "native proxy sessions did not stop within the bounded timeout"
            }
        })
    }
}

impl std::error::Error for ProxyServingRuntimeError {}

/// In-process listener/runtime effect for the vendor-neutral Proxy Serving owner.
///
/// This object owns only concrete listener/session execution. Protocol/auth/target semantics remain
/// in `mish-proxy`; DNS, cellular admission and socket routing remain behind the injected outbound
/// connector. The listener address is deliberately restricted to loopback because public Mesh
/// ingress remains the sole external exposure owner.
pub struct ProxyServingRuntime {
    wake_addresses: Vec<SocketAddr>,
    stop_requested: Arc<AtomicBool>,
    live_acceptors: Arc<AtomicUsize>,
    active_sessions: Arc<AtomicUsize>,
    clients: Arc<Mutex<HashMap<u64, TcpStream>>>,
    accept_threads: Mutex<Vec<JoinHandle<()>>>,
}

impl ProxyServingRuntime {
    pub fn start(
        plan: ProxyServingPlan,
        connector: Arc<dyn ProxyOutboundConnector>,
    ) -> Result<Arc<Self>, ProxyServingRuntimeError> {
        if !plan.listen_address().is_loopback() {
            return Err(ProxyServingRuntimeError::NonLoopbackListen);
        }

        let credentials = Arc::new(plan.credentials().clone());
        let mut bound = Vec::with_capacity(plan.listeners().len());
        for listener in plan.listeners() {
            let socket = SocketAddr::new(plan.listen_address(), listener.port);
            let tcp =
                TcpListener::bind(socket).map_err(|_| ProxyServingRuntimeError::BindFailed)?;
            let address = tcp
                .local_addr()
                .map_err(|_| ProxyServingRuntimeError::StateUnavailable)?;
            bound.push((listener.protocol, tcp, address));
        }

        let stop_requested = Arc::new(AtomicBool::new(false));
        let live_acceptors = Arc::new(AtomicUsize::new(bound.len()));
        let active_sessions = Arc::new(AtomicUsize::new(0));
        let clients = Arc::new(Mutex::new(HashMap::new()));
        let session_sequence = Arc::new(AtomicU64::new(1));
        let wake_addresses = bound
            .iter()
            .map(|(_, _, address)| *address)
            .collect::<Vec<_>>();
        let mut accept_threads = Vec::with_capacity(bound.len());

        for (protocol, listener, _) in bound {
            let accept_stop = Arc::clone(&stop_requested);
            let accept_live = Arc::clone(&live_acceptors);
            let accept_active = Arc::clone(&active_sessions);
            let accept_clients = Arc::clone(&clients);
            let accept_sequence = Arc::clone(&session_sequence);
            let accept_credentials = Arc::clone(&credentials);
            let accept_connector = Arc::clone(&connector);
            let name = match protocol {
                ProxyProtocol::Mixed => "mish-proxy-mixed-accept",
                ProxyProtocol::Socks5 => "mish-proxy-socks5-accept",
                ProxyProtocol::Http => "mish-proxy-http-accept",
            };
            match thread::Builder::new().name(name.to_owned()).spawn(move || {
                accept_loop(
                    protocol,
                    listener,
                    accept_credentials,
                    accept_connector,
                    accept_stop,
                    accept_live,
                    accept_active,
                    accept_clients,
                    accept_sequence,
                )
            }) {
                Ok(handle) => accept_threads.push(handle),
                Err(_) => {
                    stop_requested.store(true, Ordering::Release);
                    for address in &wake_addresses {
                        let _ = TcpStream::connect_timeout(address, WAKE_TIMEOUT);
                    }
                    for handle in accept_threads {
                        let _ = handle.join();
                    }
                    return Err(ProxyServingRuntimeError::ThreadUnavailable);
                }
            }
        }

        Ok(Arc::new(Self {
            wake_addresses,
            stop_requested,
            live_acceptors,
            active_sessions,
            clients,
            accept_threads: Mutex::new(accept_threads),
        }))
    }

    pub fn is_healthy(&self) -> bool {
        !self.stop_requested.load(Ordering::Acquire)
            && self.live_acceptors.load(Ordering::Acquire) == self.wake_addresses.len()
    }

    pub fn active_sessions(&self) -> usize {
        self.active_sessions.load(Ordering::Acquire)
    }

    pub fn stop(&self) -> Result<(), ProxyServingRuntimeError> {
        self.stop_internal()
    }

    fn stop_internal(&self) -> Result<(), ProxyServingRuntimeError> {
        self.stop_requested.store(true, Ordering::Release);
        for address in &self.wake_addresses {
            let _ = TcpStream::connect_timeout(address, WAKE_TIMEOUT);
        }

        if let Ok(clients) = self.clients.lock() {
            for stream in clients.values() {
                let _ = stream.shutdown(Shutdown::Both);
            }
        } else {
            return Err(ProxyServingRuntimeError::StateUnavailable);
        }

        let handles = self
            .accept_threads
            .lock()
            .map_err(|_| ProxyServingRuntimeError::StateUnavailable)?
            .drain(..)
            .collect::<Vec<_>>();
        for handle in handles {
            handle
                .join()
                .map_err(|_| ProxyServingRuntimeError::StateUnavailable)?;
        }

        let deadline = Instant::now() + SHUTDOWN_TIMEOUT;
        while self.active_sessions.load(Ordering::Acquire) != 0 && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        if self.active_sessions.load(Ordering::Acquire) != 0 {
            return Err(ProxyServingRuntimeError::ShutdownTimedOut);
        }

        self.clients
            .lock()
            .map_err(|_| ProxyServingRuntimeError::StateUnavailable)?
            .clear();
        Ok(())
    }
}

impl Drop for ProxyServingRuntime {
    fn drop(&mut self) {
        let _ = self.stop_internal();
    }
}

#[allow(clippy::too_many_arguments)]
fn accept_loop(
    protocol: ProxyProtocol,
    listener: TcpListener,
    credentials: Arc<ProxyCredentialMaterial>,
    connector: Arc<dyn ProxyOutboundConnector>,
    stop_requested: Arc<AtomicBool>,
    live_acceptors: Arc<AtomicUsize>,
    active_sessions: Arc<AtomicUsize>,
    clients: Arc<Mutex<HashMap<u64, TcpStream>>>,
    session_sequence: Arc<AtomicU64>,
) {
    while !stop_requested.load(Ordering::Acquire) {
        let (client, _) = match listener.accept() {
            Ok(pair) => pair,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        if stop_requested.load(Ordering::Acquire) {
            let _ = client.shutdown(Shutdown::Both);
            break;
        }

        if active_sessions
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |current| {
                (current < MAX_NATIVE_PROXY_SESSIONS).then_some(current + 1)
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
                let _ = client.shutdown(Shutdown::Both);
                continue;
            }
        };
        let session_id = session_sequence.fetch_add(1, Ordering::AcqRel);
        if let Ok(mut tracked_clients) = clients.lock() {
            tracked_clients.insert(session_id, tracked);
        } else {
            active_sessions.fetch_sub(1, Ordering::AcqRel);
            let _ = client.shutdown(Shutdown::Both);
            break;
        }

        let session_credentials = Arc::clone(&credentials);
        let session_connector = Arc::clone(&connector);
        let session_clients = Arc::clone(&clients);
        let session_active = Arc::clone(&active_sessions);
        let spawn = thread::Builder::new()
            .name(format!("mish-proxy-session-{session_id}"))
            .spawn(move || {
                let _ = serve_proxy_session(
                    protocol,
                    client,
                    session_credentials.as_ref(),
                    session_connector.as_ref(),
                );
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
        }
    }
    live_acceptors.fetch_sub(1, Ordering::AcqRel);
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular_egress_bridge::{ConnectTarget, OutboundConnectError};

    struct RejectingConnector;

    impl ProxyOutboundConnector for RejectingConnector {
        fn connect(&self, _target: &ConnectTarget) -> Result<TcpStream, OutboundConnectError> {
            Err(OutboundConnectError::Unavailable)
        }
    }

    #[test]
    fn non_loopback_plan_is_rejected_before_listener_effects() {
        let plan = ProxyServingPlan::canonical(
            "192.0.2.10".parse().expect("address"),
            ProxyCredentialMaterial::new("user", "password").expect("credentials"),
        )
        .expect("explicit non-wildcard plan");
        assert!(matches!(
            ProxyServingRuntime::start(plan, Arc::new(RejectingConnector)),
            Err(ProxyServingRuntimeError::NonLoopbackListen)
        ));
    }
}
