#!/usr/bin/env python3
"""Fail-closed guard for the trusted DEVICE-1 repair-cycle orchestrator."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    target = ROOT / path
    if not target.is_file():
        raise SystemExit(f"device cycle contract: required file missing: {path}")
    return target.read_text(encoding="utf-8")


def require(path: str, needle: str, reason: str) -> None:
    if needle not in read(path):
        raise SystemExit(f"device cycle contract: {reason}: {path} lacks {needle!r}")


def forbid(path: str, needle: str, reason: str) -> None:
    if needle in read(path):
        raise SystemExit(f"device cycle contract: {reason}: {path} contains {needle!r}")


def forbid_regex(path: str, pattern: str, reason: str) -> None:
    if re.search(pattern, read(path), flags=re.IGNORECASE):
        raise SystemExit(f"device cycle contract: {reason}: {path} matches /{pattern}/i")


def main() -> None:
    workflow = ".github/workflows/device-cycle.yml"
    for required in (
        "workflow_run:",
        "workflows: ['Integration Android Preflight']",
        "workflow_dispatch:",
        "device-cycle",
        "full",
        "install_only",
        "diagnose_only",
        "probe_only",
        "device-candidate-physical.yml/dispatches",
        "{ref:\"main\"",
        "expected_head_sha",
        "cycle_id",
        "Explicitly restart app and wait for bounded stable state",
        "start-device-app.ps1",
        '-ComponentName "$env:PACKAGE_NAME/com.mobileproxymish.app.MainActivity"',
        '"- Classification: $([string]$report.classification)"',
        "collect-device-diagnostic.ps1",
        "select-device-cycle-probe.ps1",
        "collect-runtime-identity.ps1",
        "diagnose-loopback-connect.ps1",
        "mish-device-cycle-v1.json",
        "AIRPLANE=NOT_RUN",
        "mish-device-cycle-checkpoint",
    ):
        require(workflow, required, "trusted orchestration contract drifted")

    for forbidden in (
        "@('install', '-r'",
        "& $env:ADB_EXE install",
        "gradle --no-daemon",
        "cargo build",
        "cargo ndk",
        "uniffi-bindgen",
        "pm uninstall",
        "adb uninstall",
        '$env:PACKAGE_NAME/.MainActivity',
        '"- Classification: `$([string]$report.classification)`"',
    ):
        forbid(
            workflow,
            forbidden,
            "orchestrator must delegate installation and preserve parse-safe exact launch/summary contracts",
        )

    physical = ".github/workflows/device-candidate-physical.yml"
    for required in (
        "run-name: Device Candidate Physical ${{ inputs.cycle_id || '' }}",
        "cycle_id:",
        "Optional opaque correlation id supplied by the trusted device-cycle orchestrator",
        "Verify, stable-sign, and install without rebuilding",
    ):
        require(physical, required, "canonical installer correlation contract drifted")

    start = "lab/windows/start-device-app.ps1"
    for required in (
        "com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity",
        "am', 'force-stop'",
        "am', 'start', '-W'",
        "snapshot_v1",
        "processIdResult",
        "Write-MishDeviceStartFailureReceipt",
        "failure_category",
        "PROCESS_NOT_STABLE",
        "PRODUCT_TERMINAL_FAILURE",
        "readinessState -ceq 'READY'",
    ):
        require(start, required, "deterministic app start/stabilization contract drifted")
    forbid(start, "com.mobileproxymish.app.debug/.MainActivity", "launcher component must use the manifest class namespace")
    forbid_regex(start, r"\$pid(?![A-Za-z0-9_])", "launcher must not shadow PowerShell's read-only automatic PID variable")
    forbid(start, "su'", "app start stage must stay non-root")

    selector = "lab/windows/select-device-cycle-probe.ps1"
    for required in (
        "STALE_PROCESS_IDENTITY_MISMATCH",
        "CHILD_EXITED",
        "CLEANUP_FAILED",
        "PRODUCT_LOOPBACK_E2E_*",
        "runtime_identity",
        "loopback_connect",
    ):
        require(selector, required, "adaptive one-probe decision table drifted")

    runtime_identity = "lab/windows/collect-runtime-identity.ps1"
    for required in (
        "shell ps -A",
        "run-as",
        "VISIBLE_PROCESS_WITHOUT_RECORDED_IDENTITY",
        "RECORDED_IDENTITY_WITHOUT_VISIBLE_PROCESS",
        "mish.lab.runtime-identity/v1",
    ):
        require(runtime_identity, required, "runtime identity probe contract drifted")
    forbid(runtime_identity, " su ", "runtime identity probe must stay read-only/non-root")

    report = "lab/windows/new-device-cycle-report.ps1"
    for required in (
        "LAB_LAUNCH_",
        "LAB_PROBE_SELECTION_FAILED",
        "LAB_TARGETED_PROBE_COLLECTION_FAILED",
        "targetedRequired",
        "evidence_present",
        "MANUAL_PROBE_COMPLETED",
    ):
        require(report, required, "cycle report must preserve LAB attribution and reject missing requested evidence")

    test = "lab/windows/test-device-cycle.ps1"
    for required in (
        "DEVICE_CYCLE_CONTRACT=PASS",
        "collect-device-diagnostic.ps1",
        "diagnose-loopback-connect.ps1",
        "PowerShell automatic variable `$PID",
        "ownership failure wins over transport classification",
        "loopback failure selects raw CONNECT probe",
        "Explicit manual probe override was not preserved",
        "Product failure was not preserved while optional targeted evidence was missing.",
        "Typed launcher failure was not preserved as a LAB failure.",
        "Missing probe-only evidence must fail closed instead of reporting PASS.",
        "Missing requested diagnose-only probe evidence must fail closed.",
        "Probe-only PASS requires actual targeted evidence.",
    ):
        require(test, required, "device-cycle executable regression coverage drifted")

    docs = "docs/architecture/DEVELOPMENT_PIPELINE.md"
    for required in (
        "## DEVICE-1 development candidate installer",
        "post-install launch/diagnostics belong to `device-cycle.yml`",
        "bounded install receipt / handoff back to Device Cycle",
        "## Canonical DEVICE-1 repair cycle",
        "full / install_only / diagnose_only / probe_only",
        "Automatic mode never runs airplane recovery",
        "Manual modes do not weaken exact-head provenance",
        "first evidence-producing diagnostic action is the canonical aggregate",
    ):
        require(docs, required, "stable device-cycle documentation drifted")

    print("DEVICE_CYCLE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
