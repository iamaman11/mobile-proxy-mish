//! Pure IP-rotation owner.
//!
//! This crate owns only the state machine: operation identity, fact acceptance, phase transitions,
//! currentness and terminal outcome. Root commands, timers and network I/O are executed by
//! mish-runtime on its existing Tokio runtime.

use std::net::IpAddr;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationPhase {
    Idle,
    Preparing,
    AirplaneEnabling,
    WaitingRadioDown,
    AirplaneDisabling,
    WaitingCellularRecovery,
    WaitingRootPolicy,
    ProbingPublicIp,
    Changed,
    Unchanged,
    Failed,
}

impl RotationPhase {
    pub const fn terminal(self) -> bool {
        matches!(self, Self::Changed | Self::Unchanged | Self::Failed)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationTerminalResult {
    Changed,
    Unchanged,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationFailure {
    RuntimeNotRunning,
    NoCurrentCellular,
    RootPolicyUnavailable,
    BeforeIpFailed,
    AirplaneEnableFailed,
    AirplaneObservationFailed,
    AirplaneDisableFailed,
    FreshCellularUnavailable,
    RootPolicyRecoveryFailed,
    AfterIpFailed,
    DeadlineExceeded,
    StateUnavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationRestoreResult {
    NotRequired,
    AlreadyOff,
    RestoredOff,
    Failed,
    Uncertain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationStartError {
    AlreadyInProgress,
    InvalidGeneration,
    OperationIdExhausted,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationTransitionError {
    StaleOperation,
    InvalidPhase,
    StaleGeneration,
    StateUnavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RotationSnapshot {
    pub operation_id: Option<u64>,
    pub phase: RotationPhase,
    pub before_generation: Option<u64>,
    pub after_generation: Option<u64>,
    pub restore_required: bool,
    pub terminal_result: Option<RotationTerminalResult>,
    pub failure: Option<RotationFailure>,
    pub restore_result: Option<RotationRestoreResult>,
}

impl RotationSnapshot {
    pub const fn idle() -> Self {
        Self {
            operation_id: None,
            phase: RotationPhase::Idle,
            before_generation: None,
            after_generation: None,
            restore_required: false,
            terminal_result: None,
            failure: None,
            restore_result: None,
        }
    }
}

#[derive(Debug, Clone)]
struct RotationOperation {
    id: u64,
    phase: RotationPhase,
    before_generation: u64,
    after_generation: Option<u64>,
    before_ip: Option<IpAddr>,
    airplane_on_observed: bool,
    airplane_off_observed: bool,
    cellular_loss_observed: bool,
    fresh_cellular_generation: Option<u64>,
    root_authorized_generation: Option<u64>,
    restore_required: bool,
    terminal_result: Option<RotationTerminalResult>,
    failure: Option<RotationFailure>,
    restore_result: Option<RotationRestoreResult>,
}

impl RotationOperation {
    fn snapshot(&self) -> RotationSnapshot {
        RotationSnapshot {
            operation_id: Some(self.id),
            phase: self.phase,
            before_generation: Some(self.before_generation),
            after_generation: self.after_generation,
            restore_required: self.restore_required,
            terminal_result: self.terminal_result,
            failure: self.failure,
            restore_result: self.restore_result,
        }
    }

    fn maybe_advance_radio_down(&mut self) {
        if self.phase == RotationPhase::WaitingRadioDown
            && self.airplane_on_observed
            && self.cellular_loss_observed
        {
            self.phase = RotationPhase::AirplaneDisabling;
            self.restore_required = true;
        }
    }

    fn maybe_advance_recovery(&mut self) {
        if !matches!(
            self.phase,
            RotationPhase::WaitingCellularRecovery | RotationPhase::WaitingRootPolicy
        ) {
            return;
        }

        let Some(fresh) = self.fresh_cellular_generation else {
            self.phase = RotationPhase::WaitingCellularRecovery;
            return;
        };
        if self.root_authorized_generation != Some(fresh) {
            self.phase = RotationPhase::WaitingRootPolicy;
            return;
        }
        if self.airplane_off_observed {
            self.after_generation = Some(fresh);
            self.restore_required = false;
            self.phase = RotationPhase::ProbingPublicIp;
        } else {
            self.phase = RotationPhase::WaitingRootPolicy;
        }
    }
}

#[derive(Debug, Clone)]
pub struct RotationStateMachine {
    next_operation_id: u64,
    current: Option<RotationOperation>,
}

impl Default for RotationStateMachine {
    fn default() -> Self {
        Self::new()
    }
}

impl RotationStateMachine {
    pub const fn new() -> Self {
        Self {
            next_operation_id: 1,
            current: None,
        }
    }

    pub fn snapshot(&self) -> RotationSnapshot {
        self.current
            .as_ref()
            .map_or_else(RotationSnapshot::idle, RotationOperation::snapshot)
    }

    pub fn start(&mut self, before_generation: u64) -> Result<u64, RotationStartError> {
        if before_generation == 0 {
            return Err(RotationStartError::InvalidGeneration);
        }
        if self
            .current
            .as_ref()
            .is_some_and(|operation| !operation.phase.terminal())
        {
            return Err(RotationStartError::AlreadyInProgress);
        }

        let id = self.next_operation_id;
        self.next_operation_id = self
            .next_operation_id
            .checked_add(1)
            .ok_or(RotationStartError::OperationIdExhausted)?;
        self.current = Some(RotationOperation {
            id,
            phase: RotationPhase::Preparing,
            before_generation,
            after_generation: None,
            before_ip: None,
            airplane_on_observed: false,
            airplane_off_observed: false,
            cellular_loss_observed: false,
            fresh_cellular_generation: None,
            root_authorized_generation: None,
            restore_required: false,
            terminal_result: None,
            failure: None,
            restore_result: None,
        });
        Ok(id)
    }

    pub fn record_before_ip(
        &mut self,
        operation_id: u64,
        generation: u64,
        address: IpAddr,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if operation.phase != RotationPhase::Preparing {
            return Err(RotationTransitionError::InvalidPhase);
        }
        if generation != operation.before_generation {
            return Err(RotationTransitionError::StaleGeneration);
        }
        operation.before_ip = Some(address);
        operation.phase = RotationPhase::AirplaneEnabling;
        Ok(operation.snapshot())
    }

    pub fn airplane_enable_effect_completed(
        &mut self,
        operation_id: u64,
        succeeded: bool,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if operation.phase != RotationPhase::AirplaneEnabling {
            return Err(RotationTransitionError::InvalidPhase);
        }
        if !succeeded {
            return Ok(fail_operation(
                operation,
                RotationFailure::AirplaneEnableFailed,
            ));
        }
        operation.restore_required = true;
        operation.phase = RotationPhase::WaitingRadioDown;
        Ok(operation.snapshot())
    }

    pub fn observe_airplane(
        &mut self,
        operation_id: u64,
        enabled: bool,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        match operation.phase {
            RotationPhase::WaitingRadioDown => {
                if enabled {
                    operation.airplane_on_observed = true;
                    operation.restore_required = true;
                }
                operation.maybe_advance_radio_down();
            }
            RotationPhase::AirplaneDisabling
            | RotationPhase::WaitingCellularRecovery
            | RotationPhase::WaitingRootPolicy => {
                if !enabled {
                    operation.airplane_off_observed = true;
                }
                operation.maybe_advance_recovery();
            }
            _ => return Err(RotationTransitionError::InvalidPhase),
        }
        Ok(operation.snapshot())
    }

    pub fn observe_cellular(
        &mut self,
        operation_id: u64,
        generation: u64,
        admitted: bool,
        root_policy_authorized: bool,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if generation <= operation.before_generation {
            if matches!(
                operation.phase,
                RotationPhase::WaitingRadioDown
                    | RotationPhase::WaitingCellularRecovery
                    | RotationPhase::WaitingRootPolicy
            ) {
                return Ok(operation.snapshot());
            }
            return Err(RotationTransitionError::StaleGeneration);
        }

        match operation.phase {
            RotationPhase::WaitingRadioDown => {
                if !admitted {
                    operation.cellular_loss_observed = true;
                }
                operation.maybe_advance_radio_down();
            }
            RotationPhase::AirplaneDisabling
            | RotationPhase::WaitingCellularRecovery
            | RotationPhase::WaitingRootPolicy => {
                if admitted {
                    operation.fresh_cellular_generation = Some(generation);
                    if root_policy_authorized {
                        operation.root_authorized_generation = Some(generation);
                    }
                }
                operation.maybe_advance_recovery();
            }
            _ => return Err(RotationTransitionError::InvalidPhase),
        }
        Ok(operation.snapshot())
    }

    pub fn airplane_disable_effect_completed(
        &mut self,
        operation_id: u64,
        succeeded: bool,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if operation.phase != RotationPhase::AirplaneDisabling {
            return Err(RotationTransitionError::InvalidPhase);
        }
        if !succeeded {
            return Ok(fail_operation(
                operation,
                RotationFailure::AirplaneDisableFailed,
            ));
        }
        operation.phase = RotationPhase::WaitingCellularRecovery;
        Ok(operation.snapshot())
    }

    pub fn record_after_ip(
        &mut self,
        operation_id: u64,
        generation: u64,
        address: IpAddr,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if operation.phase != RotationPhase::ProbingPublicIp {
            return Err(RotationTransitionError::InvalidPhase);
        }
        if operation.after_generation != Some(generation) {
            return Err(RotationTransitionError::StaleGeneration);
        }
        let before = operation
            .before_ip
            .ok_or(RotationTransitionError::StateUnavailable)?;
        if before == address {
            operation.phase = RotationPhase::Unchanged;
            operation.terminal_result = Some(RotationTerminalResult::Unchanged);
        } else {
            operation.phase = RotationPhase::Changed;
            operation.terminal_result = Some(RotationTerminalResult::Changed);
        }
        operation.restore_required = false;
        Ok(operation.snapshot())
    }

    pub fn fail(
        &mut self,
        operation_id: u64,
        failure: RotationFailure,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        Ok(fail_operation(operation, failure))
    }

    pub fn record_restore(
        &mut self,
        operation_id: u64,
        restore: RotationRestoreResult,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.current(operation_id)?;
        if operation.phase != RotationPhase::Failed {
            return Err(RotationTransitionError::InvalidPhase);
        }
        operation.restore_result = Some(restore);
        if matches!(
            restore,
            RotationRestoreResult::NotRequired
                | RotationRestoreResult::AlreadyOff
                | RotationRestoreResult::RestoredOff
        ) {
            operation.restore_required = false;
        }
        Ok(operation.snapshot())
    }

    fn current(
        &mut self,
        operation_id: u64,
    ) -> Result<&mut RotationOperation, RotationTransitionError> {
        let operation = self
            .current
            .as_mut()
            .ok_or(RotationTransitionError::StaleOperation)?;
        if operation.id != operation_id {
            return Err(RotationTransitionError::StaleOperation);
        }
        Ok(operation)
    }

    fn active(
        &mut self,
        operation_id: u64,
    ) -> Result<&mut RotationOperation, RotationTransitionError> {
        let operation = self.current(operation_id)?;
        if operation.phase.terminal() {
            return Err(RotationTransitionError::InvalidPhase);
        }
        Ok(operation)
    }
}

fn fail_operation(
    operation: &mut RotationOperation,
    failure: RotationFailure,
) -> RotationSnapshot {
    operation.phase = RotationPhase::Failed;
    operation.terminal_result = Some(RotationTerminalResult::Failed);
    operation.failure = Some(failure);
    operation.snapshot()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(value: &str) -> IpAddr {
        value.parse().expect("IP literal")
    }

    fn started() -> (RotationStateMachine, u64) {
        let mut machine = RotationStateMachine::new();
        let id = machine.start(10).expect("start");
        machine
            .record_before_ip(id, 10, ip("198.51.100.10"))
            .expect("before");
        (machine, id)
    }

    #[test]
    fn one_operation_only_and_terminal_allows_next_operation() {
        let mut machine = RotationStateMachine::new();
        let first = machine.start(10).expect("first");
        assert_eq!(
            machine.start(10),
            Err(RotationStartError::AlreadyInProgress)
        );
        machine
            .fail(first, RotationFailure::BeforeIpFailed)
            .expect("fail");
        let second = machine.start(11).expect("second");
        assert!(second > first);
    }

    #[test]
    fn command_completion_alone_never_implies_airplane_fact_or_radio_loss() {
        let (mut machine, id) = started();
        let snapshot = machine
            .airplane_enable_effect_completed(id, true)
            .expect("enable");
        assert_eq!(snapshot.phase, RotationPhase::WaitingRadioDown);

        let snapshot = machine
            .observe_cellular(id, 11, false, false)
            .expect("loss");
        assert_eq!(snapshot.phase, RotationPhase::WaitingRadioDown);

        let snapshot = machine.observe_airplane(id, true).expect("airplane on");
        assert_eq!(snapshot.phase, RotationPhase::AirplaneDisabling);
    }

    #[test]
    fn airplane_on_without_cellular_loss_does_not_advance() {
        let (mut machine, id) = started();
        machine
            .airplane_enable_effect_completed(id, true)
            .expect("enable");
        let snapshot = machine.observe_airplane(id, true).expect("airplane on");
        assert_eq!(snapshot.phase, RotationPhase::WaitingRadioDown);
    }

    #[test]
    fn disable_is_reached_once_both_required_facts_exist_in_either_order() {
        let (mut machine, id) = started();
        machine
            .airplane_enable_effect_completed(id, true)
            .expect("enable");
        machine.observe_airplane(id, true).expect("on");
        let snapshot = machine
            .observe_cellular(id, 11, false, false)
            .expect("loss");
        assert_eq!(snapshot.phase, RotationPhase::AirplaneDisabling);
        assert_eq!(
            machine.observe_cellular(id, 12, false, false),
            Err(RotationTransitionError::InvalidPhase)
        );
    }

    #[test]
    fn generation_a_recovery_is_ignored_and_fresh_b_requires_exact_root_authorization() {
        let (mut machine, id) = started();
        machine
            .airplane_enable_effect_completed(id, true)
            .expect("enable");
        machine.observe_airplane(id, true).expect("on");
        machine
            .observe_cellular(id, 11, false, false)
            .expect("loss");
        machine
            .airplane_disable_effect_completed(id, true)
            .expect("disable");
        machine.observe_airplane(id, false).expect("off");

        let old = machine
            .observe_cellular(id, 10, true, true)
            .expect("old generation ignored");
        assert_eq!(old.phase, RotationPhase::WaitingCellularRecovery);

        let fresh = machine
            .observe_cellular(id, 12, true, false)
            .expect("fresh cellular");
        assert_eq!(fresh.phase, RotationPhase::WaitingRootPolicy);
        assert_eq!(fresh.after_generation, None);

        let authorized = machine
            .observe_cellular(id, 12, true, true)
            .expect("root authorization");
        assert_eq!(authorized.phase, RotationPhase::ProbingPublicIp);
        assert_eq!(authorized.after_generation, Some(12));
    }

    #[test]
    fn after_ip_is_generation_bound_and_distinguishes_changed_unchanged() {
        for (after, expected_phase, expected_terminal) in [
            (
                "198.51.100.10",
                RotationPhase::Unchanged,
                RotationTerminalResult::Unchanged,
            ),
            (
                "203.0.113.20",
                RotationPhase::Changed,
                RotationTerminalResult::Changed,
            ),
        ] {
            let (mut machine, id) = started();
            machine
                .airplane_enable_effect_completed(id, true)
                .expect("enable");
            machine.observe_airplane(id, true).expect("on");
            machine
                .observe_cellular(id, 11, false, false)
                .expect("loss");
            machine
                .airplane_disable_effect_completed(id, true)
                .expect("disable");
            machine.observe_airplane(id, false).expect("off");
            machine
                .observe_cellular(id, 12, true, true)
                .expect("recovery");

            assert_eq!(
                machine.record_after_ip(id, 11, ip(after)),
                Err(RotationTransitionError::StaleGeneration)
            );
            let terminal = machine
                .record_after_ip(id, 12, ip(after))
                .expect("after");
            assert_eq!(terminal.phase, expected_phase);
            assert_eq!(terminal.terminal_result, Some(expected_terminal));
            assert!(!terminal.restore_required);
        }
    }

    #[test]
    fn terminal_state_cannot_mutate_except_restore_bookkeeping_on_failure() {
        let (mut machine, id) = started();
        let failed = machine
            .fail(id, RotationFailure::DeadlineExceeded)
            .expect("fail");
        assert_eq!(failed.phase, RotationPhase::Failed);
        assert_eq!(
            machine.observe_airplane(id, false),
            Err(RotationTransitionError::InvalidPhase)
        );
        let restored = machine
            .record_restore(id, RotationRestoreResult::AlreadyOff)
            .expect("restore");
        assert_eq!(restored.terminal_result, Some(RotationTerminalResult::Failed));
        assert_eq!(
            restored.restore_result,
            Some(RotationRestoreResult::AlreadyOff)
        );
    }

    #[test]
    fn stale_operation_id_is_rejected() {
        let (mut machine, id) = started();
        assert_eq!(
            machine.observe_airplane(id + 1, true),
            Err(RotationTransitionError::StaleOperation)
        );
    }
}
