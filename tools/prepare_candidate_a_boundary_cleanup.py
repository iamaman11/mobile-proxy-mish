#!/usr/bin/env python3
"""One-shot deterministic preparation for the #450 boundary cleanup.

This is development-only machinery. The cleanup workflow removes it before creating the validated
PRODUCT commit. Every rewrite is exact-count guarded so drift fails closed.
"""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    target = ROOT / path
    if not target.is_file():
        raise SystemExit(f"missing required file: {path}")
    return target.read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8")


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


def prepare_product_runtime() -> None:
    path = "crates/runtime/src/product_runtime.rs"
    text = read(path)

    replay_pattern = re.compile(
        r'''            let _ = generation\.control\(\)\.start\(\n'''
        r'''\s+control\.public_key_spki,\n'''
        r'''\s+control\.signer,\n'''
        r'''\s+control\.cellular_request_rearm,\n'''
        r'''\s+\);'''
    )
    replacement = '''            let _ = generation.control().start(
                    control.public_key_spki,
                    control.signer,
                );'''
    text, replay_count = replay_pattern.subn(replacement, text, count=1)
    if replay_count != 1:
        raise SystemExit(f"stored CONTROL replay shape drift: {replay_count}")

    fixture_pattern = re.compile(
        r'''\n    struct TestControlRearmEffect;\n\n'''
        r'''    impl CellularRequestRearmEffect for TestControlRearmEffect \{\n'''
        r'''        fn rearm_cellular_request\(&self\) -> bool \{\n'''
        r'''            true\n'''
        r'''        \}\n'''
        r'''    \}\n'''
    )
    text, fixture_count = fixture_pattern.subn("\n", text, count=1)
    if fixture_count != 1:
        raise SystemExit(f"rearm test fixture drift: {fixture_count}")

    arg = "                Arc::new(TestControlRearmEffect),\n"
    arg_count = text.count(arg)
    if arg_count != 3:
        raise SystemExit(f"rearm test call count drift: {arg_count}")
    text = text.replace(arg, "")

    write(path, text)


def prepare_diagnostics_projection() -> None:
    path = "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt"
    text = read(path)
    old = '''                putNullableLong(
                    "airplane_enable_started_ms",
                    snapshot.rotationTiming.airplaneEnableStartedMs,
                )
                putNullableLong(
                    "airplane_enable_effect_completed_ms",
                    snapshot.rotationTiming.airplaneEnableEffectCompletedMs,
                )
                putNullableLong(
                    "airplane_on_observed_ms",
                    snapshot.rotationTiming.airplaneOnObservedMs,
                )
                putNullableLong(
                    "cellular_loss_observed_ms",
                    snapshot.rotationTiming.cellularLossObservedMs,
                )
                putNullableLong(
                    "radio_power_off_observed_ms",
                    snapshot.rotationTiming.radioPowerOffObservedMs,
                )
                putNullableLong(
                    "airplane_disable_started_ms",
                    snapshot.rotationTiming.airplaneDisableStartedMs,
                )
                putNullableLong(
                    "airplane_disable_effect_completed_ms",
                    snapshot.rotationTiming.airplaneDisableEffectCompletedMs,
                )
                putNullableLong(
                    "airplane_off_observed_ms",
                    snapshot.rotationTiming.airplaneOffObservedMs,
                )
                putNullableLong(
                    "cellular_request_rearm_started_ms",
                    snapshot.rotationTiming.cellularRequestRearmStartedMs,
                )
                putNullableLong(
                    "cellular_request_rearm_completed_ms",
                    snapshot.rotationTiming.cellularRequestRearmCompletedMs,
                )
                putNullableLong(
                    "first_platform_cellular_observation_ms",
                    snapshot.rotationTiming.firstPlatformCellularObservationMs,
                )
                put(
                    "platform_cellular_observations_after_rearm",
                    snapshot.rotationTiming.platformCellularObservationsAfterRearm.toLong(),
                )
'''
    new = '''                putNullableLong(
                    "mobile_data_precondition_observed_ms",
                    snapshot.rotationTiming.mobileDataPreconditionObservedMs,
                )
                put(
                    "mobile_data_precondition_enabled",
                    snapshot.rotationTiming.mobileDataPreconditionEnabled ?: JSONObject.NULL,
                )
                putNullableLong(
                    "data_disable_started_ms",
                    snapshot.rotationTiming.dataDisableStartedMs,
                )
                putNullableLong(
                    "data_disable_effect_completed_ms",
                    snapshot.rotationTiming.dataDisableEffectCompletedMs,
                )
                putNullableLong(
                    "cellular_loss_observed_ms",
                    snapshot.rotationTiming.cellularLossObservedMs,
                )
                putNullableLong(
                    "data_enable_started_ms",
                    snapshot.rotationTiming.dataEnableStartedMs,
                )
                putNullableLong(
                    "data_enable_effect_completed_ms",
                    snapshot.rotationTiming.dataEnableEffectCompletedMs,
                )
'''
    text = replace_once(text, old, new, "diagnostic timing projection")
    write(path, text)


