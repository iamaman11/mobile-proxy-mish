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
        "open PR or a merged accepted integration PR",
        "merged candidate source is not contained in current integration lineage",
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
        "mish-device-diagnostic-v2.json",
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
        "snapshot_v2",
        "processIdResult",
        "Write-MishDeviceStartFailureReceipt",
        "PRODUCT_TERMINAL_FAILURE",
    ):
        require(start, required, "deterministic launch contract drifted")
    forbid(start, "snapshot_v1", "obsolete pre-L8 diagnostic method must not return")
    forbid_regex(start, r"\$pid(?![A-Za-z0-9_])", "launcher must not shadow PowerShell automatic PID")
    forbid(start, "su'", "launch stage must stay non-root")

    diagnostic = "lab/windows/collect-device-diagnostic.ps1"
    for required in (
        "mish.diagnostics/v2",
        "mish.lab.diagnostic/v2",
        "snapshot_v2",
        "DeviceDiagnosticClassification.psm1",
        "android.runtime.running",
        "android.cellular.admitted",
        "android.cellular.boundary_failure",
        "android.root.authority_observation",
        "android.root.policy_authorized",
        "android.proxy.healthy",
        "android.mesh.state",
        "android.mesh.admitted",
        "android.mesh.epoch_present",
        "android.mesh.ingress_running",
        "android.readiness.binding_eligible",
        "android.readiness.probe_state",
        "android.proxy.state -ceq 'RUNNING' -and [bool]$android.credential.active",
        "credential_lease_status = $credentialLeaseStatus",
        "Get-MishDeviceDiagnosticClassification",
    ):
        require(diagnostic, required, "native L8 diagnostic attribution must remain complete and fact-first")
    for obsolete in (
        "snapshot_v1",
        "mish.diagnostics/v1",
        "CREDENTIAL_LEASE_UNAVAILABLE",
        "privateBridge",
        "RuntimeProcessLifecycle",
    ):
        forbid(diagnostic, obsolete, "obsolete pre-L8 diagnostic semantics must not return")

    classification = "lab/windows/DeviceDiagnosticClassification.psm1"
    for required in (
        "PRODUCT_RUNTIME_NOT_RUNNING",
        "PRODUCT_ROOT_AUTHORITY_UNAVAILABLE",
        "PRODUCT_ROOT_POLICY_NOT_AUTHORIZED",
        "PRODUCT_CELLULAR_BOUNDARY_",
        "PRODUCT_CELLULAR_",
        "PRODUCT_PROXY_LEGACY_CUTOVER_CLEANUP_BLOCKED",
        "PRODUCT_PROXY_SERVING_UNHEALTHY",
        "PRODUCT_MESH_ADMISSION_EPOCH_MISSING",
        "READINESS_BINDING_INELIGIBLE",
        "READINESS_PROBE_",
    ):
        require(classification, required, "L8 diagnostics must preserve current owner-aligned failure attribution")
    classification_text = read(classification)
    terminal_proxy = classification_text.find("if ($ProxyState -ceq 'FAILED')")
    root_authority = classification_text.find("if ($RootAuthorityObservation -ceq 'UNAVAILABLE')")
    if terminal_proxy < 0 or root_authority < 0 or terminal_proxy > root_authority:
        raise SystemExit(
            "device cycle contract: terminal Proxy Serving failure must outrank downstream root/cellular non-observation"
        )
    forbid(classification, "STALE_PROCESS_IDENTITY_MISMATCH", "pre-L8 process identity must not classify current PRODUCT steady state")
    forbid(classification, "privateBridge", "deleted private-bridge semantics must not classify current PRODUCT steady state")

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
        "Terminal L8 Proxy Serving failure was masked by a downstream non-observation",
        "Current Cellular admission failure was not attributed to Cellular Egress",
        "Missing Mesh admission epoch was not distinguished from external Mesh reachability",
        "Current readiness probe state was not preserved",
        "Healthy current L8 fact set did not classify PASS",
        "Inactive PRODUCT credential was not distinguished from a LAB lease failure",
        "Full PASS report must accept the exact current candidate and contain no automatic probe decision",
        "Explicit probe-only evidence may pass collection but must never claim exact PRODUCT candidate acceptance",
    ):
        require(test, required, "current L8 executable regression coverage drifted")
    forbid(test, "STALE_PROCESS_IDENTITY_MISMATCH", "pre-L8 process identity fixture must not return to canonical PRODUCT diagnostics tests")

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
