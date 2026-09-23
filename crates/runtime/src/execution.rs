//! Single PRODUCT Tokio execution owner.
//!
//! This is the only place that creates a Tokio runtime for a live PRODUCT process. Native PRODUCT
//! generations and Proxy, Mesh, root-session, readiness and rotation components borrow this
//! executor; none of them may construct or destroy a second runtime.

use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::runtime::{Builder, Handle, Runtime};
use tokio::task::JoinHandle;

const IO_WORKER_THREADS: usize = 2;
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeExecutionError {
    ThreadUnavailable,
    StateUnavailable,
}

pub struct RuntimeExecutor {
    runtime: Mutex<Option<Runtime>>,
    active_tasks: Arc<AtomicU64>,
}

struct ActiveTaskGuard {
    active_tasks: Arc<AtomicU64>,
}

impl Drop for ActiveTaskGuard {
    fn drop(&mut self) {
        self.active_tasks.fetch_sub(1, Ordering::AcqRel);
    }
}

impl RuntimeExecutor {
    pub fn new() -> Result<Arc<Self>, RuntimeExecutionError> {
        let runtime = Builder::new_multi_thread()
            .worker_threads(IO_WORKER_THREADS)
            .thread_name("mish-runtime-io")
            .enable_io()
            .enable_time()
            .build()
            .map_err(|_| RuntimeExecutionError::ThreadUnavailable)?;
        Ok(Arc::new(Self {
            runtime: Mutex::new(Some(runtime)),
            active_tasks: Arc::new(AtomicU64::new(0)),
        }))
    }

    pub(crate) fn handle(&self) -> Result<Handle, RuntimeExecutionError> {
        self.runtime
            .lock()
            .map_err(|_| RuntimeExecutionError::StateUnavailable)?
            .as_ref()
            .map(|runtime| runtime.handle().clone())
            .ok_or(RuntimeExecutionError::StateUnavailable)
    }

    pub(crate) fn spawn<F>(&self, future: F) -> Result<JoinHandle<F::Output>, RuntimeExecutionError>
    where
        F: Future + Send + 'static,
        F::Output: Send + 'static,
    {
        let handle = self.handle()?;
        self.active_tasks.fetch_add(1, Ordering::AcqRel);
        let guard = ActiveTaskGuard {
            active_tasks: Arc::clone(&self.active_tasks),
        };
        Ok(handle.spawn(async move {
            let _guard = guard;
            future.await
        }))
    }

    pub fn active_task_count(&self) -> u64 {
        self.active_tasks.load(Ordering::Acquire)
    }

    pub(crate) fn block_on<F>(&self, future: F) -> Result<F::Output, RuntimeExecutionError>
    where
        F: Future,
    {
        Ok(self.handle()?.block_on(future))
    }

    pub fn shutdown(&self) -> Result<(), RuntimeExecutionError> {
        let runtime = self
            .runtime
            .lock()
            .map_err(|_| RuntimeExecutionError::StateUnavailable)?
            .take();
        if let Some(runtime) = runtime {
            runtime.shutdown_timeout(SHUTDOWN_TIMEOUT);
        }
        Ok(())
    }

    pub fn is_running(&self) -> bool {
        self.runtime
            .lock()
            .map(|runtime| runtime.is_some())
            .unwrap_or(false)
    }
}

impl Drop for RuntimeExecutor {
    fn drop(&mut self) {
        let runtime = self.runtime.get_mut().ok().and_then(Option::take);
        if let Some(runtime) = runtime {
            runtime.shutdown_timeout(SHUTDOWN_TIMEOUT);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn one_executor_runs_multiple_owned_tasks_and_stops_once() {
        let executor = RuntimeExecutor::new().expect("runtime");
        let first = executor.spawn(async { 11_u32 }).expect("first");
        let second = executor.spawn(async { 31_u32 }).expect("second");
        let sum = executor
            .block_on(async {
                first.await.expect("first join") + second.await.expect("second join")
            })
            .expect("block_on");
        assert_eq!(sum, 42);
        assert_eq!(executor.active_task_count(), 0);
        assert!(executor.is_running());
        executor.shutdown().expect("shutdown");
        assert!(!executor.is_running());
        assert_eq!(
            executor.handle().err(),
            Some(RuntimeExecutionError::StateUnavailable)
        );
    }

    #[test]
    fn task_counter_tracks_spawn_and_abort_without_owning_task_policy() {
        let executor = RuntimeExecutor::new().expect("runtime");
        let task = executor
            .spawn(std::future::pending::<()>())
            .expect("pending task");
        assert_eq!(executor.active_task_count(), 1);

        task.abort();
        executor
            .block_on(async {
                let _ = task.await;
            })
            .expect("join aborted task");
        assert_eq!(executor.active_task_count(), 0);

        executor.shutdown().expect("shutdown");
    }
}
