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
    DataDisabling,
    WaitingCellularLoss,
    DataEnabling,
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

    // Transitional source-compatibility aliases for the Android projection. They are not active
    // state-machine vocabulary and can be removed when the generated boundary is regenerated.
    #[allow(non_upper_case_globals)]
    pub const AirplaneEnabling: Self = Self::DataDisabling;
    #[allow(non_upper_case_globals)]
    pub const WaitingRadioDown: Self = Self::WaitingCellularLoss;
    #[allow(non_upper_case_globals)]
    pub const AirplaneDisabling: Self = Self::DataEnabling;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationTerminalResult {
    Changed,
    Unchanged,
    Failed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationMutationOutcome {
    Applied,
    Rejected,
    Uncertain,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationFailure {
    RuntimeNotRunning,
    NoCurrentCellular,
    RootPolicyUnavailable,
    BeforeIpFailed,
    DataDisableFailed,
    MobileDataObservationFailed,
    DataEnableFailed,
    FreshCellularUnavailable,
    RootPolicyRecoveryFailed,
    AfterIpFailed,
    CredentialChanged,
    DeadlineExceeded,
    StateUnavailable,
}

impl RotationFailure {
    // Transitional source-compatibility aliases for the Android projection only.
    #[allow(non_upper_case_globals)]
    pub const AirplaneEnableFailed: Self = Self::DataDisableFailed;
    #[allow(non_upper_case_globals)]
    pub const AirplaneObservationFailed: Self = Self::MobileDataObservationFailed;
    #[allow(non_upper_case_globals)]
    pub const AirplaneDisableFailed: Self = Self::DataEnableFailed;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RotationRestoreResult {
    NotRequired,
    AlreadyEnabled,
    RestoredEnabled,
    Failed,
    Uncertain,
}

impl RotationRestoreResult {
    // Transitional source-compatibility aliases for the Android projection only.
    #[allow(non_upper_case_globals)]
    pub const AlreadyOff: Self = Self::AlreadyEnabled;
    #[allow(non_upper_case_globals)]
    pub const RestoredOff: Self = Self::RestoredEnabled;
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
    pub before_ip: Option<IpAddr>,
    pub after_ip: Option<IpAddr>,
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
            before_ip: None,
            after_ip: None,
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
    after_ip: Option<IpAddr>,
    cellular_loss_observed: bool,
    latest_owner_generation: u64,
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
            before_ip: self.before_ip,
            after_ip: self.after_ip,
            restore_required: self.restore_required,
            terminal_result: self.terminal_result,
            failure: self.failure,
            restore_result: self.restore_result,
        }
    }

    fn observe_owner_generation(&mut self, generation: u64) -> bool {
        if generation < self.latest_owner_generation {
            return false;
        }
        if generation > self.latest_owner_generation {
            self.latest_owner_generation = generation;
            if self
                .fresh_cellular_generation
                .is_some_and(|current| current < generation)
            {
                self.fresh_cellular_generation = None;
            }
            if self
                .root_authorized_generation
                .is_some_and(|current| current < generation)
            {
                self.root_authorized_generation = None;
            }
        }
        true
    }

    fn observe_recovery_cellular(&mut self, generation: u64, admitted: bool) {
        if admitted {
            self.fresh_cellular_generation = Some(generation);
        } else {
            if self.fresh_cellular_generation == Some(generation) {
                self.fresh_cellular_generation = None;
            }
            if self.root_authorized_generation == Some(generation) {
                self.root_authorized_generation = None;
            }
        }
    }

    fn maybe_advance_loss(&mut self) {
        if self.phase == RotationPhase::WaitingCellularLoss && self.cellular_loss_observed {
            self.phase = RotationPhase::DataEnabling;
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
        self.after_generation = Some(fresh);
        self.phase = RotationPhase::ProbingPublicIp;
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
            after_ip: None,
            cellular_loss_observed: false,
            latest_owner_generation: before_generation,
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
        // Recording the before-IP fact does not itself grant compensation authority. The runtime
        // must first prove the expected precondition (mobile data ENABLED), then mark the exact
        // point immediately before it submits the disable mutation.
        operation.phase = RotationPhase::DataDisabling;
        Ok(operation.snapshot())
    }

    pub fn data_disable_mutation_started(
        &mut self,
        operation_id: u64,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if operation.phase != RotationPhase::DataDisabling {
            return Err(RotationTransitionError::InvalidPhase);
        }
        operation.restore_required = true;
        Ok(operation.snapshot())
    }

    pub fn data_disable_effect_completed(
        &mut self,
        operation_id: u64,
        outcome: RotationMutationOutcome,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if operation.phase != RotationPhase::DataDisabling {
            return Err(RotationTransitionError::InvalidPhase);
        }
        match outcome {
            RotationMutationOutcome::Applied => {
                operation.restore_required = true;
                operation.phase = RotationPhase::WaitingCellularLoss;
                operation.maybe_advance_loss();
            }
            RotationMutationOutcome::Rejected => {
                operation.restore_required = false;
                return Ok(fail_operation(
                    operation,
                    RotationFailure::DataDisableFailed,
                ));
            }
            RotationMutationOutcome::Uncertain => {
                operation.restore_required = true;
                return Ok(fail_operation(
                    operation,
                    RotationFailure::DataDisableFailed,
                ));
            }
        }
        Ok(operation.snapshot())
    }

    pub fn data_enable_effect_completed(
        &mut self,
        operation_id: u64,
        outcome: RotationMutationOutcome,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if operation.phase != RotationPhase::DataEnabling {
            return Err(RotationTransitionError::InvalidPhase);
        }
        match outcome {
            RotationMutationOutcome::Applied => {
                operation.restore_required = false;
                operation.phase = RotationPhase::WaitingCellularRecovery;
                operation.maybe_advance_recovery();
            }
            RotationMutationOutcome::Rejected | RotationMutationOutcome::Uncertain => {
                operation.restore_required = true;
                return Ok(fail_operation(operation, RotationFailure::DataEnableFailed));
            }
        }
        Ok(operation.snapshot())
    }

    pub fn observe_cellular(
        &mut self,
        operation_id: u64,
        generation: u64,
        admitted: bool,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if generation <= operation.before_generation {
            if matches!(
                operation.phase,
                RotationPhase::DataDisabling
                    | RotationPhase::WaitingCellularLoss
                    | RotationPhase::DataEnabling
                    | RotationPhase::WaitingCellularRecovery
                    | RotationPhase::WaitingRootPolicy
            ) {
                return Ok(operation.snapshot());
            }
            return Err(RotationTransitionError::StaleGeneration);
        }
        if !operation.observe_owner_generation(generation) {
            return Ok(operation.snapshot());
        }

        match operation.phase {
            RotationPhase::DataDisabling | RotationPhase::WaitingCellularLoss => {
                if !admitted {
                    operation.cellular_loss_observed = true;
                }
                operation.maybe_advance_loss();
            }
            RotationPhase::DataEnabling => {
                operation.observe_recovery_cellular(generation, admitted);
            }
            RotationPhase::WaitingCellularRecovery | RotationPhase::WaitingRootPolicy => {
                operation.observe_recovery_cellular(generation, admitted);
                operation.maybe_advance_recovery();
            }
            _ => return Err(RotationTransitionError::InvalidPhase),
        }
        Ok(operation.snapshot())
    }

    pub fn observe_root_policy(
        &mut self,
        operation_id: u64,
        generation: u64,
        authorized: bool,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        let operation = self.active(operation_id)?;
        if generation <= operation.before_generation {
            if matches!(
                operation.phase,
                RotationPhase::DataEnabling
                    | RotationPhase::WaitingCellularRecovery
                    | RotationPhase::WaitingRootPolicy
            ) {
                return Ok(operation.snapshot());
            }
            return Err(RotationTransitionError::StaleGeneration);
        }
        if !operation.observe_owner_generation(generation) {
            return Ok(operation.snapshot());
        }

        match operation.phase {
            RotationPhase::DataEnabling
            | RotationPhase::WaitingCellularRecovery
            | RotationPhase::WaitingRootPolicy => {
                if authorized {
                    operation.root_authorized_generation = Some(generation);
                } else {
                    operation.root_authorized_generation = None;
                }
                if operation.phase != RotationPhase::DataEnabling {
                    operation.maybe_advance_recovery();
                }
            }
            _ => return Err(RotationTransitionError::InvalidPhase),
        }
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
        operation.after_ip = Some(address);
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

    pub fn deadline_exceeded(
        &mut self,
        operation_id: u64,
    ) -> Result<RotationSnapshot, RotationTransitionError> {
        self.fail(operation_id, RotationFailure::DeadlineExceeded)
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
                | RotationRestoreResult::AlreadyEnabled
                | RotationRestoreResult::RestoredEnabled
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

fn fail_operation(operation: &mut RotationOperation, failure: RotationFailure) -> RotationSnapshot {
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

    fn detached(machine: &mut RotationStateMachine, id: u64) {
        machine
            .data_disable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("disable");
        let snapshot = machine.observe_cellular(id, 11, false).expect("loss");
        assert_eq!(snapshot.phase, RotationPhase::DataEnabling);
    }

    fn recovered(machine: &mut RotationStateMachine, id: u64, generation: u64) {
        machine
            .data_enable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("enable");
        machine
            .observe_cellular(id, generation, true)
            .expect("fresh cellular");
        machine
            .observe_root_policy(id, generation, true)
            .expect("root authorization");
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
    fn precondition_phase_does_not_claim_restore_before_disable_mutation() {
        let (machine, _id) = started();
        assert_eq!(machine.snapshot().phase, RotationPhase::DataDisabling);
        assert!(!machine.snapshot().restore_required);
    }

    #[test]
    fn disable_mutation_start_claims_restore_before_deadline_can_race() {
        let (mut machine, id) = started();
        let started = machine
            .data_disable_mutation_started(id)
            .expect("disable mutation start");
        assert!(started.restore_required);
        let failed = machine.deadline_exceeded(id).expect("deadline");
        assert_eq!(failed.phase, RotationPhase::Failed);
        assert!(failed.restore_required);
    }

    #[test]
    fn disable_completion_alone_never_implies_cellular_loss() {
        let (mut machine, id) = started();
        let snapshot = machine
            .data_disable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("disable");
        assert_eq!(snapshot.phase, RotationPhase::WaitingCellularLoss);
        assert!(snapshot.restore_required);
    }

    #[test]
    fn enable_is_reached_only_after_fresh_authoritative_loss() {
        let (mut machine, id) = started();
        machine
            .data_disable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("disable");
        let stale = machine
            .observe_cellular(id, 10, false)
            .expect("old ignored");
        assert_eq!(stale.phase, RotationPhase::WaitingCellularLoss);
        let fresh = machine.observe_cellular(id, 11, false).expect("fresh loss");
        assert_eq!(fresh.phase, RotationPhase::DataEnabling);
    }

    #[test]
    fn loss_can_arrive_during_disable_effect_without_being_lost() {
        let (mut machine, id) = started();
        let early = machine.observe_cellular(id, 11, false).expect("early loss");
        assert_eq!(early.phase, RotationPhase::DataDisabling);
        let ready = machine
            .data_disable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("disable complete");
        assert_eq!(ready.phase, RotationPhase::DataEnabling);
    }

    #[test]
    fn uncertain_disable_fails_main_path_and_requires_restore() {
        let (mut machine, id) = started();
        let failed = machine
            .data_disable_effect_completed(id, RotationMutationOutcome::Uncertain)
            .expect("uncertain disable");
        assert_eq!(failed.phase, RotationPhase::Failed);
        assert_eq!(failed.failure, Some(RotationFailure::DataDisableFailed));
        assert!(failed.restore_required);
    }

    #[test]
    fn rejected_disable_fails_without_claiming_restore() {
        let (mut machine, id) = started();
        let failed = machine
            .data_disable_effect_completed(id, RotationMutationOutcome::Rejected)
            .expect("rejected disable");
        assert_eq!(failed.phase, RotationPhase::Failed);
        assert!(!failed.restore_required);
    }

    #[test]
    fn uncertain_enable_fails_main_path_and_preserves_restore_requirement() {
        let (mut machine, id) = started();
        detached(&mut machine, id);
        let failed = machine
            .data_enable_effect_completed(id, RotationMutationOutcome::Uncertain)
            .expect("uncertain enable");
        assert_eq!(failed.phase, RotationPhase::Failed);
        assert_eq!(failed.failure, Some(RotationFailure::DataEnableFailed));
        assert!(failed.restore_required);
    }

    #[test]
    fn fresh_generation_requires_exact_root_authorization() {
        let (mut machine, id) = started();
        detached(&mut machine, id);
        machine
            .data_enable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("enable");
        let fresh = machine
            .observe_cellular(id, 12, true)
            .expect("fresh cellular");
        assert_eq!(fresh.phase, RotationPhase::WaitingRootPolicy);
        assert_eq!(fresh.after_generation, None);
        let stale_root = machine
            .observe_root_policy(id, 11, true)
            .expect("stale root ignored");
        assert_eq!(stale_root.phase, RotationPhase::WaitingRootPolicy);
        let authorized = machine.observe_root_policy(id, 12, true).expect("root B");
        assert_eq!(authorized.phase, RotationPhase::ProbingPublicIp);
        assert_eq!(authorized.after_generation, Some(12));
    }

    #[test]
    fn root_fact_may_arrive_before_same_generation_cellular() {
        let (mut machine, id) = started();
        detached(&mut machine, id);
        machine
            .data_enable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("enable");
        let root_first = machine
            .observe_root_policy(id, 12, true)
            .expect("root first");
        assert_eq!(root_first.phase, RotationPhase::WaitingCellularRecovery);
        let recovered = machine.observe_cellular(id, 12, true).expect("cellular B");
        assert_eq!(recovered.phase, RotationPhase::ProbingPublicIp);
    }

    #[test]
    fn newer_owner_loss_invalidates_older_recovery_and_root_facts() {
        let (mut machine, id) = started();
        detached(&mut machine, id);
        machine
            .data_enable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("enable");
        machine.observe_root_policy(id, 12, true).expect("root B");
        let newer = machine.observe_cellular(id, 13, false).expect("loss C");
        assert_eq!(newer.phase, RotationPhase::WaitingCellularRecovery);
        let stale = machine.observe_cellular(id, 12, true).expect("stale B");
        assert_eq!(stale.phase, RotationPhase::WaitingCellularRecovery);
    }

    #[test]
    fn after_ip_is_generation_bound_and_changed_or_unchanged_both_succeed() {
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
            detached(&mut machine, id);
            recovered(&mut machine, id, 12);
            assert_eq!(
                machine.record_after_ip(id, 11, ip(after)),
                Err(RotationTransitionError::StaleGeneration)
            );
            let terminal = machine.record_after_ip(id, 12, ip(after)).expect("after");
            assert_eq!(terminal.phase, expected_phase);
            assert_eq!(terminal.terminal_result, Some(expected_terminal));
            assert!(!terminal.restore_required);
        }
    }

    #[test]
    fn raw_ip_facts_are_bounded_to_current_in_memory_operation() {
        let mut machine = RotationStateMachine::new();
        let id = machine.start(10).expect("start");
        machine
            .record_before_ip(id, 10, ip("198.51.100.10"))
            .expect("before");
        detached(&mut machine, id);
        recovered(&mut machine, id, 12);
        machine
            .record_after_ip(id, 12, ip("203.0.113.20"))
            .expect("after");
        let next = machine.start(13).expect("next");
        assert!(next > id);
        assert_eq!(machine.snapshot().before_ip, None);
        assert_eq!(machine.snapshot().after_ip, None);
    }

    #[test]
    fn absolute_deadline_keeps_restore_requirement_only_while_data_may_be_disabled() {
        let (mut machine, id) = started();
        let failed_before_mutation = machine.deadline_exceeded(id).expect("deadline");
        assert!(!failed_before_mutation.restore_required);

        let (mut machine, id) = started();
        machine
            .data_disable_mutation_started(id)
            .expect("disable mutation start");
        let failed_during_disable = machine.deadline_exceeded(id).expect("deadline");
        assert!(failed_during_disable.restore_required);

        let (mut machine, id) = started();
        machine
            .data_disable_mutation_started(id)
            .expect("disable mutation start");
        detached(&mut machine, id);
        machine
            .data_enable_effect_completed(id, RotationMutationOutcome::Applied)
            .expect("verified enable");
        let failed_after_verified_enable = machine.deadline_exceeded(id).expect("deadline");
        assert!(!failed_after_verified_enable.restore_required);
    }

    #[test]
    fn terminal_state_only_accepts_restore_bookkeeping_on_failure() {
        let (mut machine, id) = started();
        let failed = machine
            .fail(id, RotationFailure::StateUnavailable)
            .expect("fail");
        assert_eq!(failed.phase, RotationPhase::Failed);
        let restored = machine
            .record_restore(id, RotationRestoreResult::AlreadyEnabled)
            .expect("restore");
        assert_eq!(
            restored.restore_result,
            Some(RotationRestoreResult::AlreadyEnabled)
        );
        assert!(!restored.restore_required);
    }

    #[test]
    fn stale_operation_id_is_rejected() {
        let (mut machine, id) = started();
        assert_eq!(
            machine.data_disable_effect_completed(id + 1, RotationMutationOutcome::Applied),
            Err(RotationTransitionError::StaleOperation)
        );
    }
}
