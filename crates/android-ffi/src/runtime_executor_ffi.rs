use mish_runtime::{RuntimeExecutionError as OwnerRuntimeExecutionError, RuntimeExecutor};
use std::fmt;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Error)]
pub enum NativeRuntimeExecutorError {
    ThreadUnavailable,
    StateUnavailable,
}

impl fmt::Display for NativeRuntimeExecutorError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::ThreadUnavailable => "native runtime executor threads are unavailable",
            Self::StateUnavailable => "native runtime executor state is unavailable",
        })
    }
}

impl std::error::Error for NativeRuntimeExecutorError {}

impl From<OwnerRuntimeExecutionError> for NativeRuntimeExecutorError {
    fn from(error: OwnerRuntimeExecutionError) -> Self {
        match error {
            OwnerRuntimeExecutionError::ThreadUnavailable => Self::ThreadUnavailable,
            OwnerRuntimeExecutionError::StateUnavailable => Self::StateUnavailable,
        }
    }
}

/// Opaque handle to the one PRODUCT Tokio runtime for a live process generation.
///
/// Kotlin owns only this handle lifetime. It cannot schedule arbitrary Tokio work; concrete Rust
/// components receive the internal executor through Rust-only composition methods.
#[derive(uniffi::Object)]
pub struct NativeRuntimeExecutor {
    inner: Arc<RuntimeExecutor>,
}

impl NativeRuntimeExecutor {
    pub(crate) fn runtime_handle(&self) -> Arc<RuntimeExecutor> {
        Arc::clone(&self.inner)
    }
}

#[uniffi::export]
impl NativeRuntimeExecutor {
    #[uniffi::constructor]
    pub fn new() -> Result<Arc<Self>, NativeRuntimeExecutorError> {
        Ok(Arc::new(Self {
            inner: RuntimeExecutor::new()?,
        }))
    }

    pub fn is_running(&self) -> bool {
        self.inner.is_running()
    }

    pub fn shutdown(&self) -> Result<(), NativeRuntimeExecutorError> {
        self.inner.shutdown().map_err(Into::into)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_executor_wraps_exactly_one_native_runtime() {
        let executor = NativeRuntimeExecutor::new().expect("executor");
        assert!(executor.is_running());
        executor.shutdown().expect("shutdown");
        assert!(!executor.is_running());
        assert_eq!(
            executor.shutdown(),
            Ok(()),
            "shutdown is idempotent at the FFI boundary"
        );
    }
}
