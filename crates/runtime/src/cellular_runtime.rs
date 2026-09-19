//! Vendor-neutral Cellular Egress runtime coordination.
//!
//! This module composes one `mish-cellular` natural-owner instance and one bounded root-policy
//! effect gate. Proxy Serving consumes the same owner directly through a narrow connector; there is
//! no private loopback bridge, duplicate cellular owner, DNS fallback or proxy-specific root path.

use crate::RuntimeExecutor;
use crate::public_ip_network::execute_public_ip_probe;
use crate::tls_client::ProductTlsClient;
use crate::{
    CellularDnsDiagnosticSnapshot, CellularDnsResolver, CellularOutboundRuntimeConnector,
    PreparedPublicIpProbe, PublicEgressIpObservation, PublicIpProbeEffectFailure,
    PublicIpProbeFailure, cellular_dns_diagnostic_snapshot,
};
use mish_cellular::{
    CellularAdmissionSnapshot, CellularAdmissionState, CellularEgress, NetworkHandle,
    NetworkObservation, ObservationSequence,
};
use mish_proxy::{ProxyConnectTarget, ProxyOutboundConnectError, ProxyOutboundConnector};
use std::net::TcpStream;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;
use tokio::sync::Notify;
use tokio::time::{Instant as TokioInstant, timeout as tokio_timeout};

const OPERATION_TIMEOUT_MAX_MS: u64 = 120_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CellularRuntimeError {
    InvalidOperationTimeout,
    ConnectorUnavailable,
    StateUnavailable,
}

pub struct CellularRuntimeCoordinator {
    owner: Arc<Mutex<CellularEgress>>,
    root_policy_effect_gate: Arc<RootPolicyEffectGate>,
    resolver: Arc<dyn CellularDnsResolver>,
}

impl CellularRuntimeCoordinator {
    pub fn new(resolver: Arc<dyn CellularDnsResolver>) -> Arc<Self> {
        Arc::new(Self {
            owner: Arc::new(Mutex::new(CellularEgress::new())),
            root_policy_effect_gate: Arc::new(RootPolicyEffectGate::default()),
            resolver,
        })
    }

    pub fn admission_snapshot(&self) -> Result<CellularAdmissionSnapshot, CellularRuntimeError> {
        Ok(self.owner()?.admission())
    }

    pub fn dns_diagnostic_snapshot(&self) -> CellularDnsDiagnosticSnapshot {
        cellular_dns_diagnostic_snapshot()
    }

    /// Begins one bounded generation-bound public-IP observation using the same root-policy
    /// authorization and owner-bound DNS authority as PRODUCT proxy egress. The returned ticket
    /// carries no socket and owns no lifecycle; Android performs only the ordinary UID TLS effect.
    pub fn prepare_public_ip_probe(
        &self,
        operation_timeout: Duration,
    ) -> Result<RuntimePublicIpProbe, PublicIpProbeFailure> {
        validate_operation_timeout(operation_timeout)
            .map_err(|_| PublicIpProbeFailure::DeadlineExceeded)?;
        let permit = self
            .root_policy_effect_gate
            .acquire()
            .ok_or(PublicIpProbeFailure::RootPolicyUnavailable)?;
        let inner = PreparedPublicIpProbe::prepare(
            Arc::clone(&self.owner),
            Arc::clone(&self.resolver),
            operation_timeout,
        )?;
        Ok(RuntimePublicIpProbe {
            inner,
            effect_gate: Arc::clone(&self.root_policy_effect_gate),
            permit: Mutex::new(Some(permit)),
        })
    }

