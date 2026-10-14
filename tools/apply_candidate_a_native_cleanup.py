#!/usr/bin/env python3
"""One-shot deterministic cleanup for #450 on rotation/candidate-a-product.

This script is intentionally deleted by the workflow that consumes it. Every rewrite is guarded by
exact-count assertions so source drift fails closed rather than producing a partial migration.
"""

from __future__ import annotations

import importlib.util
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def replace_regex_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.DOTALL)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one regex match, found {count}")
    return updated


def update_rotation_semantics() -> None:
    path = "crates/rotation/src/lib.rs"
    text = read(path)
    old = '''        operation.before_ip = Some(address);\n        // From this point a disable mutation may already be in flight when a concurrent absolute\n        // deadline fires. Mark restore intent before scheduling the mutation so timeout/shutdown\n        // can only recover by authoritative observe -> at-most-one enable, never by blind replay.\n        operation.restore_required = true;\n        operation.phase = RotationPhase::DataDisabling;\n        Ok(operation.snapshot())\n    }\n\n    pub fn data_disable_effect_completed(\n'''
    new = '''        operation.before_ip = Some(address);\n        // Recording the before-IP fact does not itself grant compensation authority. The runtime\n        // must first prove the expected precondition (mobile data ENABLED), then mark the exact\n        // point immediately before it submits the disable mutation.\n        operation.phase = RotationPhase::DataDisabling;\n        Ok(operation.snapshot())\n    }\n\n    pub fn data_disable_mutation_started(\n        &mut self,\n        operation_id: u64,\n    ) -> Result<RotationSnapshot, RotationTransitionError> {\n        let operation = self.active(operation_id)?;\n        if operation.phase != RotationPhase::DataDisabling {\n            return Err(RotationTransitionError::InvalidPhase);\n        }\n        operation.restore_required = true;\n        Ok(operation.snapshot())\n    }\n\n    pub fn data_disable_effect_completed(\n'''
    text = replace_once(text, old, new, "rotation restore-intent transition")

    text = replace_once(
        text,
        '''            RotationMutationOutcome::Applied => {\n                operation.phase = RotationPhase::WaitingCellularLoss;\n''',
        '''            RotationMutationOutcome::Applied => {\n                operation.restore_required = true;\n                operation.phase = RotationPhase::WaitingCellularLoss;\n''',
        "applied disable keeps compensation authority",
    )
    text = replace_once(
        text,
        '''            RotationMutationOutcome::Uncertain => {\n                return Ok(fail_operation(operation, RotationFailure::DataDisableFailed));\n''',
        '''            RotationMutationOutcome::Uncertain => {\n                operation.restore_required = true;\n                return Ok(fail_operation(operation, RotationFailure::DataDisableFailed));\n''',
        "uncertain disable keeps compensation authority",
    )

    text = replace_regex_once(
        text,
        r'''    #\[test\]\n    fn entering_disable_phase_marks_restore_before_mutation_can_race_deadline\(\) \{.*?\n    \}\n\n''',
        '''    #[test]\n    fn precondition_phase_does_not_claim_restore_before_disable_mutation() {\n        let (machine, _id) = started();\n        assert_eq!(machine.snapshot().phase, RotationPhase::DataDisabling);\n        assert!(!machine.snapshot().restore_required);\n    }\n\n    #[test]\n    fn disable_mutation_start_claims_restore_before_deadline_can_race() {\n        let (mut machine, id) = started();\n        let started = machine\n            .data_disable_mutation_started(id)\n            .expect("disable mutation start");\n        assert!(started.restore_required);\n        let failed = machine.deadline_exceeded(id).expect("deadline");\n        assert_eq!(failed.phase, RotationPhase::Failed);\n        assert!(failed.restore_required);\n    }\n\n''',
        "rotation restore-intent tests",
    )

    text = replace_regex_once(
        text,
        r'''    #\[test\]\n    fn absolute_deadline_keeps_restore_requirement_only_while_data_may_be_disabled\(\) \{.*?\n    \}\n\n''',
        '''    #[test]\n    fn absolute_deadline_keeps_restore_requirement_only_while_data_may_be_disabled() {\n        let (mut machine, id) = started();\n        let failed_before_mutation = machine.deadline_exceeded(id).expect("deadline");\n        assert!(!failed_before_mutation.restore_required);\n\n        let (mut machine, id) = started();\n        machine\n            .data_disable_mutation_started(id)\n            .expect("disable mutation start");\n        let failed_during_disable = machine.deadline_exceeded(id).expect("deadline");\n        assert!(failed_during_disable.restore_required);\n\n        let (mut machine, id) = started();\n        machine\n            .data_disable_mutation_started(id)\n            .expect("disable mutation start");\n        detached(&mut machine, id);\n        machine\n            .data_enable_effect_completed(id, RotationMutationOutcome::Applied)\n            .expect("verified enable");\n        let failed_after_verified_enable = machine.deadline_exceeded(id).expect("deadline");\n        assert!(!failed_after_verified_enable.restore_required);\n    }\n\n''',
        "absolute deadline restore test",
    )
    write(path, text)


