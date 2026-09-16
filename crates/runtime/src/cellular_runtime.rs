//! Vendor-neutral Cellular Egress runtime coordination.
//!
//! This module composes one `mish-cellular` natural-owner instance and one bounded root-policy
//! effect gate. Proxy Serving consumes the same owner directly through a narrow connector; there is
//! no private loopback bridge, duplicate cellular owner, DNS fallback or proxy-specific root path.

use crate::{CellularDnsResolver, CellularOutboundRuntimeConnector};
use mish_cellular::{
    CellularAdmissionSnapshot, CellularAdmissionState, CellularEgress, NetworkHandle,
    NetworkObservation, ObservationSequence,
};
use mish_proxy::{ProxyConnectTarget, ProxyOutboundConnectError, ProxyOutboundConnector};
use std::net::TcpStream;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

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
        self.owner.lock().map_err(|_| CellularRuntimeError::StateUnavailable)
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
}

#[derive(Default)]
struct RootPolicyEffectGateState {
    ready: bool,
    in_flight: usize,
}

impl RootPolicyEffectGate {
    fn set_ready(&self, ready: bool) -> bool {
        let Ok(mut state) = self.state.lock() else { return false; };
        state.ready = ready;
        if !ready && state.in_flight == 0 { self.quiesced.notify_all(); }
        true
    }

    fn acquire(self: &Arc<Self>) -> Option<RootPolicyEffectPermit> {
        let mut state = self.state.lock().ok()?;
        if !state.ready { return None; }
        state.in_flight = state.in_flight.checked_add(1)?;
        drop(state);
        Some(RootPolicyEffectPermit { gate: Arc::clone(self) })
    }

    fn wait_quiesced(&self, timeout: Duration) -> Option<bool> {
        let state = self.state.lock().ok()?;
        let (state, _) = self.quiesced.wait_timeout_while(state, timeout, |state| state.in_flight != 0).ok()?;
        Some(state.in_flight == 0)
    }
}

struct RootPolicyEffectPermit { gate: Arc<RootPolicyEffectGate> }
impl Drop for RootPolicyEffectPermit {
    fn drop(&mut self) {
        if let Ok(mut state) = self.gate.state.lock() {
            if state.in_flight == 0 { return; }
            state.in_flight -= 1;
            if state.in_flight == 0 { self.gate.quiesced.notify_all(); }
        }
    }
}

#[derive(Clone)]
struct RootPolicyGatedConnector {
    inner: CellularOutboundRuntimeConnector,
    effect_gate: Arc<RootPolicyEffectGate>,
}

impl ProxyOutboundConnector for RootPolicyGatedConnector {
    fn connect(&self, target: &ProxyConnectTarget) -> Result<TcpStream, ProxyOutboundConnectError> {
        let _permit = self.effect_gate.acquire().ok_or(ProxyOutboundConnectError::Unavailable)?;
        self.inner.connect(target)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_cellular::{CellularAdmissionReason, CellularNetworkAuthority};
    use std::net::{IpAddr, Ipv4Addr};

    fn sequence(raw: u64) -> ObservationSequence { ObservationSequence::new(raw).expect("sequence") }
    fn handle(raw: u64) -> NetworkHandle { NetworkHandle::new(raw).expect("handle") }

    struct StaticResolver;
    impl CellularDnsResolver for StaticResolver {
        fn resolve(&self, _authority: CellularNetworkAuthority, _hostname: &str) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
            Ok(vec![IpAddr::V4(Ipv4Addr::new(203, 0, 113, 9))])
        }
    }
    fn coordinator() -> Arc<CellularRuntimeCoordinator> { CellularRuntimeCoordinator::new(Arc::new(StaticResolver)) }

    #[test]
    fn admission_and_loss_delegate_to_one_cellular_owner() {
        let runtime = coordinator();
        let admitted = runtime.observe_network(NetworkObservation::new(sequence(1), handle(42), true, true, true, true)).expect("observe");
        assert_eq!(admitted.state(), CellularAdmissionState::Admitted);
        let lost = runtime.network_lost(sequence(2), handle(42)).expect("loss");
        assert_eq!(lost.state(), CellularAdmissionState::NotAdmitted);
        assert_eq!(lost.reason(), Some(CellularAdmissionReason::NetworkLost));
    }

    #[test]
    fn root_policy_gate_is_default_closed_and_generation_checked() {
        let runtime = coordinator();
        runtime.observe_network(NetworkObservation::new(sequence(1), handle(42), true, true, true, true)).expect("observe");
        assert!(runtime.authorize_root_policy(sequence(1), handle(42)).expect("authorize"));
        runtime.network_lost(sequence(2), handle(42)).expect("loss");
        assert!(!runtime.authorize_root_policy(sequence(1), handle(42)).expect("stale"));
    }

    #[test]
    fn zero_timeout_is_rejected_before_connector_creation() {
        let runtime = coordinator();
        assert!(matches!(runtime.outbound_connector(Duration::ZERO), Err(CellularRuntimeError::InvalidOperationTimeout)));
    }
}