    /// Executes one generation-bound public-IP observation entirely on the shared PRODUCT Tokio
    /// runtime. Owner-bound DNS, root-policy currentness, TCP/TLS/HTTPS and final parsing remain
    /// within Rust; Android receives only the typed terminal observation.
    pub fn observe_public_egress_ip(
        &self,
        executor: &RuntimeExecutor,
        operation_timeout: Duration,
    ) -> Result<PublicEgressIpObservation, PublicIpProbeFailure> {
        let tls = ProductTlsClient::new().map_err(|_| PublicIpProbeFailure::TlsHandshake)?;
        let probe = self.prepare_public_ip_probe(operation_timeout)?;
        executor
            .block_on(execute_public_ip_probe(probe, &tls))
            .map_err(|_| PublicIpProbeFailure::Io)?
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
        validate_operation_timeout(timeout)?;
        self.root_policy_effect_gate
            .wait_quiesced(timeout)
            .ok_or(CellularRuntimeError::StateUnavailable)
    }

    pub async fn await_root_policy_quiesced_async(
        &self,
        timeout: Duration,
    ) -> Result<bool, CellularRuntimeError> {
        validate_operation_timeout(timeout)?;
        Ok(self
            .root_policy_effect_gate
            .wait_quiesced_async(timeout)
            .await)
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

    /// Returns the only PRODUCT outbound connector for Proxy Serving.
    pub fn outbound_connector(
        &self,
        operation_timeout: Duration,
    ) -> Result<Arc<dyn ProxyOutboundConnector>, CellularRuntimeError> {
        validate_operation_timeout(operation_timeout)?;
        let inner = CellularOutboundRuntimeConnector::new(
            Arc::clone(&self.owner),
            operation_timeout,
            Arc::clone(&self.resolver),
        )
        .map_err(|_| CellularRuntimeError::ConnectorUnavailable)?;
        Ok(Arc::new(RootPolicyGatedConnector {
            inner,
            effect_gate: Arc::clone(&self.root_policy_effect_gate),
        }))
    }

    fn owner(&self) -> Result<MutexGuard<'_, CellularEgress>, CellularRuntimeError> {
        self.owner
            .lock()
            .map_err(|_| CellularRuntimeError::StateUnavailable)
    }
}

fn validate_operation_timeout(timeout: Duration) -> Result<(), CellularRuntimeError> {
    if timeout.is_zero() || timeout.as_millis() > u128::from(OPERATION_TIMEOUT_MAX_MS) {
        Err(CellularRuntimeError::InvalidOperationTimeout)
    } else {
        Ok(())
    }
}

#[derive(Default)]
struct RootPolicyEffectGate {
    state: Mutex<RootPolicyEffectGateState>,
    quiesced: Condvar,
    async_quiesced: Notify,
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
            self.async_quiesced.notify_waiters();
        }
        true
    }

    fn is_ready(&self) -> bool {
        self.state.lock().is_ok_and(|state| state.ready)
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

    async fn wait_quiesced_async(&self, timeout: Duration) -> bool {
        let deadline = TokioInstant::now() + timeout;
        loop {
            if self.state.lock().is_ok_and(|state| state.in_flight == 0) {
                return true;
            }
            let notified = self.async_quiesced.notified();
            if self.state.lock().is_ok_and(|state| state.in_flight == 0) {
                return true;
            }
            let now = TokioInstant::now();
            if now >= deadline {
                return false;
            }
            if tokio_timeout(deadline - now, notified).await.is_err() {
                return false;
            }
        }
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
                self.gate.async_quiesced.notify_waiters();
            }
        }
    }
}

pub struct RuntimePublicIpProbe {
    inner: PreparedPublicIpProbe,
    effect_gate: Arc<RootPolicyEffectGate>,
    permit: Mutex<Option<RootPolicyEffectPermit>>,
}

