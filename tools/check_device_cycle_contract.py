#!/usr/bin/env python3
"""Fail-closed guard for the explicit single-run current-L8 DEVICE-1 cycle."""

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
    validation_workflow = ".github/workflows/integration-android-preflight.yml"

    require(
        workflow,
        "'- Next action: **STOP_FOR_ANALYSIS**'\n            ) | Add-Content",
        "Device Cycle summary must remain valid PowerShell without a trailing array comma",
    )

    for required in (
        "workflow_dispatch:",
        "issue_comment:",
        "types: [created]",
        "pr_number:",
        "product_sha:",
        "type: choice",
        "github.actor == 'iamaman11'",
        "startsWith(github.event.comment.body, '/mish-cycle ')",
        "Normalize explicit manual request",
        "/mish-cycle <PR> <PRODUCT_SHA> <mode> <probe>",
        '"trigger": "operator_comment"',
        "PR_NUMBER: ${{ steps.request.outputs.pr_number }}",
        "EXPECTED_SHA: ${{ steps.request.outputs.product_sha }}",
        "MODE: ${{ steps.request.outputs.mode }}",
        "PROBE: ${{ steps.request.outputs.probe }}",
        "device cycle control must be dispatched from current protected main",
        "device-cycle requires an explicit exact 40-hex PRODUCT SHA",
        "installing a device candidate requires an open PR to main",
        "installing a device candidate requires base main",
        "installing a device candidate requires a ready PR",
        "build first, then explicitly request the cycle",
        "candidate build is not a completed successful PR preflight",
        "PR Validation + PRODUCT Candidate",
        "probe_only supports only the current-function loopback_connect probe",
        "full accepts only none, capacity_resources, recovery_lifecycle, dns_lifetime_live, u5_rotation, u7_runtime_restart_resources, u7_512_lifecycle_stability, or u8_reboot_install_durability",
        "install_only/diagnose_only require probe=none",
        "capacity_resources",
        "recovery_lifecycle",
        "dns_lifetime_live",
        "u5_rotation",
        "u7_runtime_restart_resources",
        "u7_512_lifecycle_stability",
        "u8_reboot_install_durability",
        "Explicit U8 reboot + replacement-install durability",
        "diagnose-u8-reboot-install-durability.ps1",
        "Explicit U3 DNS lifetime - live same-process observation",
        "diagnose-dns-lifetime-live.ps1",
        "Explicit U5 rotation - PRODUCT-owned airplane cycle acceptance",
        "diagnose-u5-rotation.ps1",
        "Explicit U7 runtime restart resources - same-process STOP/START",
        "diagnose-u7-runtime-restart-resources.ps1",
        "Explicit U7 repeated 512 + rotation + stop-during-ON restart stability",
        "diagnose-u7-512-lifecycle-stability.ps1",
        'echo "control_sha=$GITHUB_SHA"',
        "actions: read",
        "steps.request.outputs.trigger",
        "Install -> verify installed exact bytes",
        "Download exact completed hosted candidate",
        "Materialize exact hosted candidate in canonical Windows store",
        "DEVICE_CANDIDATE_STORE_ROOT: C:\\\\mish-lab\\\\runner\\\\.state\\\\device-candidate\\\\versions",
        "Install exact signed candidate without rebuilding",
        "Verify installed APK bytes and signing identity",
        "verify-installed-candidate.ps1",
        "installed-verification-v2.json",
        'ref: ${{ needs.resolve.outputs.control_sha }}',
        "Launch -> canonical diagnostic -> STOP",
        "Explicitly restart app and wait for bounded stable state",
        "Collect one canonical current-L8 diagnostic snapshot",
        "mish-device-diagnostic-v2.json",
        "Explicit current-function probe only - loopback CONNECT",
        "Explicit U7 capacity/resources - external Mesh",
        "diagnose-capacity-resources.ps1",
        "steps.baseline.outcome == 'success'",
        "Automatic cycle start: **NO**",
        "Automatic repair/probe decision: **NO**",
        "STOP_FOR_ANALYSIS",
        "PRODUCER_PATH='.github/workflows/integration-android-preflight.yml'",
        "PRODUCT_PRODUCER_SHA",
        "CONTROL_PRODUCER_SHA",
        "candidate producer workflow differs from accepted protected-main producer",
        "Accepted producer policy",
        "Exact candidate acceptance",
        "Targeted acceptance",
    ):
        require(workflow, required, "explicit single-run orchestration contract drifted")

    require(
        "lab/windows/test-device-cycle.ps1",
        "test-u8-reboot-install-probe-contract.ps1",
        "U8 durability probe guard must run inside the existing Device Cycle Contracts job without changing candidate-producer policy",
    )

    for required in (
        "name: Device Cycle Contracts",
        "runs-on: windows-latest",
        "Verify Device Cycle orchestration contracts",
        ".\\lab\\windows\\test-device-candidate-store.ps1",
        ".\\lab\\windows\\test-device-candidate.ps1",
        ".\\lab\\windows\\test-device-cycle.ps1",
        ".\\lab\\windows\\test-recovery-lifecycle-probe-contract.ps1",
        ".\\lab\\windows\\test-dns-lifetime-live-probe-contract.ps1",
        ".\\lab\\windows\\test-u5-rotation-probe-contract.ps1",
        "python .\\tools\\check_device_cycle_contract.py",
    ):
        require(validation_workflow, required, "Device Cycle contract verification must remain in protected-main PR validation")

    for forbidden in (
        "fix/root-policy-reconciliation",
        "merged candidate source is not contained in current integration lineage",
        "workflow_run:",
        "pull_request:",
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
        "runtime_identity",
        "LEGACY_MIGRATION",
        "LEGACY_CUTOVER",
    ):
        forbid(workflow, forbidden, "cycle must stay main-based, explicit, non-building and current-L8 only")

    workflow_text = read(workflow)
    physical_jobs = workflow_text.split("\n  install:", 1)
    if len(physical_jobs) != 2:
        raise SystemExit("device cycle contract: install job boundary is missing")
    physical_text = physical_jobs[1]
    pinned_pwsh = r"C:\\mish-lab\\tools\\powershell-7.6.6\\pwsh.exe -NoLogo -NoProfile -NonInteractive"
    github_scriptblock_shell = "-Command \"& ([ScriptBlock]::Create((Get-Content -Raw -LiteralPath ''{0}'')))\""
    if pinned_pwsh not in physical_text:
        raise SystemExit("device cycle contract: DEVICE-1 jobs must use pinned portable PowerShell 7.6.6")
    if github_scriptblock_shell not in physical_text:
        raise SystemExit("device cycle contract: pinned PowerShell must execute GitHub temp script through ScriptBlock::Create")
    if physical_text.count("Verify pinned PowerShell 7 runtime") != 2:
        raise SystemExit("device cycle contract: both DEVICE-1 jobs must verify pinned PowerShell")
    if "shell: powershell" in workflow_text:
        raise SystemExit("device cycle contract: Windows PowerShell 5.1 must not execute Device Cycle")

    for obsolete_path in (".github/workflows/device-candidate-physical.yml", "lab/windows/collect-runtime-identity.ps1"):
        if (ROOT / obsolete_path).exists():
            raise SystemExit(f"device cycle contract: obsolete path must not exist: {obsolete_path}")

    materializer = "lab/windows/materialize-device-candidate.ps1"
    for required in (
        "C:\\mish-lab\\runner\\.state\\device-candidate\\versions",
        "mish.device-candidate-local/v1",
        "version_root",
        "hosted_directory",
        "signed_directory",
        "receipts_directory",
        "provenance.json",
        "STORE_DIGEST_CONFLICT",
    ):
        require(materializer, required, "canonical durable candidate store drifted")
    for forbidden in ("latest", "current"):
        forbid_regex(materializer, rf"Join-Path\s+\$store\s+['\"]{forbidden}['\"]", "mutable candidate alias is forbidden")

    installer = "lab/windows/install-device-candidate.ps1"
    for required in (
        "mish.device-candidate-install/v2",
        "hosted_product_apk_sha256",
        "lab_signed_product_apk_sha256",
        "SignedOutputDirectory",
    ):
        require(installer, required, "hosted/LAB-signed identity split drifted")

    verifier = "lab/windows/verify-installed-candidate.ps1"
    for required in (
        "mish.device-install-verification/v2",
        "'shell', 'pm', 'path'",
        "@('pull', $basePaths[0], $pulledApk)",
        "Get-FileHash -Algorithm SHA256",
        "INSTALLED_APK_DIGEST_MISMATCH",
        "INSTALLED_APK_CERT_MISMATCH",
        "hosted_to_lab_signed_lineage_verified = $true",
        "installed_matches_lab_signed_candidate = $true",
        "exact_installed_bytes_verified = $true",
    ):
        require(verifier, required, "installed exact-byte verification drifted")

    start = "lab/windows/start-device-app.ps1"
    for required in (
        "com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity",
        "am', 'force-stop'",
        "am', 'start', '-W'",
        "snapshot_v2",
        "processIdResult",
        "PRODUCT_TERMINAL_FAILURE",
    ):
        require(start, required, "deterministic launch contract drifted")
    forbid(start, "snapshot_v1", "obsolete diagnostic method must not return")
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
        "android.root.policy_authorized",
        "android.proxy.healthy",
        "android.mesh.admitted",
        "android.mesh.ingress_running",
        "android.readiness.binding_eligible",
        "android.readiness.probe_state",
        "Get-MishDeviceDiagnosticClassification",
    ):
        require(diagnostic, required, "native L8 diagnostic attribution must remain fact-first")
    for obsolete in ("snapshot_v1", "privateBridge", "RuntimeProcessLifecycle", "LEGACY_MIGRATION", "runtime_identity"):
        forbid(diagnostic, obsolete, "pre-L8 diagnostic semantics must not return")

    protocol_probe = "lab/windows/diagnose-loopback-connect.ps1"
    for required in (
        "canonical_ports = @(1080, 1081, 3128)",
        "$forwardPorts[1080]",
        "$forwardPorts[1081]",
        "$forwardPorts[3128]",
        "Invoke-MishDiagnosticHttpRelayProbe",
        "Invoke-MishDiagnosticSocks5RelayProbe",
        "-ExpectAuthRejection",
        "protocol_matrix = $protocolMatrix",
        "U2_PROXY_PROTOCOL_MATRIX_PASS",
        "MISH_LOOPBACK_DIAGNOSTIC_PROTOCOL_MATRIX_PASS",
    ):
        require(protocol_probe, required, "U2 physical protocol/auth/relay evidence drifted")
    for forbidden in ("sing-box", "'shell', 'su'", "'shell', 'kill'", "'shell', 'pkill'", "'shell', 'am', 'force-stop'"):
        forbid(protocol_probe, forbidden, "U2 protocol probe must remain read-only, non-root and current-PRODUCT-only")

    dns_probe = "lab/windows/diagnose-dns-lifetime-live.ps1"
    for required in (
        "mish.lab.dns-lifetime-live/v1",
        "Invoke-MishExternalProxyCredentialProvisioning",
        "Open-MishExternalProxyCredentialLease",
        "cmd', 'phone', 'data'",
        "LAB_DNS_LIFETIME_PROCESS_CHANGED",
        "LAB_DNS_LIFETIME_RECOVERY_SEQUENCE_UNOBSERVED",
        "U3_DNS_LIFETIME_LIVE_OBSERVATION_COMPLETE",
        "last_started_owner_sequence",
        "completed_after_owner_change",
        "discarded_after_deadline",
        "discarded_stale",
        "quiescent_after_recovery",
        "observation_only = $true",
        "same_process = $true",
        'https://mish-dns-$RunTag-$Ordinal.example.com/',
    ):
        require(dns_probe, required, "U3 DNS lifetime observation must stay bounded and same-process")
    for forbidden in (
        "'shell', 'su'",
        "'shell', 'iptables'",
        "'shell', 'ip6tables'",
        "am', 'instrument'",
        "airplane-mode",
        "gradle ",
        "cargo build",
    ):
        forbid(dns_probe, forbidden, "DNS lifetime observation must not become a second PRODUCT/root/build path")


    u8_probe = "lab/windows/diagnose-u8-reboot-install-durability.ps1"
    for required in (
        "mish.lab.u8-reboot-install-durability/v2",
        "snapshot_v2",
        "Do not touch the diagnostics provider until PRODUCT is independently observable",
        "@('install', '-r', $SignedProductApkPath)",
        "adb_install_r_attempts = 1",
        "Invoke-MishAdbCapture -Arguments @('reboot')",
        "adb_reboot_attempts = 1",
        "/proc/sys/kernel/random/boot_id",
        "sys.boot_completed",
        "'shell', 'dumpsys', 'user'",
        "RUNNING_UNLOCKED",
        "UserUnlockTimeoutSeconds = 300",
        "LAB_REBOOT_USER_UNLOCK_NOT_OBSERVED",
        "convergence_milestones_ms",
        "verify-installed-candidate.ps1",
        "PRODUCT_REPLACEMENT_AUTOSTART_NOT_OBSERVED",
        "PRODUCT_REPLACEMENT_UID_CHANGED",
        "PRODUCT_REPLACEMENT_SIGNER_CHANGED",
        "PRODUCT_REPLACEMENT_ROOT_AUTHORITY_NOT_RESTORED",
        "PRODUCT_REBOOT_AUTOSTART_NOT_OBSERVED",
        "PRODUCT_REBOOT_NOT_READY",
        "PRODUCT_REBOOT_ROOT_AUTHORITY_NOT_RESTORED",
        "U8_REBOOT_INSTALL_DURABILITY_PASS",
        "secrets_persisted_in_evidence = $false",
        "raw_public_ip_persisted = $false",
    ):
        require(u8_probe, required, "U8 reboot/install durability evidence contract drifted")
    for forbidden in (
        "'shell', 'su'",
        "'shell', 'iptables'",
        "'shell', 'ip6tables'",
        "pm uninstall",
        "adb uninstall",
        "airplane-mode",
        "'cmd', 'phone', 'data'",
        "settings put",
        "svc data",
        "gradle ",
        "cargo build",
        "ProxyUserName",
        "ProxyPassword",
        "before_ip",
        "after_ip",
        "retry-until",
        "retry_until",
    ):
        forbid(u8_probe, forbidden, "U8 durability probe must stay bounded CONTROL/LAB-only")

    u8_probe_contract = "lab/windows/test-u8-reboot-install-probe-contract.ps1"
    for required in (
        "U8_REBOOT_INSTALL_PROBE_CONTRACT=PASS",
        "exactly one deliberate replacement-install command",
        "exactly one physical reboot request",
    ):
        require(u8_probe_contract, required, "U8 durability self-test drifted")

    rotation_probe = "lab/windows/diagnose-u5-rotation.ps1"
    for required in (
        "mish.lab.u5-rotation-acceptance/v1",
        "DebugRotationActivity",
        "DebugRuntimeStopActivity",
        "'shell', 'cmd', 'connectivity', 'airplane-mode'",
        "SuccessfulOperations = 3",
        "rotation_active_tasks",
        "runtime_generation_stable_across_normal_rotations",
        "root_session_stable_across_normal_rotations",
        "rotation_tasks_quiescent",
        "request_to_airplane_on_ms",
        "request_to_cellular_loss_ms",
        "loss_to_airplane_off_request_ms",
        "off_to_fresh_owner_ms",
        "off_to_root_policy_authorized_ms",
        "off_to_readiness_ready_ms",
        "off_to_functional_public_ip_ms",
        "total_rotation_ms",
        "material_unchanged = $credentialMaterialUnchanged",
        "secrets_persisted_in_evidence = $false",
        "raw_ip_persisted = $false",
        "runtime_io_thread_name_observation_required = $false",
        "U5_ROTATION_PHYSICAL_ACCEPTANCE_PASS",
        "PRODUCT_RESTORE_OFF_FAILED",
        "PRODUCT_STOP_NOT_QUIESCENT",
        "PRODUCT_RUNTIME_CREDENTIAL_NOT_CLEARED",
        "MISH_U5_RESTORE_PHASE=RUNTIME_STOPPED_CREDENTIAL_CLEARED",
        "runtime_stopped_observed = $runtimeStopped",
        "runtime_credential_cleared = $runtimeCredentialCleared",
        "MISH_U5_RESTORE_RESTART_STATE=",
        "restart_pid_before = $ExpectedProcessId",
        "restart_pid_after = $restartPid",
        "restart_process_stable = -not $restartPidChanged",
        "restart_recovery_elapsed_ms = $restartElapsedMs",
        "cellular_reconcile_pending=",
        "root_recovery_pending=",
        "rotation_active_tasks=",
        "'shell', 'ps', '-A', '-T', '-w', '-o', 'PID,TID,CMD'",
        "row = [regex]::Match",
        "Groups['pid'].Value -eq $processId",
        "Android ps -A -T returned no PRODUCT thread rows.",
        "$_ -like 'mish-runtime-i*'",
        "MISH_U5_TOPOLOGY_THREAD_NAME_SET=",
        "MISH_U5_TOPOLOGY_RUNTIME_IO_THREADS=",
        "MISH_U5_TOPOLOGY_FORBIDDEN_KOTLIN_OWNER_THREADS=",
        "LAB_ADB_TIMEOUT",
        "WaitForExit($script:AdbTransportTimeoutMilliseconds)",
        "$process.Kill($true)",
        "MISH_U5_ROTATION_OPERATION_START=",
        "[AllowEmptyCollection()][System.Collections.Generic.List[object]] $Timeline",
        "MISH_U5_ROTATION_TIMELINE=",
        "MISH_U5_RESTORE_PHASE=",
        "Start-MishFastAirplaneObserver",
        "Stop-MishFastAirplaneObserver",
        "settings get global airplane_mode_on",
        "$startInfo.RedirectStandardInput = $true",
        "[void]$startInfo.ArgumentList.Add('shell')",
        "$process.StandardInput.Write($deviceScript)",
        "$process.StandardInput.Close()",
        "OBSERVER_READY",
        "$process.StandardOutput.ReadLineAsync()",
        "observer_exit_code",
        "stderr_empty",
        "sleep 0.05",
        "MISH_U5_FAST_AIRPLANE=",
        "STOP_TRIGGER_EXIT=",
        "$restoreTemplate.Replace('__MAX__', [string]$maxSamples).Replace('__STOP__', $StopComponent)",
        "airplane_fast_observer",
        "Invoke-MishActivityTrigger",
        "'shell', 'am', 'start', '-n'",
        "LAB_ACTIVITY_TRIGGER_FAILED",
    ):
        require(rotation_probe, required, "U5 physical rotation evidence drifted")
    for forbidden in (
        "airplane-mode enable",
        "airplane-mode disable",
        "'shell', 'su'",
        "'shell', 'iptables'",
        "'shell', 'ip6tables'",
        "settings put",
        "svc data",
        "'cmd', 'phone', 'data'",
        "gradle ",
        "cargo build",
        "assembleDebug",
        "before_ip",
        "after_ip",
        "$metricsBefore.runtime_io_threads -lt 1",
        "-not $runtimeIoStableAcrossRotations -or",
        "$runtimeIoStable -and",
        "task/*/comm",
        "'shell', 'ps', '-T', '-p'",
        "'-o', 'NAME'",
        "$output = @(& $AdbPath @Arguments",
        "'shell', 'am', 'start', '-W'",
        "@('shell', 'sh', '-c', $shell)",
        "foreach ($argument in @('shell', $shell))",
        "Invoke-MishActivityTrigger -Component $script:StopComponent -Operation 'restore_stop_trigger'",
        "Credential version changed during restore case.",
    ):
        forbid(rotation_probe, forbidden, "U5 LAB probe must observe PRODUCT rotation, never own airplane/root/build semantics")

    rotation_probe_contract = "lab/windows/test-u5-rotation-probe-contract.ps1"
    for required in (
        "U5_ROTATION_PROBE_CONTRACT=PASS",
        "airplane-mode enable",
        "airplane-mode disable",
        "DebugRotationActivity",
        "DebugRuntimeStopActivity",
    ):
        require(rotation_probe_contract, required, "U5 physical-probe self-test drifted")

    capacity_probe = "lab/windows/diagnose-capacity-resources.ps1"
    for required in (
        "mish.diagnostics/v2",
        "$snapshot.mesh.active_sessions",
        "$snapshot.proxy.active_sessions",
        "[bool]$last.consistent",
        "Find-NetRoute -RemoteIPAddress $meshAddress",
        "ConnectAsync($ProxyHost, 3128)",
        "foreach ($target in @(10, 32, 64, 512))",
        "Test-MishOverflowRejected",
        "Wait-MishOwnerCounts -ExpectedMesh 512 -ExpectedProxy 512",
        "Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0",
        "U7Measurement.psm1",
        "u7-capacity-512-v1",
        "capacity_target = 512",
        "overflow_ordinal = 513",
        "U7_CAPACITY_513TH_NOT_REJECTED",
        "independent_bounded",
        "Get-MishSafeOwnerDiagnostics",
        "Measure-MishU7SupplementalObservation",
        "$stageRecord['cleanup']",
        "resource_delta_from_idle",
        "'shell', 'run-as', $PackageName, 'cat'",
        "'shell', 'dumpsys', 'meminfo', '-s'",
        "mish.lab.capacity-resources/v1",
        "acceptance_result = $acceptanceResult",
        "U7_CAPACITY_512_PASS",
        "post_cleanup_delta_from_idle",
    ):
        require(capacity_probe, required, "U7 external-Mesh baseline evidence drifted")
    for forbidden in (
        "'forward'",
        "'shell', 'su'",
        "'shell', 'kill'",
        "'shell', 'pkill'",
        "airplane-mode",
        "settings put",
        "sing-box",
    ):
        forbid(capacity_probe, forbidden, "capacity/resource probe must remain external-Mesh, read-only and non-root")

    u7_measurement = "lab/windows/U7Measurement.psm1"
    for required in (
        "Get-MishU7CpuObservation",
        "process_cpu_percent_total_capacity",
        "process_cpu_percent_one_core_equivalent",
        "voluntary_context_switches_delta",
        "wakeups_supported = $false",
        "'dumpsys', 'battery'",
        "'dumpsys', 'thermalservice'",
        "'ps', '-A', '-o', 'PID,PPID,NAME'",
        "'ps', '-A', '-T', '-w', '-o', 'PID,TID,CMD'",
        "'mish-runtime-i*'",
        "external_powered = $externalPower",
        "product_su_like_descendants",
    ):
        require(u7_measurement, required, "U7 host observation coverage drifted")
    for forbidden in ("'shell', 'su'", "'shell', 'kill'", "'shell', 'pkill'", "settings put", "airplane-mode"):
        forbid(u7_measurement, forbidden, "U7 measurement helper must remain read-only and non-root")

    probe_module = "lab/windows/DiagnosticConnectProbe.psm1"
    for required in (
        "Invoke-MishDiagnosticHttpRelayProbe",
        "Invoke-MishDiagnosticSocks5RelayProbe",
        "INVALID_AUTH_NOT_REJECTED",
        "AUTH_REJECTED",
        "RELAY_CONFIRMED",
        "GET / HTTP/1.1",
    ):
        require(probe_module, required, "bounded protocol client semantics drifted")
    for forbidden in ("ProcessBuilder", "su -c", "pkill", "kill -9"):
        forbid(probe_module, forbidden, "protocol probe must not become a privileged control path")

    classification = "lab/windows/DeviceDiagnosticClassification.psm1"
    for required in (
        "PRODUCT_RUNTIME_NOT_RUNNING",
        "PRODUCT_ROOT_AUTHORITY_UNAVAILABLE",
        "PRODUCT_ROOT_POLICY_NOT_AUTHORIZED",
        "PRODUCT_CELLULAR_BOUNDARY_",
        "PRODUCT_PROXY_SERVING_UNHEALTHY",
        "PRODUCT_MESH_ADMISSION_EPOCH_MISSING",
        "READINESS_BINDING_INELIGIBLE",
        "READINESS_PROBE_",
    ):
        require(classification, required, "owner-aligned failure attribution drifted")
    classification_text = read(classification)
    terminal_proxy = classification_text.find("if ($ProxyState -ceq 'FAILED')")
    root_authority = classification_text.find("if ($RootAuthorityObservation -ceq 'UNAVAILABLE')")
    if terminal_proxy < 0 or root_authority < 0 or terminal_proxy > root_authority:
        raise SystemExit("device cycle contract: terminal Proxy failure must outrank downstream non-observation")

    recovery_probe = "lab/windows/diagnose-recovery-lifecycle.ps1"
    for required in (
        "Stop-MishProductProcessForInstrumentation",
        "'shell', 'am', 'force-stop', $PackageName",
        "'shell', 'pidof', $PackageName",
        "LAB_INSTRUMENTATION_HANDOFF_FORCE_STOP_FAILED",
        "LAB_INSTRUMENTATION_HANDOFF_PROCESS_STILL_ALIVE",
        "instrumentation_handoff = $instrumentationHandoff",
        "'shell', 'am', 'instrument'",
    ):
        require(
            recovery_probe,
            required,
            "recovery/lifecycle instrumentation handoff must stay explicit and single-process",
        )
    recovery_source = read(recovery_probe)
    handoff = recovery_source.find("$handoff = Stop-MishProductProcessForInstrumentation")
    instrument = recovery_source.find("'shell', 'am', 'instrument'")
    if handoff < 0 or instrument < 0 or handoff >= instrument:
        raise SystemExit(
            "device cycle contract: baseline PRODUCT process must be stopped before recovery instrumentation"
        )
    forbid(recovery_probe, "'shell', 'su'", "recovery handoff must not become a LAB root-policy path")

    report = "lab/windows/new-device-cycle-report.ps1"
    for required in (
        "ControlSha",
        "RequestedProbe",
        "loopback_connect",
        "capacity_resources",
        "recovery_lifecycle",
        "dns_lifetime_live",
        "u5_rotation",
        "u7_runtime_restart_resources",
        "u7_512_lifecycle_stability",
        "FULL_BASELINE_PLUS_DNS_LIFETIME_OBSERVATION",
        "FULL_BASELINE_PLUS_U5_ROTATION",
        "FULL_BASELINE_PLUS_U7_RUNTIME_RESTART_RESOURCES",
        "FULL_BASELINE_PLUS_U7_512_LIFECYCLE_STABILITY",
        "Get-MishTargetedAcceptance",
        "protocol_matrix_pass",
        "acceptance_result",
        "FULL_BASELINE_PLUS_CAPACITY_RESOURCES",
        "automatic = $false",
        "exact_candidate_acceptance",
        "NOT_EVALUATED",
        "Baseline facts outrank targeted-probe absence/failure",
    ):
        require(report, required, "cycle report evidence semantics drifted")

    test = "lab/windows/test-device-cycle.ps1"
    for required in (
        "DEVICE_CYCLE_CONTRACT=PASS",
        "test-u7-runtime-restart-probe-contract.ps1",
        "PRODUCT_PROXY_MIXED_LISTENER_UNAVAILABLE",
        "Healthy current L8 fact set did not classify PASS",
        "Full PASS report must accept the exact current candidate and contain no automatic probe decision",
        "A collected but failing loopback matrix must not be promoted to a green probe",
        "A real capacity failure must reject the exact PRODUCT candidate",
        "DNS lifetime observation PASS must remain measurement-only",
        "DNS lifetime collection failure must remain LAB-only",
        "A baseline PRODUCT failure must still outrank measurement-only DNS evidence",
        "U5 rotation PASS must accept the exact candidate only with baseline + targeted physical evidence",
        "Observed U5 rotation PRODUCT failure must reject the exact candidate",
        "LAB U5 rotation collection failure must not reject the PRODUCT candidate",
        "U7 runtime restart resource PASS must accept the exact candidate only with baseline + targeted evidence",
        "Observed U7 runtime restart resource PRODUCT failure must reject the exact candidate",
        "LAB U7 runtime restart collection failure must not reject the PRODUCT candidate",
        "Baseline PRODUCT failure must outrank absent capacity evidence",
        "diagnose-capacity-resources.ps1",
        "U7_CAPACITY_512_PASS",
        "test-diagnostic-connect-probe.ps1",
    ):
        require(test, required, "current L8 executable regression coverage drifted")

    docs = "docs/architecture/DEVELOPMENT_PIPELINE.md"
    for required in (
        "diagnostic -> analysis -> decision -> code -> completed build -> explicit cycle request -> install -> verify install -> launch -> diagnostic -> analysis",
        "Diagnostics never chooses a repair",
        "No automatic targeted probe",
        "No successful build, merge to main, label, or completed workflow starts DEVICE-1",
        "workflow_dispatch",
        "pr_number",
        "product_sha",
        "mode",
        "probe",
        "u5_rotation",
        "measurement-only",
        "PRODUCT-owned rotation",
        "external Mesh endpoint",
        "owner-backed",
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
