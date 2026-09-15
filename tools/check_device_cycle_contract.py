#!/usr/bin/env python3
"""Fail-closed guard for the explicit, single-run DEVICE-1 engineering cycle."""

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
        "issue_comment:",
        "types: [created]",
        "github.actor == 'iamaman11'",
        "startsWith(github.event.comment.body, '/mish-cycle ')",
        "expected /mish-cycle <mode> <40-hex-sha> [probe]",
        "device-cycle requires an explicit exact 40-hex PRODUCT SHA",
        "build first, then explicitly request the cycle",
        "candidate build is not a completed successful PR preflight",
        "Integration Android Preflight",
        "probe_only requires exactly one explicit read-only probe",
        "full/install_only/diagnose_only do not accept a probe",
        'echo "control_sha=$GITHUB_SHA"',
        "actions: read",
        "Exercise orchestration and installer contracts",
        ".\\lab\\windows\\test-device-candidate.ps1",
        "Install -> verify installed exact bytes",
        "Download exact completed hosted candidate",
        "Install exact signed candidate without rebuilding",
        "Verify installed APK bytes and signing identity",
        "verify-installed-candidate.ps1",
        "mish-device-install-verification-v1.json",
        'ref: ${{ needs.resolve.outputs.control_sha }}',
        "Launch -> canonical diagnostic -> STOP",
        "Explicitly restart app and wait for bounded stable state",
        "Collect one canonical diagnostic snapshot",
        "Explicit probe only - runtime identity",
        "Explicit probe only - loopback CONNECT",
        "Automatic cycle start: **NO**",
        "Automatic repair/probe decision: **NO**",
        "STOP_FOR_ANALYSIS",
        "PRODUCER_PATH='.github/workflows/integration-android-preflight.yml'",
        "PRODUCT_PRODUCER_SHA",
        "CONTROL_PRODUCER_SHA",
        "candidate producer workflow differs from accepted protected-main producer",
        "Accepted producer policy",
        "Exact candidate acceptance",
    ):
        require(workflow, required, "explicit single-run orchestration contract drifted")

    for forbidden in (
        "workflow_run:",
        "workflow_dispatch:",
        "Dispatch canonical physical installer",
        "device-candidate-physical.yml/dispatches",
        "device-candidate-physical.yml/runs",
        "actions: write",
        "select-device-cycle-probe.ps1",
        "RequestedProbe auto",
        "probe='auto'",
        "mish-device-cycle-checkpoint",
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
        forbid(workflow, forbidden, "cycle must not auto-start, spawn another physical workflow, rebuild, or auto-decide repairs")

    workflow_text = read(workflow)
    physical_jobs = workflow_text.split("\n  install:", 1)
    if len(physical_jobs) != 2:
        raise SystemExit("device cycle contract: install job boundary is missing")
    physical_text = physical_jobs[1]
    pinned_pwsh = r"C:\mish-lab\tools\powershell-7.6.6\pwsh.exe -NoLogo -NoProfile -NonInteractive"
    github_scriptblock_shell = "-Command \"& ([ScriptBlock]::Create((Get-Content -Raw -LiteralPath ''{0}'')))\""
    if pinned_pwsh not in physical_text:
        raise SystemExit("device cycle contract: DEVICE-1 jobs must execute through pinned portable PowerShell 7.6.6")
    if github_scriptblock_shell not in physical_text:
        raise SystemExit("device cycle contract: pinned PowerShell must execute GitHub's extensionless temp script from text through ScriptBlock::Create")
    if "Get-Content -Raw -LiteralPath ''{0}''" not in physical_text or "[ScriptBlock]::Create" not in physical_text:
        raise SystemExit("device cycle contract: GitHub extensionless temp script must be read as text before execution")
    for broken_shell in ('-File "{0}"', "-Command \". ''{0}''\""):
        if broken_shell in workflow_text:
            raise SystemExit(f"device cycle contract: broken extensionless PowerShell invocation must not return: {broken_shell}")
    if "DEVICE_CYCLE_PWSH_VERSION: '7.6.6'" not in workflow_text:
        raise SystemExit("device cycle contract: pinned PowerShell version fact is missing")
    if physical_text.count("Verify pinned PowerShell 7 runtime") != 2:
        raise SystemExit("device cycle contract: both DEVICE-1 jobs must verify the pinned PowerShell runtime")
    if "shell: powershell" in workflow_text:
        raise SystemExit("device cycle contract: Windows PowerShell 5.1 must not execute Device Cycle steps")

    obsolete_physical = ROOT / ".github/workflows/device-candidate-physical.yml"
    if obsolete_physical.exists():
        raise SystemExit(
            "device cycle contract: separate Device Candidate Physical workflow must not return; "
            "normal install/verify belongs to Device Cycle"
        )

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
        "exact_candidate_acceptance",
        "NOT_EVALUATED",
        "MISH_DEVICE_CYCLE_EXACT_CANDIDATE_ACCEPTANCE",
    ):
        require(report, required, "cycle report must distinguish evidence collection from exact PRODUCT acceptance")

    test = "lab/windows/test-device-cycle.ps1"
    for required in (
        "DEVICE_CYCLE_CONTRACT=PASS",
        "Primary PRODUCT proxy failure was masked",
        "Inactive PRODUCT credential was not distinguished from a LAB lease failure",
        "Full PASS report must accept the exact candidate and contain no automatic probe decision",
        "Explicit probe-only evidence may pass collection but must never claim exact PRODUCT candidate acceptance",
    ):
        require(test, required, "executable regression coverage drifted")

    docs = "docs/architecture/DEVELOPMENT_PIPELINE.md"
    for required in (
        "diagnostic -> analysis -> decision -> code -> completed build -> explicit cycle request -> install -> verify install -> launch -> diagnostic -> analysis",
        "Diagnostics never chooses a repair",
        "No automatic targeted probe",
        "No successful build, merge to main, label, or completed workflow starts DEVICE-1",
        "/mish-cycle full <PRODUCT_SHA>",
        "one GitHub Actions Device Cycle run",
        "CONTROL_SHA",
        "installed base.apk SHA-256",
        "Automatic airplane recovery is not part of the baseline cycle",
        "producer workflow blob",
        "exact_candidate_acceptance",
    ):
        require(docs, required, "stable explicit-cycle documentation drifted")

    print("DEVICE_CYCLE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