impl RuntimePublicIpProbe {
    pub const fn host(&self) -> &'static str {
        self.inner.host()
    }

    pub const fn port(&self) -> u16 {
        self.inner.port()
    }

    pub const fn path(&self) -> &'static str {
        self.inner.path()
    }

    pub const fn response_body_max_bytes(&self) -> usize {
        self.inner.response_body_max_bytes()
    }

    pub fn generation(&self) -> u64 {
        self.inner.generation()
    }

    pub fn numeric_addresses(&self) -> Vec<String> {
        self.inner.numeric_addresses()
    }

    pub fn is_current(&self) -> bool {
        self.ensure_current_policy().is_ok()
    }

    pub fn remaining_timeout_ms(&self) -> Result<u64, PublicIpProbeFailure> {
        self.ensure_current_policy()?;
        self.inner.remaining_timeout_ms()
    }

    pub fn complete(
        &self,
        raw_body: &str,
    ) -> Result<PublicEgressIpObservation, PublicIpProbeFailure> {
        let result = (|| {
            self.ensure_current_policy()?;
            let observation = self.inner.complete(raw_body)?;
            self.ensure_current_policy()?;
            Ok(observation)
        })();
        self.release_permit();
        result
    }

    pub fn effect_failed(&self, effect: PublicIpProbeEffectFailure) -> PublicIpProbeFailure {
        let failure = match self.ensure_current_policy() {
            Ok(()) => self.inner.effect_failed(effect),
            Err(failure) => failure,
        };
        self.release_permit();
        failure
    }

    fn release_permit(&self) {
        if let Ok(mut permit) = self.permit.lock() {
            permit.take();
        }
    }

    fn ensure_current_policy(&self) -> Result<(), PublicIpProbeFailure> {
        if !self.inner.is_current() {
            return Err(PublicIpProbeFailure::StaleGeneration);
        }
        if !self.effect_gate.is_ready() {
            return Err(PublicIpProbeFailure::RootPolicyUnavailable);
        }
        Ok(())
    }
}

#[derive(Clone)]
struct RootPolicyGatedConnector {
    inner: CellularOutboundRuntimeConnector,
    effect_gate: Arc<RootPolicyEffectGate>,
}

impl ProxyOutboundConnector for RootPolicyGatedConnector {
    fn connect(&self, target: &ProxyConnectTarget) -> Result<TcpStream, ProxyOutboundConnectError> {
        let _permit = self
            .effect_gate
            .acquire()
            .ok_or(ProxyOutboundConnectError::Unavailable)?;
        self.inner.connect(target)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular::{CellularAdmissionReason, CellularNetworkAuthority};
    use std::net::{IpAddr, Ipv4Addr};

    fn sequence(raw: u64) -> ObservationSequence {
        ObservationSequence::new(raw).expect("sequence")
    }
    fn handle(raw: u64) -> NetworkHandle {
        NetworkHandle::new(raw).expect("handle")
    }

    struct StaticResolver;
    impl CellularDnsResolver for StaticResolver {
        fn resolve(
            &self,
            _authority: CellularNetworkAuthority,
            _hostname: &str,
        ) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        }
    }
    fn coordinator() -> Arc<CellularRuntimeCoordinator> {
        CellularRuntimeCoordinator::new(Arc::new(StaticResolver))
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
    fn public_ip_ticket_holds_root_policy_quiescence_until_terminal_completion() {
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

        let probe = runtime
            .prepare_public_ip_probe(Duration::from_secs(2))
            .expect("probe");
        runtime.close_root_policy_gate().expect("close gate");
        assert!(
            !runtime
                .await_root_policy_quiesced(Duration::from_millis(1))
                .expect("quiescence")
        );

        assert_eq!(
            probe.complete("198.51.100.42"),
            Err(PublicIpProbeFailure::RootPolicyUnavailable)
        );
        assert!(
            runtime
                .await_root_policy_quiesced(Duration::from_millis(50))
                .expect("quiescence after terminal completion")
        );
    }

    #[test]
    fn public_ip_ticket_rejects_same_generation_after_root_policy_gate_closes() {
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

        let probe = runtime
            .prepare_public_ip_probe(Duration::from_secs(2))
            .expect("probe");
        assert!(probe.is_current());

        runtime.close_root_policy_gate().expect("close gate");
        assert!(!probe.is_current());
        assert_eq!(
            probe.complete("198.51.100.42"),
            Err(PublicIpProbeFailure::RootPolicyUnavailable)
        );
    }

    #[test]
    fn zero_timeout_is_rejected_before_connector_creation() {
        let runtime = coordinator();
        assert!(matches!(
            runtime.outbound_connector(Duration::ZERO),
            Err(CellularRuntimeError::InvalidOperationTimeout)
        ));
    }
}
