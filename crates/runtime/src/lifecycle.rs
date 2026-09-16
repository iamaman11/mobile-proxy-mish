//! Vendor-neutral Runtime Lifecycle natural owners.
//!
//! Android executes effects. This module owns the state transitions and typed PRODUCT semantics for
//! runtime generations and native Proxy Serving. It imports no Android, UI, persistence or root
//! mechanism.

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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RuntimeLifecycle {
    state: RuntimeLifecycleState,
    restart_after_stop: bool,
    generation_requires_replacement: bool,
    generation: u64,
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
            generation: 1,
        }
    }

    pub const fn state(self) -> RuntimeLifecycleState {
        self.state
    }

    pub const fn generation(self) -> u64 {
        self.generation
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

    pub fn take_generation_replacement_for_start(&mut self) -> bool {
        if self.state != RuntimeLifecycleState::Starting || !self.generation_requires_replacement {
            return false;
        }
        if !self.advance_generation() {
            return false;
        }
        self.generation_requires_replacement = false;
        true
    }

    pub fn advance_stopped_generation(&mut self) -> bool {
        if self.state != RuntimeLifecycleState::Stopped || self.generation_requires_replacement {
            return false;
        }
        self.advance_generation()
    }

    pub fn start_submission_failed(&mut self) {
        if self.state == RuntimeLifecycleState::Starting {
            self.state = RuntimeLifecycleState::Stopped;
        }
    }

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
            return RuntimeStartCompletion {
                install_fresh_generation_now: false,
            };
        }

        self.state = RuntimeLifecycleState::Stopped;
        let install_fresh_generation_now = clean_after_failed_start && self.advance_generation();
        self.generation_requires_replacement = !install_fresh_generation_now;
        RuntimeStartCompletion {
            install_fresh_generation_now,
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

    /// Executor rejection means cleanup never ran. Keep STOPPING as a fail-closed terminal state.
    pub fn stop_submission_failed(&mut self) {
        if self.state == RuntimeLifecycleState::Stopping {
            self.restart_after_stop = false;
        }
    }

    pub fn complete_stop(&mut self, clean: bool) -> RuntimeCleanupDisposition {
        let restart_requested = self.restart_after_stop;
        self.restart_after_stop = false;
        self.state = RuntimeLifecycleState::Stopped;

        let replacement_advanced = clean && self.advance_generation();
        let disposition = if replacement_advanced {
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

    fn advance_generation(&mut self) -> bool {
        let Some(next) = self.generation.checked_add(1) else {
            return false;
        };
        self.generation = next;
        true
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProxyServingState {
    Stopped,
    Starting,
    Running,
    Failed,
}

/// One semantic failure vocabulary for current native Proxy Serving.
///
/// Operational Rust errors are translated into these owner facts before crossing UniFFI, so
/// Android and diagnostics never need to infer the failing layer from exception text.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
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

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProxyServingSnapshot {
    state: ProxyServingState,
    failure: Option<ProxyServingFailure>,
}

impl ProxyServingSnapshot {
    pub const fn state(self) -> ProxyServingState {
        self.state
    }

    pub const fn failure(self) -> Option<ProxyServingFailure> {
        self.failure
    }
}

/// Natural owner state machine for one in-process Proxy Serving generation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProxyServingLifecycle {
    snapshot: ProxyServingSnapshot,
}

impl Default for ProxyServingLifecycle {
    fn default() -> Self {
        Self::new()
    }
}

impl ProxyServingLifecycle {
    pub const fn new() -> Self {
        Self {
            snapshot: ProxyServingSnapshot {
                state: ProxyServingState::Stopped,
                failure: None,
            },
        }
    }

    pub const fn snapshot(self) -> ProxyServingSnapshot {
        self.snapshot
    }

    pub fn request_start(&mut self) -> bool {
        match self.snapshot.state {
            ProxyServingState::Starting | ProxyServingState::Running => false,
            ProxyServingState::Stopped | ProxyServingState::Failed => {
                self.snapshot = ProxyServingSnapshot {
                    state: ProxyServingState::Starting,
                    failure: None,
                };
                true
            }
        }
    }

    pub fn mark_running(&mut self) -> bool {
        if self.snapshot.state != ProxyServingState::Starting {
            return false;
        }
        self.snapshot = ProxyServingSnapshot {
            state: ProxyServingState::Running,
            failure: None,
        };
        true
    }

    pub fn mark_failed(&mut self, failure: ProxyServingFailure) {
        self.snapshot = ProxyServingSnapshot {
            state: ProxyServingState::Failed,
            failure: Some(failure),
        };
    }

    pub fn mark_stopped(&mut self) {
        self.snapshot = ProxyServingSnapshot {
            state: ProxyServingState::Stopped,
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
        assert_eq!(owner.generation(), 1);
        assert_eq!(owner.request_start(), RuntimeStartAction::StartNow);
        assert_eq!(owner.request_start(), RuntimeStartAction::AlreadyActive);
        assert_eq!(owner.request_stop(), RuntimeStopAction::StopNow);
        assert_eq!(owner.request_start(), RuntimeStartAction::QueuedAfterStop);

        let disposition = owner.complete_stop(true);
        assert!(disposition.install_fresh_generation_now());
        assert!(disposition.restart_now());
        assert_eq!(owner.state(), RuntimeLifecycleState::Stopped);
        assert_eq!(owner.generation(), 2);
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
        assert_eq!(owner.generation(), 1);
    }

    #[test]
    fn dirty_generation_is_replaced_only_by_later_explicit_start() {
        let mut owner = RuntimeLifecycle::new();
        assert!(owner.mark_stopped_generation_dirty());
        assert!(owner.generation_requires_replacement());
        assert_eq!(owner.request_start(), RuntimeStartAction::StartNow);
        assert!(owner.take_generation_replacement_for_start());
        assert!(!owner.generation_requires_replacement());
        assert_eq!(owner.generation(), 2);
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
        assert_eq!(clean.generation(), 2);

        let mut dirty = RuntimeLifecycle::new();
        dirty.request_start();
        let dirty_completion = dirty.complete_start(false, false);
        assert!(!dirty_completion.install_fresh_generation_now());
        assert!(dirty.generation_requires_replacement());
        assert_eq!(dirty.generation(), 1);
    }

    #[test]
    fn stopped_credential_cutover_advances_owner_generation() {
        let mut owner = RuntimeLifecycle::new();
        assert!(owner.can_mutate_stopped_generation());
        assert!(owner.advance_stopped_generation());
        assert_eq!(owner.generation(), 2);
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
    fn proxy_serving_lifecycle_preserves_typed_native_failure() {
        let mut owner = ProxyServingLifecycle::new();
        assert_eq!(owner.snapshot().state(), ProxyServingState::Stopped);
        assert!(owner.request_start());
        assert!(!owner.request_start());
        assert!(owner.mark_running());
        owner.mark_failed(ProxyServingFailure::MixedListenerUnavailable);
        assert_eq!(owner.snapshot().state(), ProxyServingState::Failed);
        assert_eq!(
            owner.snapshot().failure(),
            Some(ProxyServingFailure::MixedListenerUnavailable)
        );
        assert!(owner.request_start());
        owner.mark_stopped();
        assert_eq!(owner.snapshot().state(), ProxyServingState::Stopped);
        assert_eq!(owner.snapshot().failure(), None);
    }
}
