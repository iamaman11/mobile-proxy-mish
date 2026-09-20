//! Cross-owner Mesh ingress composition.
//!
//! Transport owns endpoint admission/epoch/capacity. Proxy owns serving health. Readiness is a
//! derived owner fact. This coordinator is the only place that combines those facts into the
//! runtime effect "Mesh ingress should be running".

use crate::{ProxyServingRuntime, mesh_ingress_serving_allowed};
use mish_configuration::MeshAcceptedCidr;
use mish_proxy::canonical_listeners;
use mish_transport::{
    MeshIngressExecutor, MeshPortForward, MeshTransportCoordinator, MeshTransportError,
    MeshTransportSnapshot, MeshVpnObservation,
};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::{Arc, Mutex, MutexGuard};

pub type MeshRuntimeObserver = Arc<dyn Fn(MeshTransportSnapshot) + Send + Sync>;

struct MeshCompositionState {
    proxy: Option<Arc<ProxyServingRuntime>>,
    readiness_ready: bool,
    last_failure: Option<MeshTransportError>,
    observer: Option<MeshRuntimeObserver>,
}

/// One process-generation Mesh composition owner.
pub struct MeshCompositionCoordinator {
    transport: Arc<MeshTransportCoordinator>,
    state: Mutex<MeshCompositionState>,
}

impl MeshCompositionCoordinator {
    pub fn new() -> Result<Arc<Self>, MeshTransportError> {
        let accepted =
            MeshAcceptedCidr::deployment().map_err(|_| MeshTransportError::StateUnavailable)?;
        let transport = MeshTransportCoordinator::new(accepted.network(), accepted.prefix())
            .map_err(MeshTransportError::Owner)?;
        Ok(Arc::new(Self {
            transport,
            state: Mutex::new(MeshCompositionState {
                proxy: None,
                readiness_ready: false,
                last_failure: None,
                observer: None,
            }),
        }))
    }

    pub fn snapshot(&self) -> Result<MeshTransportSnapshot, MeshTransportError> {
        self.transport.snapshot()
    }

    pub fn set_observer(&self, observer: MeshRuntimeObserver) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        state.observer = Some(Arc::clone(&observer));
        drop(state);
        if let Ok(snapshot) = self.transport.snapshot() {
            notify_mesh(Some((observer, snapshot)));
        }
    }

    pub fn observe_vpn(
        &self,
        sequence: u64,
        observation: MeshVpnObservation,
    ) -> Result<MeshTransportSnapshot, MeshTransportError> {
        self.transport.observe_vpn(sequence, observation)?;
        self.reconcile()
    }

    pub fn install_proxy(
        &self,
        proxy: Arc<ProxyServingRuntime>,
    ) -> Result<MeshTransportSnapshot, MeshTransportError> {
        {
            let mut state = self.state()?;
            state.proxy = Some(proxy);
        }
        self.reconcile()
    }

    pub fn clear_proxy(&self) -> Result<MeshTransportSnapshot, MeshTransportError> {
        {
            let mut state = self.state()?;
            state.proxy = None;
        }
        self.reconcile()
    }

    /// Transitional input until readiness scheduling itself moves into this native generation.
    /// The value is already the Rust-owned terminal readiness projection; Kotlin may forward it,
    /// but it cannot decide Mesh serving from it.
    pub fn set_readiness_ready(
        &self,
        readiness_ready: bool,
    ) -> Result<MeshTransportSnapshot, MeshTransportError> {
        {
            let mut state = self.state()?;
            state.readiness_ready = readiness_ready;
        }
        self.reconcile()
    }

    pub fn last_failure(&self) -> Option<MeshTransportError> {
        self.state().ok().and_then(|state| state.last_failure)
    }

    pub fn shutdown(&self) -> Result<(), MeshTransportError> {
        {
            let mut state = self.state()?;
            state.proxy = None;
            state.readiness_ready = false;
        }
        let result = self.transport.stop_ingress();
        self.notify_current();
        result
    }

    fn reconcile(&self) -> Result<MeshTransportSnapshot, MeshTransportError> {
        let snapshot = self.transport.snapshot()?;
        let admission = snapshot.admission();
        let (proxy, readiness_ready) = {
            let state = self.state()?;
            (state.proxy.clone(), state.readiness_ready)
        };

        let proxy_running = proxy.as_ref().is_some_and(|proxy| proxy.is_healthy());
        let allowed = mesh_ingress_serving_allowed(
            proxy_running,
            readiness_ready,
            admission.state() == mish_transport::MeshAdmissionState::Admitted,
            admission.admission_epoch().is_some(),
        );

        let result = if allowed {
            let proxy = proxy.ok_or(MeshTransportError::IngressUnavailable)?;
            let epoch = admission
                .admission_epoch()
                .ok_or(MeshTransportError::IngressUnavailable)?;
            let mappings = proxy_transport_mappings();
            let executor: Arc<dyn MeshIngressExecutor> = proxy;
            self.transport
                .start_ingress(epoch, &mappings, executor)
                .map(|_| ())
        } else {
            self.transport.stop_ingress()
        };

        let outcome = match result {
            Ok(()) => {
                if let Ok(mut state) = self.state() {
                    state.last_failure = None;
                }
                self.transport.snapshot()
            }
            Err(error) => {
                if let Ok(mut state) = self.state() {
                    state.last_failure = Some(error);
                }
                Err(error)
            }
        };
        self.notify_current();
        outcome
    }

    fn notify_current(&self) {
        let observer = self
            .state
            .lock()
            .ok()
            .and_then(|state| state.observer.clone());
        let snapshot = self.transport.snapshot().ok();
        if let (Some(observer), Some(snapshot)) = (observer, snapshot) {
            notify_mesh(Some((observer, snapshot)));
        }
    }

    fn state(&self) -> Result<MutexGuard<'_, MeshCompositionState>, MeshTransportError> {
        self.state
            .lock()
            .map_err(|_| MeshTransportError::StateUnavailable)
    }
}

