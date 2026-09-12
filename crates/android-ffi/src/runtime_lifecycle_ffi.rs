use mish_runtime::{
    RuntimeCleanupDisposition as OwnerCleanupDisposition,
    RuntimeLifecycle as OwnerRuntimeLifecycle, RuntimeLifecycleState as OwnerRuntimeLifecycleState,
    RuntimeProcessFailure as OwnerRuntimeProcessFailure,
    RuntimeProcessLifecycle as OwnerRuntimeProcessLifecycle,
    RuntimeProcessSnapshot as OwnerRuntimeProcessSnapshot,
    RuntimeProcessState as OwnerRuntimeProcessState, RuntimeStartAction as OwnerRuntimeStartAction,
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

    /// Exact monotonic key of the currently installed Android runtime effect generation.
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
pub enum RuntimeProcessState {
    Stopped,
    Starting,
    Running,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RuntimeProcessFailure {
    NativeRuntimeMissing,
    StaleProcessIdentityMismatch,
    ExternalCredentialUnavailable,
    PrivateBridgeUnavailable,
    ConfigurationRejected,
    ChildLaunchFailed,
    HealthCheckFailed,
    ChildExited,
    PrivateBridgeUnhealthy,
    CleanupFailed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Record)]
pub struct RuntimeProcessSnapshotView {
    pub state: RuntimeProcessState,
    pub failure: Option<RuntimeProcessFailure>,
}

/// Thin typed UniFFI projection of one owned child-process lifecycle state machine.
#[derive(uniffi::Object)]
pub struct RuntimeProcessLifecycleController {
    owner: Mutex<OwnerRuntimeProcessLifecycle>,
}

#[uniffi::export]
impl RuntimeProcessLifecycleController {
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            owner: Mutex::new(OwnerRuntimeProcessLifecycle::new()),
        })
    }

    pub fn snapshot(&self) -> RuntimeProcessSnapshotView {
        map_process_snapshot(self.owner().snapshot())
    }

    pub fn request_start(&self) -> bool {
        self.owner_mut().request_start()
    }

    pub fn mark_running(&self) -> bool {
        self.owner_mut().mark_running()
    }

    pub fn mark_failed(&self, failure: RuntimeProcessFailure) {
        self.owner_mut()
            .mark_failed(map_process_failure_in(failure));
    }

    pub fn mark_stopped(&self) {
        self.owner_mut().mark_stopped();
    }
}

impl RuntimeProcessLifecycleController {
    fn owner(&self) -> MutexGuard<'_, OwnerRuntimeProcessLifecycle> {
        self.owner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn owner_mut(&self) -> MutexGuard<'_, OwnerRuntimeProcessLifecycle> {
        self.owner()
    }
}

fn map_lifecycle_state(state: OwnerRuntimeLifecycleState) -> RuntimeLifecycleState {
    match state {
        OwnerRuntimeLifecycleState::Stopped => RuntimeLifecycleState::Stopped,
        OwnerRuntimeLifecycleState::Starting => RuntimeLifecycleState::Starting,
        OwnerRuntimeLifecycleState::Running => RuntimeLifecycleState::Running,
        OwnerRuntimeLifecycleState::Stopping => RuntimeLifecycleState::Stopping,
    }
}

fn map_start_action(action: OwnerRuntimeStartAction) -> RuntimeStartAction {
    match action {
        OwnerRuntimeStartAction::StartNow => RuntimeStartAction::StartNow,
        OwnerRuntimeStartAction::AlreadyActive => RuntimeStartAction::AlreadyActive,
        OwnerRuntimeStartAction::QueuedAfterStop => RuntimeStartAction::QueuedAfterStop,
    }
}

