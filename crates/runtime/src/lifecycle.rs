//! Vendor-neutral Runtime Lifecycle natural-owner state machines.
//!
//! Android services/process APIs execute effects, but all start/stop/restart/generation and
//! owned-child lifecycle decisions live here. No Android, sing-box, UI, persistence, or root
//! mechanism is imported by this module.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeLifecycleState {
    Stopped,
    Starting,
    Running,
    Stopping,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeStartAction {
    StartNow,
    AlreadyActive,
    QueuedAfterStop,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeStopAction {
    StopNow,
    AlreadyStopped,
    AlreadyStopping,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeStartCompletion {
    install_fresh_generation_now: bool,
}

impl RuntimeStartCompletion {
    pub const fn install_fresh_generation_now(self) -> bool {
        self.install_fresh_generation_now
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeCleanupDisposition {
    install_fresh_generation_now: bool,
    require_fresh_generation_before_next_explicit_start: bool,
    restart_now: bool,
}

impl RuntimeCleanupDisposition {
    pub const fn install_fresh_generation_now(self) -> bool {
        self.install_fresh_generation_now
    }

    pub const fn require_fresh_generation_before_next_explicit_start(self) -> bool {
        self.require_fresh_generation_before_next_explicit_start
    }

    pub const fn restart_now(self) -> bool {
        self.restart_now
    }
}

/// Natural owner of the foreground runtime generation lifecycle.
///
/// Effects are deliberately absent. The Android adapter requests transitions, executes the
/// concrete generation/process cleanup or startup effect, then publishes the typed outcome here.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeLifecycle {
    state: RuntimeLifecycleState,
    restart_after_stop: bool,
    generation_requires_replacement: bool,
}

impl Default for RuntimeLifecycle {
    fn default() -> Self {
        Self::new()
    }
}

impl RuntimeLifecycle {
    pub const fn new() -> Self {
        Self {
            state: RuntimeLifecycleState::Stopped,
            restart_after_stop: false,
            generation_requires_replacement: false,
        }
    }

    pub const fn state(self) -> RuntimeLifecycleState {
        self.state
    }

    pub const fn generation_requires_replacement(self) -> bool {
        self.generation_requires_replacement
    }

    pub fn request_start(&mut self) -> RuntimeStartAction {
        match self.state {
            RuntimeLifecycleState::Stopped => {
                self.state = RuntimeLifecycleState::Starting;
                RuntimeStartAction::StartNow
            }
            RuntimeLifecycleState::Starting | RuntimeLifecycleState::Running => {
                RuntimeStartAction::AlreadyActive
            }
            RuntimeLifecycleState::Stopping => {
                self.restart_after_stop = true;
                RuntimeStartAction::QueuedAfterStop
            }
        }
    }

    /// Claims a replacement required by an earlier failed cleanup only from an explicit start.
    /// The caller must report a failed start if replacement/effects cannot be completed.
    pub fn take_generation_replacement_for_start(&mut self) -> bool {
        if self.state != RuntimeLifecycleState::Starting || !self.generation_requires_replacement {
            return false;
        }
        self.generation_requires_replacement = false;
        true
    }

    /// Submission failed before any start effect executed. No automatic retry is introduced.
    pub fn start_submission_failed(&mut self) {
        if self.state == RuntimeLifecycleState::Starting {
            self.state = RuntimeLifecycleState::Stopped;
        }
    }

    /// Publishes the result of one start effect sequence.
    ///
    /// If stop was requested while startup was executing, the state remains STOPPING and the
    /// queued stop effect owns cleanup. Otherwise a failed startup may install a fresh generation
    /// only after exact cleanup succeeded.
    pub fn complete_start(
        &mut self,
        started: bool,
        clean_after_failed_start: bool,
    ) -> RuntimeStartCompletion {
        if self.state != RuntimeLifecycleState::Starting {
            return RuntimeStartCompletion {
                install_fresh_generation_now: false,
            };
        }

        if started {
            self.state = RuntimeLifecycleState::Running;
            RuntimeStartCompletion {
                install_fresh_generation_now: false,
            }
        } else {
            self.state = RuntimeLifecycleState::Stopped;
            self.generation_requires_replacement = !clean_after_failed_start;
            RuntimeStartCompletion {
                install_fresh_generation_now: clean_after_failed_start,
            }
        }
    }

    pub fn request_stop(&mut self) -> RuntimeStopAction {
        match self.state {
            RuntimeLifecycleState::Stopped => RuntimeStopAction::AlreadyStopped,
            RuntimeLifecycleState::Stopping => RuntimeStopAction::AlreadyStopping,
            RuntimeLifecycleState::Starting | RuntimeLifecycleState::Running => {
                self.state = RuntimeLifecycleState::Stopping;
                RuntimeStopAction::StopNow
            }
        }
    }

    /// Executor rejection means cleanup never ran. Keep STOPPING as terminal fail-closed state.
    pub fn stop_submission_failed(&mut self) {
        if self.state == RuntimeLifecycleState::Stopping {
            self.restart_after_stop = false;
        }
    }

    pub fn complete_stop(&mut self, clean: bool) -> RuntimeCleanupDisposition {
        let restart_requested = self.restart_after_stop;
        self.restart_after_stop = false;
        self.state = RuntimeLifecycleState::Stopped;

        let disposition = if clean {
            RuntimeCleanupDisposition {
                install_fresh_generation_now: true,
                require_fresh_generation_before_next_explicit_start: false,
                restart_now: restart_requested,
            }
        } else {
            RuntimeCleanupDisposition {
                install_fresh_generation_now: false,
                require_fresh_generation_before_next_explicit_start: true,
                restart_now: false,
            }
        };
        self.generation_requires_replacement =
            disposition.require_fresh_generation_before_next_explicit_start;
        disposition
    }

    pub fn can_mutate_stopped_generation(self) -> bool {
        self.state == RuntimeLifecycleState::Stopped && !self.generation_requires_replacement
    }

    pub fn mark_stopped_generation_dirty(&mut self) -> bool {
        if self.state != RuntimeLifecycleState::Stopped {
            return false;
        }
        self.generation_requires_replacement = true;
        true
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RuntimeProcessState {
    Stopped,
    Starting,
    Running,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeProcessSnapshot {
    state: RuntimeProcessState,
    failure: Option<RuntimeProcessFailure>,
}

impl RuntimeProcessSnapshot {
    pub const fn state(self) -> RuntimeProcessState {
        self.state
    }

    pub const fn failure(self) -> Option<RuntimeProcessFailure> {
        self.failure
    }
}

/// Natural-owner state machine for one supervised owned child process generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeProcessLifecycle {
    snapshot: RuntimeProcessSnapshot,
}

impl Default for RuntimeProcessLifecycle {
    fn default() -> Self {
        Self::new()
    }
}

impl RuntimeProcessLifecycle {
    pub const fn new() -> Self {
        Self {
            snapshot: RuntimeProcessSnapshot {
                state: RuntimeProcessState::Stopped,
                failure: None,
            },
        }
    }

    pub const fn snapshot(self) -> RuntimeProcessSnapshot {
        self.snapshot
    }

    pub fn request_start(&mut self) -> bool {
        match self.snapshot.state {
            RuntimeProcessState::Starting | RuntimeProcessState::Running => false,
            RuntimeProcessState::Stopped | RuntimeProcessState::Failed => {
                self.snapshot = RuntimeProcessSnapshot {
                    state: RuntimeProcessState::Starting,
                    failure: None,
                };
                true
            }
        }
    }

    pub fn mark_running(&mut self) -> bool {
        if self.snapshot.state != RuntimeProcessState::Starting {
            return false;
        }
        self.snapshot = RuntimeProcessSnapshot {
            state: RuntimeProcessState::Running,
            failure: None,
        };
        true
    }

    pub fn mark_failed(&mut self, failure: RuntimeProcessFailure) {
        self.snapshot = RuntimeProcessSnapshot {
            state: RuntimeProcessState::Failed,
            failure: Some(failure),
        };
    }

    pub fn mark_stopped(&mut self) {
        self.snapshot = RuntimeProcessSnapshot {
            state: RuntimeProcessState::Stopped,
            failure: None,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn duplicate_start_is_idempotent_and_stop_race_queues_restart() {
        let mut owner = RuntimeLifecycle::new();
        assert_eq!(owner.request_start(), RuntimeStartAction::StartNow);
        assert_eq!(owner.request_start(), RuntimeStartAction::AlreadyActive);
        assert_eq!(owner.request_stop(), RuntimeStopAction::StopNow);
        assert_eq!(owner.request_start(), RuntimeStartAction::QueuedAfterStop);

        let disposition = owner.complete_stop(true);
        assert!(disposition.install_fresh_generation_now());
        assert!(disposition.restart_now());
        assert_eq!(owner.state(), RuntimeLifecycleState::Stopped);
    }

    #[test]
    fn failed_cleanup_never_installs_fresh_generation_or_auto_restarts() {
        let mut owner = RuntimeLifecycle::new();
        assert_eq!(owner.request_start(), RuntimeStartAction::StartNow);
        assert!(
            !owner
                .complete_start(true, true)
                .install_fresh_generation_now()
        );
        assert_eq!(owner.request_stop(), RuntimeStopAction::StopNow);
        assert_eq!(owner.request_start(), RuntimeStartAction::QueuedAfterStop);

        let disposition = owner.complete_stop(false);
        assert!(!disposition.install_fresh_generation_now());
        assert!(disposition.require_fresh_generation_before_next_explicit_start());
        assert!(!disposition.restart_now());
        assert!(owner.generation_requires_replacement());
    }

    #[test]
    fn dirty_generation_is_replaced_only_by_later_explicit_start() {
        let mut owner = RuntimeLifecycle::new();
        assert!(owner.mark_stopped_generation_dirty());
        assert!(owner.generation_requires_replacement());
        assert_eq!(owner.request_start(), RuntimeStartAction::StartNow);
        assert!(owner.take_generation_replacement_for_start());
        assert!(!owner.generation_requires_replacement());
        assert!(
            !owner
                .complete_start(true, true)
                .install_fresh_generation_now()
        );
        assert_eq!(owner.state(), RuntimeLifecycleState::Running);
    }

    #[test]
    fn failed_start_cleanup_controls_generation_replacement() {
        let mut clean = RuntimeLifecycle::new();
        clean.request_start();
        let clean_completion = clean.complete_start(false, true);
        assert!(clean_completion.install_fresh_generation_now());
        assert!(!clean.generation_requires_replacement());

        let mut dirty = RuntimeLifecycle::new();
        dirty.request_start();
        let dirty_completion = dirty.complete_start(false, false);
        assert!(!dirty_completion.install_fresh_generation_now());
        assert!(dirty.generation_requires_replacement());
    }

    #[test]
    fn stop_submission_failure_remains_stopping_and_suppresses_restart() {
        let mut owner = RuntimeLifecycle::new();
        owner.request_start();
        owner.complete_start(true, true);
        owner.request_stop();
        owner.request_start();
        owner.stop_submission_failed();
        assert_eq!(owner.state(), RuntimeLifecycleState::Stopping);
        let disposition = owner.complete_stop(true);
        assert!(!disposition.restart_now());
    }

    #[test]
    fn child_process_lifecycle_is_owner_state_not_adapter_state() {
        let mut owner = RuntimeProcessLifecycle::new();
        assert_eq!(owner.snapshot().state(), RuntimeProcessState::Stopped);
        assert!(owner.request_start());
        assert!(!owner.request_start());
        assert!(owner.mark_running());
        owner.mark_failed(RuntimeProcessFailure::ChildExited);
        assert_eq!(owner.snapshot().state(), RuntimeProcessState::Failed);
        assert_eq!(
            owner.snapshot().failure(),
            Some(RuntimeProcessFailure::ChildExited)
        );
        assert!(owner.request_start());
        owner.mark_stopped();
        assert_eq!(owner.snapshot().state(), RuntimeProcessState::Stopped);
        assert_eq!(owner.snapshot().failure(), None);
    }
}