fn notify_mesh(notification: Option<(MeshRuntimeObserver, MeshTransportSnapshot)>) {
    if let Some((observer, snapshot)) = notification {
        let _ = catch_unwind(AssertUnwindSafe(|| observer(snapshot)));
    }
}

fn proxy_transport_mappings() -> Vec<MeshPortForward> {
    canonical_listeners()
        .iter()
        .map(|listener| MeshPortForward::same(listener.port))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use mish_transport::{MeshAdmissionState, MeshVpnObservation};
    use std::net::Ipv4Addr;

    #[test]
    fn vpn_admission_alone_never_starts_ingress() {
        let coordinator = MeshCompositionCoordinator::new().expect("coordinator");
        let snapshot = coordinator
            .observe_vpn(
                1,
                MeshVpnObservation::UniqueVpn {
                    local_ipv4: vec![Ipv4Addr::new(100, 96, 2, 4)],
                },
            )
            .expect("observation");
        assert_eq!(snapshot.admission().state(), MeshAdmissionState::Admitted);
        assert!(!snapshot.ingress_running());
    }

    #[test]
    fn readiness_false_remains_fail_closed_without_proxy() {
        let coordinator = MeshCompositionCoordinator::new().expect("coordinator");
        let snapshot = coordinator
            .set_readiness_ready(false)
            .expect("readiness update");
        assert!(!snapshot.ingress_running());
        assert!(coordinator.last_failure().is_none());
    }

    #[test]
    fn readiness_reconcile_publishes_owner_snapshot_without_new_vpn_observation() {
        let coordinator = MeshCompositionCoordinator::new().expect("coordinator");
        let publications = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let observed = Arc::clone(&publications);
        coordinator.set_observer(Arc::new(move |_| {
            observed.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        }));
        let baseline = publications.load(std::sync::atomic::Ordering::SeqCst);

        coordinator
            .set_readiness_ready(true)
            .expect("readiness reconcile");

        assert_eq!(
            publications.load(std::sync::atomic::Ordering::SeqCst),
            baseline + 1,
        );
    }
}