def prepare_kotlin_vocabulary() -> None:
    replacements = {
        "RotationPhaseView.AIRPLANE_ENABLING": "RotationPhaseView.DATA_DISABLING",
        "RotationPhaseView.WAITING_RADIO_DOWN": "RotationPhaseView.WAITING_CELLULAR_LOSS",
        "RotationPhaseView.AIRPLANE_DISABLING": "RotationPhaseView.DATA_ENABLING",
        "RotationFailureView.AIRPLANE_ENABLE_FAILED": "RotationFailureView.DATA_DISABLE_FAILED",
        "RotationFailureView.AIRPLANE_OBSERVATION_FAILED": "RotationFailureView.MOBILE_DATA_OBSERVATION_FAILED",
        "RotationFailureView.AIRPLANE_DISABLE_FAILED": "RotationFailureView.DATA_ENABLE_FAILED",
        "RotationStageUi.RESTORING_RADIO": "RotationStageUi.ENABLING_CELLULAR_DATA",
        "RESTORING_RADIO": "ENABLING_CELLULAR_DATA",
        "RotationFailureUi.AIRPLANE_ENABLE_FAILED": "RotationFailureUi.DATA_DISABLE_FAILED",
        "RotationFailureUi.AIRPLANE_OBSERVATION_FAILED": "RotationFailureUi.MOBILE_DATA_OBSERVATION_FAILED",
        "RotationFailureUi.AIRPLANE_DISABLE_FAILED": "RotationFailureUi.DATA_ENABLE_FAILED",
        "AIRPLANE_ENABLE_FAILED": "DATA_DISABLE_FAILED",
        "AIRPLANE_OBSERVATION_FAILED": "MOBILE_DATA_OBSERVATION_FAILED",
        "AIRPLANE_DISABLE_FAILED": "DATA_ENABLE_FAILED",
        '"Restoring radio"': '"Enabling cellular data"',
        '"Could not disconnect the mobile radio."': '"Could not disable mobile data."',
        '"Could not confirm the radio state."': '"Could not read the mobile-data state."',
        '"Could not restore the mobile radio."': '"Could not enable mobile data."',
    }

    roots = [
        ROOT / "android/app/src/main",
        ROOT / "android/app/src/test",
        ROOT / "android/app/src/androidTest",
    ]
    changed_files: list[str] = []
    for root in roots:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.kt")):
            text = path.read_text(encoding="utf-8")
            updated = text
            for before, after in replacements.items():
                updated = updated.replace(before, after)
            if updated != text:
                path.write_text(updated, encoding="utf-8")
                changed_files.append(path.relative_to(ROOT).as_posix())

    if not changed_files:
        raise SystemExit("Candidate A Android presentation vocabulary produced no changes")


def main() -> None:
    prepare_product_runtime()
    prepare_diagnostics_projection()
    prepare_kotlin_vocabulary()


if __name__ == "__main__":
    main()