fn map_stop_action(action: OwnerRuntimeStopAction) -> RuntimeStopAction {
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

fn map_process_snapshot(snapshot: OwnerRuntimeProcessSnapshot) -> RuntimeProcessSnapshotView {
    RuntimeProcessSnapshotView {
        state: match snapshot.state() {
            OwnerRuntimeProcessState::Stopped => RuntimeProcessState::Stopped,
            OwnerRuntimeProcessState::Starting => RuntimeProcessState::Starting,
            OwnerRuntimeProcessState::Running => RuntimeProcessState::Running,
            OwnerRuntimeProcessState::Failed => RuntimeProcessState::Failed,
        },
        failure: snapshot.failure().map(map_process_failure_out),
    }
}

fn map_process_failure_out(failure: OwnerRuntimeProcessFailure) -> RuntimeProcessFailure {
    match failure {
        OwnerRuntimeProcessFailure::NativeRuntimeMissing => {
            RuntimeProcessFailure::NativeRuntimeMissing
        }
        OwnerRuntimeProcessFailure::StaleProcessIdentityMismatch => {
            RuntimeProcessFailure::StaleProcessIdentityMismatch
        }
        OwnerRuntimeProcessFailure::ExternalCredentialUnavailable => {
            RuntimeProcessFailure::ExternalCredentialUnavailable
        }
        OwnerRuntimeProcessFailure::PrivateBridgeUnavailable => {
            RuntimeProcessFailure::PrivateBridgeUnavailable
        }
        OwnerRuntimeProcessFailure::ConfigurationRejected => {
            RuntimeProcessFailure::ConfigurationRejected
        }
        OwnerRuntimeProcessFailure::ChildLaunchFailed => RuntimeProcessFailure::ChildLaunchFailed,
        OwnerRuntimeProcessFailure::HealthCheckFailed => RuntimeProcessFailure::HealthCheckFailed,
        OwnerRuntimeProcessFailure::ChildExited => RuntimeProcessFailure::ChildExited,
        OwnerRuntimeProcessFailure::PrivateBridgeUnhealthy => {
            RuntimeProcessFailure::PrivateBridgeUnhealthy
        }
        OwnerRuntimeProcessFailure::CleanupFailed => RuntimeProcessFailure::CleanupFailed,
    }
}

fn map_process_failure_in(failure: RuntimeProcessFailure) -> OwnerRuntimeProcessFailure {
    match failure {
        RuntimeProcessFailure::NativeRuntimeMissing => {
            OwnerRuntimeProcessFailure::NativeRuntimeMissing
        }
        RuntimeProcessFailure::StaleProcessIdentityMismatch => {
            OwnerRuntimeProcessFailure::StaleProcessIdentityMismatch
        }
        RuntimeProcessFailure::ExternalCredentialUnavailable => {
            OwnerRuntimeProcessFailure::ExternalCredentialUnavailable
        }
        RuntimeProcessFailure::PrivateBridgeUnavailable => {
            OwnerRuntimeProcessFailure::PrivateBridgeUnavailable
        }
        RuntimeProcessFailure::ConfigurationRejected => {
            OwnerRuntimeProcessFailure::ConfigurationRejected
        }
        RuntimeProcessFailure::ChildLaunchFailed => OwnerRuntimeProcessFailure::ChildLaunchFailed,
        RuntimeProcessFailure::HealthCheckFailed => OwnerRuntimeProcessFailure::HealthCheckFailed,
        RuntimeProcessFailure::ChildExited => OwnerRuntimeProcessFailure::ChildExited,
        RuntimeProcessFailure::PrivateBridgeUnhealthy => {
            OwnerRuntimeProcessFailure::PrivateBridgeUnhealthy
        }
        RuntimeProcessFailure::CleanupFailed => OwnerRuntimeProcessFailure::CleanupFailed,
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
    fn ffi_process_projection_preserves_failure_reason() {
        let controller = RuntimeProcessLifecycleController::new();
        assert!(controller.request_start());
        assert!(controller.mark_running());
        controller.mark_failed(RuntimeProcessFailure::ChildExited);
        assert_eq!(
            controller.snapshot(),
            RuntimeProcessSnapshotView {
                state: RuntimeProcessState::Failed,
                failure: Some(RuntimeProcessFailure::ChildExited),
            }
        );
    }
}
