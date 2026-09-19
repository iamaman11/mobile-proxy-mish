//! Single PRODUCT Tokio execution owner.
//!
//! This is the only place that creates a Tokio runtime for a live PRODUCT process generation.
//! Proxy, Mesh, root-session, readiness and rotation components borrow this executor; none of
//! them may construct or destroy a second runtime.

use std::future::Future;
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
        Ok(self.handle()?.spawn(future))
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
        assert!(executor.is_running());
        executor.shutdown().expect("shutdown");
        assert!(!executor.is_running());
        assert_eq!(
            executor.handle().err(),
            Some(RuntimeExecutionError::StateUnavailable)
        );
    }
}
