//! One immutable native diagnostic snapshot for the current PRODUCT generation.
//!
//! Diagnostics are observation-only. This module pins one ProductGeneration, reads every Rust-owned
//! diagnostic fact twice, and only marks the snapshot consistent when the lifecycle/generation and
//! every captured owner fact remained unchanged across the capture. Android receives one snapshot;
//! it never composes owner state or invents a generation fence.

use crate::{
    CellularDnsDiagnosticSnapshot, CellularReconcileDiagnostic, ProductGeneration,
    ProductRuntimeCoordinator, ProductRuntimeSnapshot, ProxyRuntimePublication,
    ReadinessDiagnosticSnapshot, RootPolicyReconcileDiagnostic, RootPolicyResult,
    RootRecoveryDiagnostic, RuntimeExecutionError,
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
    pub root_policy_result: Option<RootPolicyResult>,
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
        let mut latest = None;

        for _ in 0..DIAGNOSTIC_STABILITY_ATTEMPTS {
            let generation = self.current_generation()?;
            let runtime_before = self.snapshot();
            if runtime_before.generation != generation.generation() {
                continue;
            }

            let first = capture_generation(&generation)?;
            let second = capture_generation(&generation)?;
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

    let cellular_admission = cellular
        .admission_snapshot()
        .map_err(|_| RuntimeExecutionError::StateUnavailable)?;
    let cellular_reconcile = policy.reconcile_diagnostic();
    let dns = cellular.dns_diagnostic_snapshot();
    let root_policy_result = policy.last_policy_result();
    let root_reconcile =
        policy.root_policy_diagnostic_blocking(&generation.executor())?;
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
        root_policy_result,
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

    #[test]
    fn diagnostic_snapshot_is_pinned_to_one_native_generation() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");

        let first = runtime.diagnostic_snapshot().expect("first snapshot");
        assert_eq!(first.runtime.generation, first.generation.generation);
        assert_eq!(first.generation.rotation, RotationDiagnosticState::NotSupported);

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
    fn stable_idle_runtime_yields_consistent_atomic_snapshot() {
        let runtime = ProductRuntimeCoordinator::new(
            Arc::new(EmptyResolver),
            10_124,
            RootPolicyNamespace::Debug,
        )
        .expect("runtime");

        let snapshot = runtime.diagnostic_snapshot().expect("diagnostic snapshot");
        assert!(snapshot.consistent);
        assert_eq!(snapshot.runtime.generation, snapshot.generation.generation);

        runtime.executor().shutdown().expect("executor shutdown");
    }
}
