//! One Rust-owned PRODUCT runtime generation composed on the shared process executor.
//!
//! Android/FFI must not assemble per-generation Cellular/Proxy/Readiness/Mesh owners. This type is
//! the single native composition unit that a stable process lifecycle owner can replace.

use crate::{
    CellularDnsResolver, CellularPolicyCoordinator, CellularRuntimeCoordinator,
    MeshCompositionCoordinator, ProxyRuntimeCoordinator, ReadinessRuntimeCoordinator,
    RotationRuntimeCoordinator, RuntimeExecutionError, RuntimeExecutor,
};
use mish_cellular::RootPolicyNamespace;
use std::future::Future;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::OnceCell;
use tokio::task::spawn_blocking;

const PROXY_OPERATION_TIMEOUT: Duration = Duration::from_secs(15);

pub struct ProductGeneration {
    generation: u64,
    executor: Arc<RuntimeExecutor>,
    cellular: Arc<CellularRuntimeCoordinator>,
    policy: Arc<CellularPolicyCoordinator>,
    mesh: Arc<MeshCompositionCoordinator>,
    readiness: Arc<ReadinessRuntimeCoordinator>,
    proxy: Arc<ProxyRuntimeCoordinator>,
    rotation: Arc<RotationRuntimeCoordinator>,
    shutdown_result: OnceCell<bool>,
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
        let readiness =
            ReadinessRuntimeCoordinator::new(Arc::clone(&executor), Arc::clone(&mesh), generation)
                .map_err(|_| RuntimeExecutionError::StateUnavailable)?;

        let readiness_admission = Arc::clone(&readiness);
        policy.add_internal_admission_observer(Arc::new(move |admission| {
            let _ = readiness_admission.observe_cellular_admission(admission);
        }));

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
        let rotation = RotationRuntimeCoordinator::new(
            Arc::clone(&executor),
            Arc::clone(&cellular),
            Arc::clone(&policy),
            Arc::clone(&proxy),
        );

        Ok(Arc::new(Self {
            generation,
            executor,
            cellular,
            policy,
            mesh,
            readiness,
            proxy,
            rotation,
            shutdown_result: OnceCell::new(),
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

    pub fn rotation(&self) -> Arc<RotationRuntimeCoordinator> {
        Arc::clone(&self.rotation)
    }

    /// Exact native generation drain. Concurrent callers share one cleanup execution and one
    /// terminal result; the shared process executor intentionally remains alive so a later
    /// generation can be constructed without creating a second Tokio runtime.
    pub async fn shutdown_async(&self) -> bool {
        run_shutdown_once(&self.shutdown_result, || async {
            let rotation_clean = self.rotation.shutdown().await;

            let proxy = Arc::clone(&self.proxy);
            let proxy_clean = spawn_blocking(move || {
                proxy.shutdown().failure != Some(crate::ProxyServingFailure::ShutdownFailed)
            })
            .await
            .unwrap_or(false);

            self.readiness.shutdown();

            let mesh = Arc::clone(&self.mesh);
            let mesh_clean = spawn_blocking(move || mesh.shutdown().is_ok())
                .await
                .unwrap_or(false);

            let policy_clean = self.policy.shutdown().await;
            rotation_clean && proxy_clean && mesh_clean && policy_clean
        })
        .await
    }

    pub fn shutdown_blocking(&self) -> Result<bool, RuntimeExecutionError> {
        self.executor.block_on(self.shutdown_async())
    }
}

async fn run_shutdown_once<F, Fut>(result: &OnceCell<bool>, operation: F) -> bool
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = bool>,
{
    *result.get_or_init(operation).await
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
    fn concurrent_generation_shutdown_callers_share_one_execution_and_result() {
        use std::sync::atomic::{AtomicUsize, Ordering};

        let executor = RuntimeExecutor::new().expect("executor");
        let executions = Arc::new(AtomicUsize::new(0));
        let result = Arc::new(OnceCell::new());
        let started = Arc::new(tokio::sync::Notify::new());
        let release = Arc::new(tokio::sync::Notify::new());

        let first_result = Arc::clone(&result);
        let first_executions = Arc::clone(&executions);
        let first_started = Arc::clone(&started);
        let first_release = Arc::clone(&release);
        let first = executor
            .spawn(async move {
                run_shutdown_once(&first_result, || async move {
                    first_executions.fetch_add(1, Ordering::SeqCst);
                    first_started.notify_one();
                    first_release.notified().await;
                    true
                })
                .await
            })
            .expect("first shutdown caller");

        executor
            .block_on(started.notified())
            .expect("first cleanup entered");

        let second_result = Arc::clone(&result);
        let second_executions = Arc::clone(&executions);
        let second = executor
            .spawn(async move {
                run_shutdown_once(&second_result, || async move {
                    second_executions.fetch_add(1, Ordering::SeqCst);
                    false
                })
                .await
            })
            .expect("second shutdown caller");

        release.notify_one();
        let (first_value, second_value) = executor
            .block_on(async {
                (
                    first.await.expect("first join"),
                    second.await.expect("second join"),
                )
            })
            .expect("await callers");

        assert!(first_value);
        assert!(second_value);
        assert_eq!(executions.load(Ordering::SeqCst), 1);
        executor.shutdown().expect("executor shutdown");
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
