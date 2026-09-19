//! One immutable native diagnostic snapshot for the current PRODUCT generation.
//!
//! Diagnostics are observation-only. This module pins one ProductGeneration, reads every Rust-owned
//! diagnostic fact twice, and only marks the snapshot consistent when the lifecycle/generation and
//! every captured owner fact remained unchanged across the capture. Android receives one snapshot;
//! it never composes owner state or invents a generation fence.

use crate::{
    CellularDnsDiagnosticSnapshot, CellularPolicyPublication, CellularReconcileDiagnostic,
    ProductGeneration, ProductRuntimeCoordinator, ProductRuntimeSnapshot, ProxyRuntimePublication,
    ReadinessDiagnosticSnapshot, RootPolicyReconcileDiagnostic, RootRecoveryDiagnostic,
    RuntimeExecutionError,
};
use mish_cellular::CellularAdmissionSnapshot;
use mish_transport::{MeshTransportError, MeshTransportSnapshot};
use std::sync::Arc;

const DIAGNOSTIC_STABILITY_ATTEMPTS: usize = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationDiagnosticState {
    NotSupported,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProductGenerationDiagnosticSnapshot {
    pub generation: u64,
    pub cellular_admission: CellularAdmissionSnapshot,
    pub cellular_reconcile: CellularReconcileDiagnostic,
    pub dns: CellularDnsDiagnosticSnapshot,
    pub root_publication: Option<CellularPolicyPublication>,
    pub root_session_generation: Option<u64>,
    pub root_reconcile: RootPolicyReconcileDiagnostic,
    pub root_recovery: RootRecoveryDiagnostic,
    pub proxy: ProxyRuntimePublication,
    pub proxy_active_sessions: u32,
    pub mesh: Option<MeshTransportSnapshot>,
    pub mesh_failure: Option<MeshTransportError>,
    pub readiness: ReadinessDiagnosticSnapshot,
    pub rotation: RotationDiagnosticState,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProductDiagnosticSnapshot {
    pub consistent: bool,
    pub runtime: ProductRuntimeSnapshot,
    pub generation: ProductGenerationDiagnosticSnapshot,
}

impl ProductRuntimeCoordinator {
    /// Captures one generation-pinned read-only PRODUCT diagnostic snapshot.
    ///
    /// A returned snapshot never mixes owner objects from different ProductGeneration instances.
    /// If concurrently changing owner facts prevent a stable double-read after a bounded number of
    /// attempts, the latest same-generation capture is returned with consistent=false.
    pub fn diagnostic_snapshot(&self) -> Result<ProductDiagnosticSnapshot, RuntimeExecutionError> {
        self.diagnostic_snapshot_with(capture_generation)
    }

    fn diagnostic_snapshot_with<F>(
        &self,
        mut capture: F,
    ) -> Result<ProductDiagnosticSnapshot, RuntimeExecutionError>
    where
        F: FnMut(
            &Arc<ProductGeneration>,
        ) -> Result<ProductGenerationDiagnosticSnapshot, RuntimeExecutionError>,
    {
        let mut latest = None;

        for _ in 0..DIAGNOSTIC_STABILITY_ATTEMPTS {
            let generation = self.current_generation()?;
            let runtime_before = self.snapshot();
            if runtime_before.generation != generation.generation() {
                continue;
            }

            let first = capture(&generation)?;
            let second = capture(&generation)?;
            let runtime_after = self.snapshot();
            let current = self.current_generation()?;

            let same_generation = Arc::ptr_eq(&generation, &current)
                && runtime_before.generation == generation.generation()
                && runtime_after.generation == generation.generation();
            let stable = same_generation && runtime_before == runtime_after && first == second;

            let candidate = ProductDiagnosticSnapshot {
                consistent: stable,
                runtime: runtime_before,
                generation: second,
            };
            if stable {
                return Ok(candidate);
            }
            latest = Some(candidate);
        }

        latest.ok_or(RuntimeExecutionError::StateUnavailable)
    }
}

fn capture_generation(
    generation: &Arc<ProductGeneration>,
) -> Result<ProductGenerationDiagnosticSnapshot, RuntimeExecutionError> {
    let cellular = generation.cellular();
    let policy = generation.policy();
    let proxy = generation.proxy();
    let mesh = generation.mesh();
    let readiness = generation.readiness();
    let executor = generation.executor();

    let cellular_admission = cellular
        .admission_snapshot()
        .map_err(|_| RuntimeExecutionError::StateUnavailable)?;
    let cellular_reconcile = policy.reconcile_diagnostic();
    let dns = cellular.dns_diagnostic_snapshot();
    let root_publication = policy.last_publication();
    let root_session_generation = policy.root_session_generation_blocking(&executor)?;
    let root_reconcile = policy.root_policy_diagnostic_blocking(&executor)?;
    let root_recovery = policy.recovery_diagnostic();
    let proxy_snapshot = proxy.snapshot();
    let proxy_active_sessions = proxy.active_sessions();
    let mesh_snapshot = match mesh.snapshot() {
        Ok(snapshot) => (Some(snapshot), mesh.last_failure()),
        Err(error) => (None, Some(error)),
    };
    let readiness_snapshot = readiness.diagnostic_snapshot();

    Ok(ProductGenerationDiagnosticSnapshot {
        generation: generation.generation(),
        cellular_admission,
        cellular_reconcile,
        dns,
        root_publication,
        root_session_generation,
        root_reconcile,
        root_recovery,
        proxy: proxy_snapshot,
        proxy_active_sessions,
        mesh: mesh_snapshot.0,
        mesh_failure: mesh_snapshot.1,
        readiness: readiness_snapshot,
        rotation: RotationDiagnosticState::NotSupported,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::CellularDnsResolver;
    use mish_cellular::RootPolicyNamespace;
    use mish_proxy::ProxyOutboundConnectError;
    use std::net::IpAddr;

    struct EmptyResolver;

    impl CellularDnsResolver for EmptyResolver {
        fn resolve(
            &self,
            _authority: mish_cellular::CellularNetworkAuthority,
            _hostname: &str,
        ) -> Result<Vec<IpAddr>, ProxyOutboundConnectError> {
            Err(ProxyOutboundConnectError::Unavailable)
        }
    }

    fn test_runtime(uid: u32) -> Arc<ProductRuntimeCoordinator> {
        ProductRuntimeCoordinator::new(Arc::new(EmptyResolver), uid, RootPolicyNamespace::Debug)
            .expect("runtime")
    }

    #[test]
    fn diagnostic_snapshot_is_pinned_to_one_native_generation() {
        let runtime = test_runtime(10_123);

        let first = runtime.diagnostic_snapshot().expect("first snapshot");
        assert_eq!(first.runtime.generation, first.generation.generation);
        assert_eq!(
            first.generation.rotation,
            RotationDiagnosticState::NotSupported
        );

        let lease = runtime
            .begin_stopped_platform_mutation()
            .expect("lease")
            .expect("stopped mutation lease");
        assert!(
            runtime
                .complete_stopped_platform_mutation(lease, true)
                .expect("generation replacement")
        );

        let second = runtime.diagnostic_snapshot().expect("second snapshot");
        assert_eq!(second.runtime.generation, second.generation.generation);
        assert!(second.runtime.generation > first.runtime.generation);
        assert_eq!(first.runtime.generation, first.generation.generation);

        runtime.executor().shutdown().expect("executor shutdown");
    }

    #[test]
    fn generation_replacement_during_capture_never_returns_a_mixed_snapshot() {
        let runtime = test_runtime(10_124);
        let mut replaced = false;

        let snapshot = runtime
            .diagnostic_snapshot_with(|generation| {
                let captured = capture_generation(generation)?;
                if !replaced {
                    replaced = true;
                    let lease = runtime
                        .begin_stopped_platform_mutation()?
                        .ok_or(RuntimeExecutionError::StateUnavailable)?;
                    if !runtime.complete_stopped_platform_mutation(lease, true)? {
                        return Err(RuntimeExecutionError::StateUnavailable);
                    }
                }
                Ok(captured)
            })
            .expect("diagnostic snapshot");

        assert!(replaced);
        assert!(snapshot.consistent);
        assert_eq!(snapshot.runtime.generation, snapshot.generation.generation);
        assert_eq!(snapshot.runtime.generation, 2);

        runtime.executor().shutdown().expect("executor shutdown");
    }

    #[test]
    fn stable_idle_runtime_yields_consistent_atomic_snapshot() {
        let runtime = test_runtime(10_125);

        let snapshot = runtime.diagnostic_snapshot().expect("diagnostic snapshot");
        assert!(snapshot.consistent);
        assert_eq!(snapshot.runtime.generation, snapshot.generation.generation);

        runtime.executor().shutdown().expect("executor shutdown");
    }
}
