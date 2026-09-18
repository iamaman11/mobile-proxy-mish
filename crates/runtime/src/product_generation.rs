//! One Rust-owned PRODUCT runtime generation composed on the shared process executor.
//!
//! Android/FFI must not assemble per-generation Cellular/Proxy/Readiness/Mesh owners. This type is
//! the single native composition unit that a stable process lifecycle owner can replace.

use crate::{
    CellularDnsResolver, CellularPolicyCoordinator, CellularRuntimeCoordinator,
    MeshCompositionCoordinator, ProxyRuntimeCoordinator, ReadinessRuntimeCoordinator,
    RuntimeExecutionError, RuntimeExecutor,
};
use mish_cellular::RootPolicyNamespace;
use std::sync::Arc;
use std::time::Duration;

const PROXY_OPERATION_TIMEOUT: Duration = Duration::from_secs(15);

pub struct ProductGeneration {
    generation: u64,
    executor: Arc<RuntimeExecutor>,
    cellular: Arc<CellularRuntimeCoordinator>,
    policy: Arc<CellularPolicyCoordinator>,
    mesh: Arc<MeshCompositionCoordinator>,
    readiness: Arc<ReadinessRuntimeCoordinator>,
    proxy: Arc<ProxyRuntimeCoordinator>,
}

impl ProductGeneration {
    pub fn new(
        executor: Arc<RuntimeExecutor>,
        resolver: Arc<dyn CellularDnsResolver>,
        product_uid: u32,
        namespace: RootPolicyNamespace,
        generation: u64,
    ) -> Result<Arc<Self>, RuntimeExecutionError> {
        if generation == 0 || product_uid == 0 {
            return Err(RuntimeExecutionError::StateUnavailable);
        }

        let cellular = CellularRuntimeCoordinator::new(resolver);
        let policy = CellularPolicyCoordinator::new(
            Arc::clone(&executor),
            Arc::clone(&cellular),
            product_uid,
            namespace,
        )?;
        let mesh = MeshCompositionCoordinator::new()
            .map_err(|_| RuntimeExecutionError::StateUnavailable)?;
        let readiness = ReadinessRuntimeCoordinator::new(
            Arc::clone(&executor),
            Arc::clone(&mesh),
            generation,
        )
        .map_err(|_| RuntimeExecutionError::StateUnavailable)?;

        let readiness_cellular = Arc::clone(&readiness);
        policy.add_internal_observer(Arc::new(move |publication| {
            let _ = readiness_cellular.observe_cellular(publication);
        }));

        let proxy = ProxyRuntimeCoordinator::new(
            Arc::clone(&executor),
            Arc::clone(&cellular),
            Arc::clone(&mesh),
            Arc::clone(&readiness),
            PROXY_OPERATION_TIMEOUT,
        );

        Ok(Arc::new(Self {
            generation,
            executor,
            cellular,
            policy,
            mesh,
            readiness,
            proxy,
        }))
    }

    pub const fn generation(&self) -> u64 {
        self.generation
    }

    pub fn executor(&self) -> Arc<RuntimeExecutor> {
        Arc::clone(&self.executor)
    }

    pub fn cellular(&self) -> Arc<CellularRuntimeCoordinator> {
        Arc::clone(&self.cellular)
    }

    pub fn policy(&self) -> Arc<CellularPolicyCoordinator> {
        Arc::clone(&self.policy)
    }

    pub fn mesh(&self) -> Arc<MeshCompositionCoordinator> {
        Arc::clone(&self.mesh)
    }

    pub fn readiness(&self) -> Arc<ReadinessRuntimeCoordinator> {
        Arc::clone(&self.readiness)
    }

    pub fn proxy(&self) -> Arc<ProxyRuntimeCoordinator> {
        Arc::clone(&self.proxy)
    }

    /// Exact native generation drain. The shared process executor intentionally remains alive so a
    /// later generation can be constructed without creating a second Tokio runtime.
    pub fn shutdown_blocking(&self) -> Result<bool, RuntimeExecutionError> {
        let proxy_clean =
            self.proxy.shutdown().failure != Some(crate::ProxyServingFailure::ShutdownFailed);
        self.readiness.shutdown();
        let mesh_clean = self.mesh.shutdown().is_ok();
        let policy_clean = self.policy.shutdown_blocking(&self.executor)?;
        Ok(proxy_clean && mesh_clean && policy_clean)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
    fn one_generation_borrows_the_shared_executor_and_drains_without_destroying_it() {
        let executor = RuntimeExecutor::new().expect("executor");
        let generation = ProductGeneration::new(
            Arc::clone(&executor),
            Arc::new(EmptyResolver),
            10_123,
            RootPolicyNamespace::Debug,
            1,
        )
        .expect("generation");

        assert_eq!(generation.generation(), 1);
        assert!(executor.is_running());
        drop(generation);
        assert!(executor.is_running());
        executor.shutdown().expect("executor shutdown");
    }
}
