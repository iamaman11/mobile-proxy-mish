#!/usr/bin/env python3
"""Fail-closed guard for the simple sequential DEVICE-1 engineering cycle."""

from pathlib import Path
import re

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
        'if [[ "$WORKFLOW_RUN_CONCLUSION" != \'success\' ]]',
        'if [[ "$EVENT_NAME" == \'workflow_run\' && "$current_sha" != "$WORKFLOW_RUN_HEAD_SHA" ]]',
        "probe='none'",
        "probe_only requires an explicit read-only probe",
        "full/install_only/diagnose_only do not choose probes",
        'echo "control_sha=$GITHUB_SHA"',
        '--arg control "$CONTROL_SHA"',
        'control_sha:$control',
        'if [[ "$child_head" != "$CONTROL_SHA" ]]',
        'ref: ${{ needs.resolve.outputs.control_sha }}',
        "Install -> verify installed exact bytes",
        "Explicitly restart app and wait for bounded stable state",
        "Collect one canonical diagnostic snapshot",
        "Explicit probe only - runtime identity",
        "Explicit probe only - loopback CONNECT",
        "AUTOMATIC_REPAIR_DECISION=NO",
        "mish-device-cycle-checkpoint",
    ):
        require(workflow, required, "sequential orchestration contract drifted")

    for forbidden in (
        "select-device-cycle-probe.ps1",
        "RequestedProbe auto",
        "probe='auto'",
        "@('install', '-r'",
        "& $env:ADB_EXE install",
        "gradle --no-daemon",
        "cargo build",
        "cargo ndk",
        "uniffi-bindgen",
        "pm uninstall",
        "adb uninstall",
        '$env:PACKAGE_NAME/.MainActivity',
    ):
        forbid(workflow, forbidden, "orchestrator must observe, never build/install directly or auto-decide repairs/probes")

    physical = ".github/workflows/device-candidate-physical.yml"
    for required in (
        "control_sha:",
        "Exact protected-main CONTROL SHA",
        'if [[ "$GITHUB_SHA" != "$CONTROL_SHA" ]]',
        'ref: ${{ needs.resolve.outputs.control_sha }}',
        "Install exact signed candidate without rebuilding",
        "Verify installed APK bytes and signing identity",
        "verify-installed-candidate.ps1",
        "mish-device-install-verification-v1.json",
    ):
        require(physical, required, "physical install/verification contract drifted")

    verifier = "lab/windows/verify-installed-candidate.ps1"
    for required in (
        "mish.device-install-verification/v1",
        "'shell', 'pm', 'path'",
        "@('pull', $basePaths[0], $pulledApk)",
        "Get-FileHash -Algorithm SHA256",
        "'verify', '--print-certs'",
        "INSTALLED_APK_DIGEST_MISMATCH",
        "INSTALLED_APK_CERT_MISMATCH",
        "exact_bytes_verified = $true",
    ):
        require(verifier, required, "installed exact-byte verification drifted")

    start = "lab/windows/start-device-app.ps1"
    for required in (
        "com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity",
        "am', 'force-stop'",
        "am', 'start', '-W'",
        "snapshot_v1",
        "processIdResult",
        "Write-MishDeviceStartFailureReceipt",
        "PRODUCT_TERMINAL_FAILURE",
    ):
        require(start, required, "deterministic launch contract drifted")
    forbid_regex(start, r"\$pid(?![A-Za-z0-9_])", "launcher must not shadow PowerShell automatic PID")
    forbid(start, "su'", "launch stage must stay non-root")

    diagnostic = "lab/windows/collect-device-diagnostic.ps1"
    for required in (
        "DeviceDiagnosticClassification.psm1",
        "android.proxy.state -ceq 'RUNNING' -and [bool]$android.credential.active",
        "credential_lease_status = $credentialLeaseStatus",
        "Get-MishDeviceDiagnosticClassification",
    ):
        require(diagnostic, required, "diagnostic attribution must remain fact-first")
    forbid(diagnostic, "CREDENTIAL_LEASE_UNAVAILABLE", "ambiguous LAB/Product credential classification must not return")

    report = "lab/windows/new-device-cycle-report.ps1"
    for required in (
        "ControlSha",
        "RequestedProbe",
        "automatic = $false",
        "MANUAL_PROBE_COMPLETED",
        "LAB_TARGETED_PROBE_COLLECTION_FAILED",
    ):
        require(report, required, "cycle report must remain observational")

    test = "lab/windows/test-device-cycle.ps1"
    for required in (
        "DEVICE_CYCLE_CONTRACT=PASS",
        "Primary PRODUCT proxy failure was masked",
        "Inactive PRODUCT credential was not distinguished from a LAB lease failure",
        "Full PASS report must be observational and contain no automatic probe decision",
        "Explicit probe-only evidence must remain manual and attributable",
    ):
        require(test, required, "executable regression coverage drifted")

    docs = "docs/architecture/DEVELOPMENT_PIPELINE.md"
    for required in (
        "diagnostic -> analysis -> decision -> code -> completed build -> install -> verify install -> launch -> diagnostic -> analysis",
        "Diagnostics never chooses a repair",
        "No automatic targeted probe",
        "CONTROL_SHA",
        "installed base.apk SHA-256",
        "Automatic mode never runs airplane recovery",
    ):
        require(docs, required, "stable sequential-cycle documentation drifted")

    print("DEVICE_CYCLE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
