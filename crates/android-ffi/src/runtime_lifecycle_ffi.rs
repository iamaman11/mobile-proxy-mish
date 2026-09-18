use mish_runtime::{
    ProxyServingFailure as OwnerProxyServingFailure,
    ProxyServingSnapshot as OwnerProxyServingSnapshot, ProxyServingState as OwnerProxyServingState,
    RuntimeCleanupDisposition as OwnerCleanupDisposition,
    RuntimeLifecycle as OwnerRuntimeLifecycle, RuntimeLifecycleState as OwnerRuntimeLifecycleState,
    RuntimeStartAction as OwnerRuntimeStartAction,
    RuntimeStartCompletion as OwnerRuntimeStartCompletion,
    RuntimeStopAction as OwnerRuntimeStopAction,
};
use std::sync::{Arc, Mutex, MutexGuard};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RuntimeLifecycleState {
    Stopped,
    Starting,
    Running,
    Stopping,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RuntimeStartAction {
    StartNow,
    AlreadyActive,
    QueuedAfterStop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RuntimeStopAction {
    StopNow,
    AlreadyStopped,
    AlreadyStopping,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeStartCompletionView {
    pub install_fresh_generation_now: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeCleanupDispositionView {
    pub install_fresh_generation_now: bool,
    pub require_fresh_generation_before_next_explicit_start: bool,
    pub restart_now: bool,
}

/// Thin typed UniFFI projection of the `mish-runtime` foreground lifecycle natural owner.
#[derive(uniffi::Object)]
pub struct RuntimeLifecycleController {
    owner: Mutex<OwnerRuntimeLifecycle>,
}

#[uniffi::export]
impl RuntimeLifecycleController {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            owner: Mutex::new(OwnerRuntimeLifecycle::new()),
        })
    }

    pub fn state(&self) -> RuntimeLifecycleState {
        map_lifecycle_state(self.owner().state())
    }

    pub fn generation(&self) -> u64 {
        self.owner().generation()
    }

    pub fn generation_requires_replacement(&self) -> bool {
        self.owner().generation_requires_replacement()
    }

    pub fn request_start(&self) -> RuntimeStartAction {
        map_start_action(self.owner_mut().request_start())
    }

    pub fn take_generation_replacement_for_start(&self) -> bool {
        self.owner_mut().take_generation_replacement_for_start()
    }

    pub fn advance_stopped_generation(&self) -> bool {
        self.owner_mut().advance_stopped_generation()
    }

    pub fn start_submission_failed(&self) {
        self.owner_mut().start_submission_failed();
    }

    pub fn complete_start(
        &self,
        started: bool,
        clean_after_failed_start: bool,
    ) -> RuntimeStartCompletionView {
        map_start_completion(
            self.owner_mut()
                .complete_start(started, clean_after_failed_start),
        )
    }

    pub fn request_stop(&self) -> RuntimeStopAction {
        map_stop_action(self.owner_mut().request_stop())
    }

    pub fn stop_submission_failed(&self) {
        self.owner_mut().stop_submission_failed();
    }

    pub fn complete_stop(&self, clean: bool) -> RuntimeCleanupDispositionView {
        map_cleanup_disposition(self.owner_mut().complete_stop(clean))
    }

    pub fn can_mutate_stopped_generation(&self) -> bool {
        self.owner().can_mutate_stopped_generation()
    }

    pub fn mark_stopped_generation_dirty(&self) -> bool {
        self.owner_mut().mark_stopped_generation_dirty()
    }
}

impl RuntimeLifecycleController {
    fn owner(&self) -> MutexGuard<'_, OwnerRuntimeLifecycle> {
        self.owner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn owner_mut(&self) -> MutexGuard<'_, OwnerRuntimeLifecycle> {
        self.owner()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProxyServingState {
    Stopped,
    Starting,
    Running,
    Failed,
}

/// Exact projection of the Rust Runtime Lifecycle failure vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ProxyServingFailure {
    NativeRuntimeMissing,
    ExternalCredentialUnavailable,
    CellularConnectorUnavailable,
    ProxyConfigurationRejected,
    MixedListenerUnavailable,
    Socks5ListenerUnavailable,
    HttpConnectListenerUnavailable,
    ExecutorUnavailable,
    RuntimeStateUnavailable,
    ServingUnhealthy,
    ShutdownFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct ProxyServingSnapshotView {
    pub state: ProxyServingState,
    pub failure: Option<ProxyServingFailure>,
}

pub(crate) fn map_lifecycle_state(state: OwnerRuntimeLifecycleState) -> RuntimeLifecycleState {
    match state {
        OwnerRuntimeLifecycleState::Stopped => RuntimeLifecycleState::Stopped,
        OwnerRuntimeLifecycleState::Starting => RuntimeLifecycleState::Starting,
        OwnerRuntimeLifecycleState::Running => RuntimeLifecycleState::Running,
        OwnerRuntimeLifecycleState::Stopping => RuntimeLifecycleState::Stopping,
    }
}

pub(crate) fn map_start_action(action: OwnerRuntimeStartAction) -> RuntimeStartAction {
    match action {
        OwnerRuntimeStartAction::StartNow => RuntimeStartAction::StartNow,
        OwnerRuntimeStartAction::AlreadyActive => RuntimeStartAction::AlreadyActive,
        OwnerRuntimeStartAction::QueuedAfterStop => RuntimeStartAction::QueuedAfterStop,
    }
}

pub(crate) fn map_stop_action(action: OwnerRuntimeStopAction) -> RuntimeStopAction {
    match action {
        OwnerRuntimeStopAction::StopNow => RuntimeStopAction::StopNow,
        OwnerRuntimeStopAction::AlreadyStopped => RuntimeStopAction::AlreadyStopped,
        OwnerRuntimeStopAction::AlreadyStopping => RuntimeStopAction::AlreadyStopping,
    }
}

fn map_start_completion(completion: OwnerRuntimeStartCompletion) -> RuntimeStartCompletionView {
    RuntimeStartCompletionView {
        install_fresh_generation_now: completion.install_fresh_generation_now(),
    }
}

fn map_cleanup_disposition(disposition: OwnerCleanupDisposition) -> RuntimeCleanupDispositionView {
    RuntimeCleanupDispositionView {
        install_fresh_generation_now: disposition.install_fresh_generation_now(),
        require_fresh_generation_before_next_explicit_start: disposition
            .require_fresh_generation_before_next_explicit_start(),
        restart_now: disposition.restart_now(),
    }
}

pub(crate) fn map_proxy_snapshot(snapshot: OwnerProxyServingSnapshot) -> ProxyServingSnapshotView {
    ProxyServingSnapshotView {
        state: match snapshot.state() {
            OwnerProxyServingState::Stopped => ProxyServingState::Stopped,
            OwnerProxyServingState::Starting => ProxyServingState::Starting,
            OwnerProxyServingState::Running => ProxyServingState::Running,
            OwnerProxyServingState::Failed => ProxyServingState::Failed,
        },
        failure: snapshot.failure().map(map_proxy_failure_out),
    }
}

pub(crate) const fn map_proxy_failure_out(
    failure: OwnerProxyServingFailure,
) -> ProxyServingFailure {
    match failure {
        OwnerProxyServingFailure::NativeRuntimeMissing => ProxyServingFailure::NativeRuntimeMissing,
        OwnerProxyServingFailure::ExternalCredentialUnavailable => {
            ProxyServingFailure::ExternalCredentialUnavailable
        }
        OwnerProxyServingFailure::CellularConnectorUnavailable => {
            ProxyServingFailure::CellularConnectorUnavailable
        }
        OwnerProxyServingFailure::ProxyConfigurationRejected => {
            ProxyServingFailure::ProxyConfigurationRejected
        }
        OwnerProxyServingFailure::MixedListenerUnavailable => {
            ProxyServingFailure::MixedListenerUnavailable
        }
        OwnerProxyServingFailure::Socks5ListenerUnavailable => {
            ProxyServingFailure::Socks5ListenerUnavailable
        }
        OwnerProxyServingFailure::HttpConnectListenerUnavailable => {
            ProxyServingFailure::HttpConnectListenerUnavailable
        }
        OwnerProxyServingFailure::ExecutorUnavailable => ProxyServingFailure::ExecutorUnavailable,
        OwnerProxyServingFailure::RuntimeStateUnavailable => {
            ProxyServingFailure::RuntimeStateUnavailable
        }
        OwnerProxyServingFailure::ServingUnhealthy => ProxyServingFailure::ServingUnhealthy,
        OwnerProxyServingFailure::ShutdownFailed => ProxyServingFailure::ShutdownFailed,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_lifecycle_projection_delegates_generation_to_runtime_owner() {
        let controller = RuntimeLifecycleController::new();
        assert_eq!(controller.generation(), 1);
        assert_eq!(controller.state(), RuntimeLifecycleState::Stopped);
        assert_eq!(controller.request_start(), RuntimeStartAction::StartNow);
        assert_eq!(
            controller.request_start(),
            RuntimeStartAction::AlreadyActive
        );
        assert!(
            !controller
                .complete_start(true, true)
                .install_fresh_generation_now
        );
        assert_eq!(controller.state(), RuntimeLifecycleState::Running);
        assert_eq!(controller.request_stop(), RuntimeStopAction::StopNow);
        let disposition = controller.complete_stop(true);
        assert!(disposition.install_fresh_generation_now);
        assert_eq!(controller.generation(), 2);
    }

    #[test]
    fn ffi_stopped_generation_cutover_is_owner_authorized() {
        let controller = RuntimeLifecycleController::new();
        assert!(controller.can_mutate_stopped_generation());
        assert!(controller.advance_stopped_generation());
        assert_eq!(controller.generation(), 2);
    }

    #[test]
    fn ffi_proxy_failure_projection_preserves_every_native_failure_reason() {
        for (owner, projected) in [
            (
                OwnerProxyServingFailure::NativeRuntimeMissing,
                ProxyServingFailure::NativeRuntimeMissing,
            ),
            (
                OwnerProxyServingFailure::ExternalCredentialUnavailable,
                ProxyServingFailure::ExternalCredentialUnavailable,
            ),
            (
                OwnerProxyServingFailure::CellularConnectorUnavailable,
                ProxyServingFailure::CellularConnectorUnavailable,
            ),
            (
                OwnerProxyServingFailure::ProxyConfigurationRejected,
                ProxyServingFailure::ProxyConfigurationRejected,
            ),
            (
                OwnerProxyServingFailure::MixedListenerUnavailable,
                ProxyServingFailure::MixedListenerUnavailable,
            ),
            (
                OwnerProxyServingFailure::Socks5ListenerUnavailable,
                ProxyServingFailure::Socks5ListenerUnavailable,
            ),
            (
                OwnerProxyServingFailure::HttpConnectListenerUnavailable,
                ProxyServingFailure::HttpConnectListenerUnavailable,
            ),
            (
                OwnerProxyServingFailure::ExecutorUnavailable,
                ProxyServingFailure::ExecutorUnavailable,
            ),
            (
                OwnerProxyServingFailure::RuntimeStateUnavailable,
                ProxyServingFailure::RuntimeStateUnavailable,
            ),
            (
                OwnerProxyServingFailure::ServingUnhealthy,
                ProxyServingFailure::ServingUnhealthy,
            ),
            (
                OwnerProxyServingFailure::ShutdownFailed,
                ProxyServingFailure::ShutdownFailed,
            ),
        ] {
            assert_eq!(map_proxy_failure_out(owner), projected);
        }
    }
}