def update_rotation_runtime() -> None:
    path = "crates/runtime/src/rotation_runtime.rs"
    text = read(path)
    old = '''        if observed != MobileDataState::Enabled {\n            self.fail(operation_id, RotationFailure::MobileDataObservationFailed);\n            return;\n        }\n\n        self.mark_timing(operation_id, |timing, elapsed_ms| {\n            set_once(&mut timing.data_disable_started_ms, elapsed_ms);\n        });\n'''
    new = '''        if observed != MobileDataState::Enabled {\n            self.fail(operation_id, RotationFailure::MobileDataObservationFailed);\n            return;\n        }\n\n        // The precondition is now authoritative. Mark compensation authority immediately before\n        // submitting the one disable mutation so a concurrent absolute deadline cannot either\n        // mutate a pre-existing disabled state or leave our own uncertain disable uncompensated.\n        let mutation_started = {\n            let Ok(mut state) = self.state.lock() else {\n                return;\n            };\n            if !operation_current(&state, operation_id) {\n                return;\n            }\n            match state.machine.data_disable_mutation_started(operation_id) {\n                Ok(snapshot) => snapshot,\n                Err(_) => return,\n            }\n        };\n        self.after_transition(mutation_started);\n        if self.snapshot().phase.terminal() {\n            return;\n        }\n\n        self.mark_timing(operation_id, |timing, elapsed_ms| {\n            set_once(&mut timing.data_disable_started_ms, elapsed_ms);\n        });\n'''
    text = replace_once(text, old, new, "runtime disable mutation authority")
    write(path, text)


def remove_dead_airplane_effect() -> None:
    entry = "crates/runtime/src/entry.rs"
    text = read(entry)
    text = replace_once(text, "mod airplane_effect;\n", "", "remove airplane module declaration")
    write(entry, text)

    policy = "crates/runtime/src/cellular_policy_coordinator.rs"
    text = read(policy)
    text = replace_once(
        text,
        '''    pub(crate) fn airplane_effect(&self) -> Arc<crate::airplane_effect::AirplaneModeEffect> {\n        crate::airplane_effect::AirplaneModeEffect::new(Arc::clone(&self.root_session))\n    }\n\n''',
        "",
        "remove airplane effect accessor",
    )
    write(policy, text)

    airplane = ROOT / "crates/runtime/src/airplane_effect.rs"
    if not airplane.is_file():
        raise SystemExit("airplane_effect.rs already missing; refusing ambiguous cleanup")
    airplane.unlink()


def normalize_architecture_guard() -> None:
    dispatcher_path = ROOT / "tools/check_architecture.py"
    legacy_path = ROOT / "tools/check_architecture_legacy.py"
    if not legacy_path.is_file():
        raise SystemExit("legacy architecture checker missing")

    spec = importlib.util.spec_from_file_location("candidate_a_guard", dispatcher_path)
    if spec is None or spec.loader is None:
        raise SystemExit("cannot load Candidate A guard dispatcher")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    legacy = legacy_path.read_text(encoding="utf-8")
    start_marker = module.START
    end_marker = module.END
    if legacy.count(start_marker) != 1 or legacy.count(end_marker) != 1:
        raise SystemExit("architecture Rotation sentinel drift")
    start = legacy.index(start_marker)
    end = legacy.index(end_marker, start)
    candidate = module.CANDIDATE_A

    candidate = replace_once(
        candidate,
        '        "pub fn data_disable_effect_completed(",\n',
        '        "pub fn data_disable_mutation_started(",\n        "pub fn data_disable_effect_completed(",\n',
        "guard requires mutation-start transition",
    )
    candidate = replace_once(
        candidate,
        '        "entering_disable_phase_marks_restore_before_mutation_can_race_deadline",\n',
        '        "precondition_phase_does_not_claim_restore_before_disable_mutation",\n        "disable_mutation_start_claims_restore_before_deadline_can_race",\n',
        "guard restore tests",
    )
    candidate = replace_once(
        candidate,
        '''    forbid_product(\n        mobile_data_effect,\n        "sleep(",\n        "mobile-data effect must not own recovery timing",\n    )\n''',
        '''    forbid_product(\n        mobile_data_effect,\n        "sleep(",\n        "mobile-data effect must not own recovery timing",\n    )\n    forbid_exists(\n        "crates/runtime/src/airplane_effect.rs",\n        "Candidate A must delete the obsolete Rust airplane mutation effect rather than retain a dormant fallback",\n    )\n    forbid_product(\n        "crates/runtime/src/entry.rs",\n        "mod airplane_effect;",\n        "Candidate A runtime composition must not retain the obsolete airplane effect module",\n    )\n''',
        "guard forbids dead airplane effect",
    )

    effective = legacy[:start] + candidate + legacy[end:]
    dispatcher_path.write_text(effective, encoding="utf-8")
    legacy_path.unlink()


def main() -> None:
    update_rotation_semantics()
    update_rotation_runtime()
    remove_dead_airplane_effect()
    normalize_architecture_guard()

    # One-shot dev machinery deletes itself before the validated commit is created.
    for relative in (
        "tools/apply_candidate_a_native_cleanup.py",
        ".github/workflows/candidate-a-native-cleanup.yml",
    ):
        target = ROOT / relative
        if target.exists():
            target.unlink()


if __name__ == "__main__":
    main()
