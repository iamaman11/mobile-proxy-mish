[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CandidateDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedSourceSha,
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $ComponentName = 'com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity',
    [Parameter(Mandatory)][string] $InitialLaunchReceiptPath,
    [Parameter(Mandatory)][string] $PostRestartReceiptPath,
    [Parameter(Mandatory)][string] $PostRestartDiagnosticPath,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-recovery-lifecycle-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.recovery-lifecycle/v1'
$script:CandidateSchema = 'mish-device-candidate-v1'
$script:TestPackage = "$PackageName.test"
$script:TestClass = 'com.mobileproxymish.app.cellular.CellularE3InstrumentedTest'
$script:TestMethod = 'runPhysicalScenario'
$script:TestComponent = "$($script:TestPackage)/androidx.test.runner.AndroidJUnitRunner"
$script:SnapshotMethod = 'snapshot_v2'

function Stop-MishRecovery {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_RECOVERY_FAILURE|$Classification|$Message"
}

function Invoke-MishProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 60
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Stop-MishRecovery 'LAB_PROCESS_START_FAILED' 'Required subprocess could not be started.'
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            Stop-MishRecovery 'LAB_PROCESS_TIMEOUT' 'Required subprocess exceeded its bounded timeout.'
        }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-MishAdb {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 60
    )
    Invoke-MishProcess -FilePath $AdbPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Stop-MishProductProcessForInstrumentation {
    param(
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 10,
        [ValidateRange(50, 2000)][int] $PollMilliseconds = 100
    )

    $forceStop = Invoke-MishAdb -Arguments @('shell', 'am', 'force-stop', $PackageName) -TimeoutSeconds 20
    if ($forceStop.ExitCode -ne 0) {
        Stop-MishRecovery 'LAB_INSTRUMENTATION_HANDOFF_FORCE_STOP_FAILED' 'Baseline PRODUCT process could not be stopped before instrumentation.'
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $processId = Invoke-MishAdb -Arguments @('shell', 'pidof', $PackageName) -TimeoutSeconds 10
        if ([string]::IsNullOrWhiteSpace($processId.StdOut)) {
            return [ordered]@{
                force_stop_succeeded = $true
                previous_process_absent = $true
                elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
            }
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    Stop-MishRecovery 'LAB_INSTRUMENTATION_HANDOFF_PROCESS_STILL_ALIVE' 'Baseline PRODUCT process remained alive after bounded force-stop before instrumentation.'
}
function Get-MishSha256 {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-MishRecovery 'LAB_ARTIFACT_MISSING' 'Required exact-candidate artifact file is missing.'
    }
    (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-MishJson {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-MishRecovery 'LAB_ARTIFACT_MISSING' 'Required JSON evidence is missing.'
    }
    try { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json }
    catch { Stop-MishRecovery 'LAB_ARTIFACT_INVALID' 'Required JSON evidence is invalid.' }
}

function Read-MishSnapshot {
    $result = Invoke-MishAdb -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    ) -TimeoutSeconds 15
    if ($result.ExitCode -ne 0) { return $null }

    $match = [regex]::Match($result.StdOut, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { return $null }

    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    }
    catch { return $null }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-MishDnsLifetimeObservation {
    param([AllowNull()][Parameter(Mandatory)] $Snapshot)

    if (
        $null -eq $Snapshot -or
        -not [bool]$Snapshot.consistent -or
        $null -eq $Snapshot.cellular -or
        $null -eq $Snapshot.cellular.dns -or
        -not [bool]$Snapshot.cellular.dns.available
    ) {
        return $null
    }

    $dns = $Snapshot.cellular.dns
    return [ordered]@{
        pid = [int]$Snapshot.pid
        captured_elapsed_ms = [int64]$Snapshot.captured_elapsed_ms
        slow_threshold_ms = [int64]$dns.slow_threshold_ms
        started = [int64]$dns.started
        completed = [int64]$dns.completed
        active = [int64]$dns.active
        peak_active = [int64]$dns.peak_active
        slow_completions = [int64]$dns.slow_completions
        resolver_failed = [int64]$dns.resolver_failed
        discarded_after_deadline = [int64]$dns.discarded_after_deadline
        completed_after_owner_change = [int64]$dns.completed_after_owner_change
        discarded_stale = [int64]$dns.discarded_stale
        authority_validation_failed = [int64]$dns.authority_validation_failed
        unusable_result = [int64]$dns.unusable_result
        accepted_current = [int64]$dns.accepted_current
        max_native_elapsed_ms = [int64]$dns.max_native_elapsed_ms
        last_started_owner_sequence = $dns.last_started_owner_sequence
        last_completed_start_owner_sequence = $dns.last_completed_start_owner_sequence
        last_completed_current_owner_sequence = $dns.last_completed_current_owner_sequence
    }
}

function Wait-MishDnsLifetimeObservation {
    param(
        [ValidateRange(1, 30)][int] $TimeoutSeconds = 10,
        [ValidateRange(50, 5000)][int] $PollMilliseconds = 250
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $attempts = 0
    do {
        $attempts++
        $snapshot = Read-MishSnapshot
        if ($null -ne $snapshot) {
            $observation = Get-MishDnsLifetimeObservation -Snapshot $snapshot
            if ($null -ne $observation) {
                return [pscustomobject]@{
                    observation = $observation
                    attempts = $attempts
                    elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
                }
            }
        }

        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ($true)

    return [pscustomobject]@{
        observation = $null
        attempts = $attempts
        elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
    }
}

function Get-MishBoundedText {
    param(
        [AllowEmptyString()][string] $Text,
        [ValidateRange(256, 65536)][int] $MaxChars = 32768
    )
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $MaxChars) { return $Text }
    return $Text.Substring(0, $MaxChars) + "`n[TRUNCATED]"
}

function Get-MishE3FailureClassification {
    param(
        [Parameter(Mandatory)][string] $Output,
        [Parameter(Mandatory)][bool] $TestDispatched
    )
    if (-not $TestDispatched) { return 'LAB_TEST_HARNESS_EXECUTION_UNPROVEN' }
    if ($Output -match '(?i)not signed with the same certificate|signatures?.*(?:do not|don''t).*match|INSTRUMENTATION_FAILED.*sign') {
        return 'LAB_TEST_HARNESS_SIGNATURE_MISMATCH'
    }
    if ($Output -match 'root mobile-data transition command failed') { return 'LAB_E3_DEVICE_CONTROL_FAILED' }
    if ($Output -match 'expected direct cellular Internet presence=true validated_required=true') { return 'LAB_E3_DIRECT_CELLULAR_UNAVAILABLE' }
    if ($Output -match 'E3_SAFE_FAILURE stage=(dns_query|public_probe|socket_timeout|http_status|response_parse|public_ip_parse)') { return 'LAB_E3_UPSTREAM_PROBE_FAILED' }
    return 'U2_CELLULAR_E3_FAILED'
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishRecovery 'LAB_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

$classification = 'LAB_RECOVERY_PROBE_NOT_COMPLETED'
$acceptanceResult = 'FAIL'
$testApkSha = ''
$lossEvidence = [ordered]@{
    release_gate = $false
    external_owner_fault_injection = 'NOT_REQUIRED'
    reason = 'NO_SUPPORTED_DETERMINISTIC_UNATTENDED_TRIGGER_ON_DEVICE_1'
}
$cellularEvidence = [ordered]@{}
$dnsLifetimeEvidence = [ordered]@{
    measurement_status = 'NOT_EVALUATED'
    same_process = $false
    comparison_scope = 'NOT_OBSERVED'
    before_e3 = $null
    after_e3_before_restart = $null
    post_e3_snapshot_attempts = 0
    post_e3_wait_elapsed_ms = 0
}
$restartEvidence = [ordered]@{}
$lifecycleLatencyBudget = [ordered]@{
    measurement_status = 'NOT_OBSERVED'
    threshold_policy = 'NO_NEW_SLA'
    startup = [ordered]@{
        initial_launch_elapsed_ms = $null
        restart_launch_elapsed_ms = $null
    }
    root_reconcile = [ordered]@{
        initial_last_reconcile_elapsed_ms = $null
        initial_last_policy_effect_elapsed_ms = $null
        restart_last_reconcile_elapsed_ms = $null
        restart_last_policy_effect_elapsed_ms = $null
    }
    loss = $null
    recovery = $null
    stop = $null
}
$harnessCleanup = [ordered]@{
    package_id = $script:TestPackage
    attempted = $false
    succeeded = $false
}
$instrumentationHandoff = [ordered]@{
    mode = 'EXPLICIT_FORCE_STOP'
    attempted = $false
    force_stop_succeeded = $false
    previous_process_absent = $false
    elapsed_ms = $null
}

try {
    $candidateRoot = [IO.Path]::GetFullPath($CandidateDirectory)
    $manifestPath = Join-Path $candidateRoot 'candidate.json'
    $candidate = Read-MishJson -Path $manifestPath
    if (
        [string]$candidate.schema -cne $script:CandidateSchema -or
        [string]$candidate.source_sha -cne $ExpectedSourceSha -or
        [string]$candidate.application_id -cne $PackageName -or
        [string]$candidate.target_abi -cne 'armeabi-v7a'
    ) {
        Stop-MishRecovery 'LAB_CANDIDATE_MANIFEST_INVALID' 'Exact candidate manifest identity does not match the requested PRODUCT.'
    }

    $testApkPath = Join-Path $candidateRoot ([string]$candidate.android_test_apk.name)
    $testApkSha = Get-MishSha256 -Path $testApkPath
    if ($testApkSha -cne [string]$candidate.android_test_apk.sha256) {
        Stop-MishRecovery 'LAB_TEST_APK_DIGEST_MISMATCH' 'Exact candidate androidTest APK digest mismatch.'
    }

    $initialLaunch = Read-MishJson -Path $InitialLaunchReceiptPath
    if ([string]$initialLaunch.result -cne 'PASS') {
        Stop-MishRecovery 'LAB_INITIAL_LAUNCH_RECEIPT_INVALID' 'Recovery probe requires a PASS canonical initial launch receipt.'
    }

    $preSnapshot = Read-MishSnapshot
    if (
        $null -eq $preSnapshot -or
        -not [bool]$preSnapshot.consistent -or
        -not [bool]$preSnapshot.cellular.admitted -or
        -not [bool]$preSnapshot.mesh.admitted -or
        -not [bool]$preSnapshot.mesh.epoch_present -or
        -not [bool]$preSnapshot.mesh.ingress_running -or
        [string]$preSnapshot.readiness.state -cne 'READY'
    ) {
        Stop-MishRecovery 'LAB_RECOVERY_PRECONDITION_NOT_READY' 'Baseline owner/network facts are not ready for recovery/lifecycle acceptance.'
    }

    $lifecycleLatencyBudget.startup.initial_launch_elapsed_ms = [int64]$initialLaunch.elapsed_ms
    $lifecycleLatencyBudget.root_reconcile.initial_last_reconcile_elapsed_ms =
        [int64]$preSnapshot.root.reconcile.last_reconcile_elapsed_ms
    $lifecycleLatencyBudget.root_reconcile.initial_last_policy_effect_elapsed_ms =
        [int64]$preSnapshot.root.reconcile.last_policy_effect_elapsed_ms

    $preDnsObservation = Get-MishDnsLifetimeObservation -Snapshot $preSnapshot
    if ($null -eq $preDnsObservation) {
        Stop-MishRecovery 'LAB_DNS_LIFETIME_BASELINE_INVALID' 'Baseline canonical snapshot omitted a consistent native DNS observation.'
    }
    $dnsLifetimeEvidence.before_e3 = $preDnsObservation

    $testPackagePath = Invoke-MishAdb -Arguments @('shell', 'pm', 'path', $script:TestPackage) -TimeoutSeconds 20
    $pathRows = @($testPackagePath.StdOut -split "`r?`n" | Where-Object { $_ -match '^package:.+/base\.apk$' })
    if ($testPackagePath.ExitCode -ne 0 -or $pathRows.Count -ne 1) {
        Stop-MishRecovery 'LAB_TEST_APK_INSTALL_IDENTITY_MISSING' 'Preinstalled LAB-signed androidTest package path could not be resolved uniquely.'
    }

    # Android instrumentation may replace the PRODUCT process. Make that boundary explicit:
    # stop the baseline process first, prove its PID is absent, then start the exact androidTest.
    # This prevents two process generations from reconciling/cleaning the same PRODUCT-owned
    # kernel policy concurrently. No root-policy object is mutated by LAB here.
    $instrumentationHandoff.attempted = $true
    $handoff = Stop-MishProductProcessForInstrumentation
    $instrumentationHandoff.force_stop_succeeded = [bool]$handoff.force_stop_succeeded
    $instrumentationHandoff.previous_process_absent = [bool]$handoff.previous_process_absent
    $instrumentationHandoff.elapsed_ms = [int64]$handoff.elapsed_ms

    $instrumentation = Invoke-MishAdb -Arguments @(
        'shell', 'am', 'instrument', '-w', '-r',
        '-e', 'class', $script:TestClass,
        '-e', 'e3Mode', 'lifecycle',
        $script:TestComponent
    ) -TimeoutSeconds 300

    $instrumentationOutput = (($instrumentation.StdOut, $instrumentation.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"
    $testDispatched = $instrumentationOutput -match "(?im)^INSTRUMENTATION_STATUS:\s*test=$([regex]::Escape($script:TestMethod))\s*$"
    $instrumentationPass = $instrumentation.ExitCode -eq 0 -and $testDispatched -and $instrumentationOutput -match '(?m)^OK \(1 test\)\s*$'
    $positive = $instrumentationOutput -match '(?m)^INSTRUMENTATION_STATUS:\s*e3_evidence=phase=positive '
    $negative = $instrumentationOutput -match '(?m)^INSTRUMENTATION_STATUS:\s*e3_evidence=phase=negative '
    $recovery = $instrumentationOutput -match '(?m)^INSTRUMENTATION_STATUS:\s*e3_evidence=phase=recovery '

    $latencyPattern =
        '(?m)^INSTRUMENTATION_STATUS:\s*e3_evidence=phase=latency ' +
        'loss_owner_elapsed_ms=(?<lossOwner>\d+) ' +
        'loss_fail_closed_elapsed_ms=(?<lossFailClosed>\d+) ' +
        'recovery_owner_elapsed_ms=(?<recoveryOwner>\d+) ' +
        'recovery_functional_elapsed_ms=(?<recoveryFunctional>\d+) ' +
        'proxy_close_elapsed_ms=(?<proxyClose>\d+) ' +
        'cellular_close_elapsed_ms=(?<cellularClose>\d+) ' +
        'cleanup_verify_elapsed_ms=(?<cleanupVerify>\d+) ' +
        'stop_total_elapsed_ms=(?<stopTotal>\d+)\s*$'
    $latencyMatch = [regex]::Match($instrumentationOutput, $latencyPattern)
    if ($latencyMatch.Success) {
        $lifecycleLatencyBudget.measurement_status = 'E3_OBSERVED'
        $lifecycleLatencyBudget.loss = [ordered]@{
            owner_not_admitted_elapsed_ms = [int64]$latencyMatch.Groups['lossOwner'].Value
            full_fail_closed_elapsed_ms = [int64]$latencyMatch.Groups['lossFailClosed'].Value
        }
        $lifecycleLatencyBudget.recovery = [ordered]@{
            owner_ready_elapsed_ms = [int64]$latencyMatch.Groups['recoveryOwner'].Value
            functional_ready_elapsed_ms = [int64]$latencyMatch.Groups['recoveryFunctional'].Value
        }
        $lifecycleLatencyBudget.stop = [ordered]@{
            proxy_close_elapsed_ms = [int64]$latencyMatch.Groups['proxyClose'].Value
            cellular_close_elapsed_ms = [int64]$latencyMatch.Groups['cellularClose'].Value
            cleanup_verify_elapsed_ms = [int64]$latencyMatch.Groups['cleanupVerify'].Value
            total_elapsed_ms = [int64]$latencyMatch.Groups['stopTotal'].Value
        }
    }

    $cellularEvidence = [ordered]@{
        exact_test_apk_sha256 = $testApkSha
        exact_test_apk_digest_verified = $true
        preinstalled_lab_signed_harness = $true
        test_package_id = $script:TestPackage
        installed_package_path_verified = $true
        instrumentation_exit_code = [int]$instrumentation.ExitCode
        instrumentation_test_dispatched = $testDispatched
        instrumentation_pass = $instrumentationPass
        instrumentation_stderr_present = -not [string]::IsNullOrWhiteSpace($instrumentation.StdErr)
        instrumentation_output = Get-MishBoundedText -Text $instrumentationOutput
        positive_phase = $positive
        negative_phase = $negative
        recovery_phase = $recovery
        established_flow_blocked = $instrumentationOutput -match 'established_flow_blocked=true'
        dns_blocked = $instrumentationOutput -match 'dns_blocked=true'
        public_socket_blocked = $instrumentationOutput -match 'public_socket_blocked=true'
        no_default_fallback = $instrumentationOutput -match 'no_default_fallback=true'
        fresh_generation = $instrumentationOutput -match 'fresh_generation=true'
        cleanup_verified = $instrumentationOutput -match 'cleanup_verified=true'
    }

    if (-not $instrumentationPass -or -not $positive -or -not $negative -or -not $recovery) {
        Stop-MishRecovery (Get-MishE3FailureClassification -Output $instrumentationOutput -TestDispatched $testDispatched) 'Exact-head Cellular E3 lifecycle instrumentation failed.'
    }

    foreach ($required in @('established_flow_blocked','dns_blocked','public_socket_blocked','no_default_fallback','fresh_generation','cleanup_verified')) {
        if (-not [bool]$cellularEvidence[$required]) {
            Stop-MishRecovery 'U2_CELLULAR_E3_EVIDENCE_INCOMPLETE' "Cellular E3 PASS output omitted required $required evidence."
        }
    }

    # Capture the first coherent process-wide DNS observation available after E3 and before the
    # explicit force-stop/start below. Android instrumentation can replace the PRODUCT process, so
    # PID continuity is evidence, not a recovery acceptance gate. Counters from different PIDs must
    # never be compared as one process-wide lifetime series.
    $postE3Read = Wait-MishDnsLifetimeObservation
    $dnsLifetimeEvidence.post_e3_snapshot_attempts = [int]$postE3Read.attempts
    $dnsLifetimeEvidence.post_e3_wait_elapsed_ms = [int64]$postE3Read.elapsed_ms
    if ($null -eq $postE3Read.observation) {
        # E3/recovery acceptance is owned by the exact PRODUCT instrumentation and the canonical
        # post-restart diagnostic below. A post-instrumentation DNS snapshot is optional U3
        # measurement evidence: absence here must never manufacture either DNS PASS or recovery
        # failure. Keep the measurement explicitly NOT_EVALUATED and continue to the real restart
        # acceptance boundary.
        $dnsLifetimeEvidence.measurement_status = 'POST_INSTRUMENTATION_UNAVAILABLE'
    } else {
        $dnsLifetimeEvidence.after_e3_before_restart = $postE3Read.observation
        $dnsLifetimeEvidence.measurement_status = 'OBSERVED'
        $dnsLifetimeEvidence.same_process =
            [int]$postE3Read.observation.pid -eq [int]$preDnsObservation.pid
        $dnsLifetimeEvidence.comparison_scope = if ([bool]$dnsLifetimeEvidence.same_process) {
            'SAME_PROCESS'
        } else {
            'PROCESS_BOUNDARY'
        }
    }

    & (Join-Path $PSScriptRoot 'start-device-app.ps1') `
        -AdbPath $AdbPath `
        -PackageName $PackageName `
        -ComponentName $ComponentName `
        -ReceiptPath $PostRestartReceiptPath | Out-Host

    $postStart = Read-MishJson -Path $PostRestartReceiptPath
    if ([string]$postStart.result -cne 'PASS') {
        Stop-MishRecovery 'U2_RESTART_LAUNCH_FAILED' 'Canonical post-E3 PRODUCT restart did not stabilize.'
    }

    & (Join-Path $PSScriptRoot 'collect-device-diagnostic.ps1') `
        -AdbPath $AdbPath `
        -PackageName $PackageName `
        -EvidencePath $PostRestartDiagnosticPath | Out-Host

    $postDiagnostic = Read-MishJson -Path $PostRestartDiagnosticPath
    $postClass = [string]$postDiagnostic.classification
    $externalMeshBlocked = $postClass -ceq 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED'
    if ($postClass -cne 'PASS' -and -not $externalMeshBlocked) {
        if ($postClass -like 'LAB_*') {
            Stop-MishRecovery $postClass 'Post-restart canonical diagnostic failed in LAB.'
        }
        Stop-MishRecovery 'U2_RESTART_DIAGNOSTIC_FAILED' "Post-restart canonical diagnostic was not PASS: $postClass"
    }

    if ([int64]$postDiagnostic.android.mesh.active_sessions -ne 0 -or [int]$postDiagnostic.android.proxy.active_sessions -ne 0) {
        Stop-MishRecovery 'U2_RESTART_ACTIVE_SESSION_LEAK' 'Post-restart owner snapshot retained active sessions before diagnostic probes.'
    }

    $restartEvidence = [ordered]@{
        canonical_force_stop_start = $true
        initial_pid = [int]$initialLaunch.pid
        final_pid = [int]$postStart.pid
        final_pid_stable = [bool]$postStart.pid_stable
        launch_elapsed_ms = [int64]$postStart.elapsed_ms
        diagnostic_classification = $postClass
        external_mesh_acceptance_blocked = $externalMeshBlocked
        root_policy_authorized = [bool]$postDiagnostic.android.root.policy_authorized
        root_authority_observation = [string]$postDiagnostic.android.root.authority_observation
        proxy_healthy = [bool]$postDiagnostic.android.proxy.healthy
        mesh_admitted = [bool]$postDiagnostic.android.mesh.admitted
        mesh_epoch_present = [bool]$postDiagnostic.android.mesh.epoch_present
        mesh_ingress_running = [bool]$postDiagnostic.android.mesh.ingress_running
        owner_sessions_before_external_diagnostic_probes = [ordered]@{
            mesh = [int64]$postDiagnostic.android.mesh.active_sessions
            proxy = [int]$postDiagnostic.android.proxy.active_sessions
        }
        loopback_e2e = [string]$postDiagnostic.external.adb_loopback_proxy_e2e.result
        mesh_e2e = [string]$postDiagnostic.external.mesh_proxy_e2e.result
    }

    $lifecycleLatencyBudget.startup.restart_launch_elapsed_ms = [int64]$postStart.elapsed_ms
    $lifecycleLatencyBudget.root_reconcile.restart_last_reconcile_elapsed_ms =
        [int64]$postDiagnostic.android.root.reconcile.last_reconcile_elapsed_ms
    $lifecycleLatencyBudget.root_reconcile.restart_last_policy_effect_elapsed_ms =
        [int64]$postDiagnostic.android.root.reconcile.last_policy_effect_elapsed_ms
    if ([string]$lifecycleLatencyBudget.measurement_status -ceq 'E3_OBSERVED') {
        $lifecycleLatencyBudget.measurement_status = 'COMPLETE'
    }

    $externalMeshSatisfied = $externalMeshBlocked -or [string]$restartEvidence.mesh_e2e -ceq 'PASS'
    if (
        -not [bool]$restartEvidence.root_policy_authorized -or
        [string]$restartEvidence.root_authority_observation -cne 'READY_AT_POLICY_AUTHORIZATION' -or
        -not [bool]$restartEvidence.proxy_healthy -or
        -not [bool]$restartEvidence.mesh_admitted -or
        -not [bool]$restartEvidence.mesh_epoch_present -or
        -not [bool]$restartEvidence.mesh_ingress_running -or
        [string]$restartEvidence.loopback_e2e -cne 'PASS' -or
        -not $externalMeshSatisfied
    ) {
        Stop-MishRecovery 'U2_RESTART_RECOVERY_INCOMPLETE' 'Canonical post-restart owner/readiness/E2E evidence is incomplete.'
    }

    if ($externalMeshBlocked) {
        Stop-MishRecovery 'LAB_EXTERNAL_MESH_ACCEPTANCE_BLOCKED' 'Cellular E3 and PRODUCT restart passed, but external Mesh E2E is blocked by the Windows LAB sandbox.'
    }

    $classification = 'U2_RECOVERY_LIFECYCLE_PASS'
    $acceptanceResult = 'PASS'
}
catch {
    $message = $_.Exception.Message
    if ($message -match '^MISH_RECOVERY_FAILURE\|(?<classification>[A-Z0-9_]+)\|') {
        $classification = $Matches['classification']
    }
    else {
        $classification = 'LAB_RECOVERY_PROBE_UNEXPECTED_FAILURE'
    }
}
finally {
    try {
        $installedHarness = Invoke-MishAdb -Arguments @('shell', 'pm', 'path', $script:TestPackage) -TimeoutSeconds 20
        $harnessPresent = $installedHarness.ExitCode -eq 0 -and $installedHarness.StdOut -match '(?m)^package:'
        if ($harnessPresent) {
            $harnessCleanup.attempted = $true
            $cleanup = Invoke-MishAdb -Arguments @('uninstall', $script:TestPackage) -TimeoutSeconds 30
            $harnessCleanup.succeeded = $cleanup.ExitCode -eq 0 -and $cleanup.StdOut -match '(?m)^Success\s*$'
        }
        else {
            $harnessCleanup.succeeded = $true
        }
    }
    catch {
        $harnessCleanup.attempted = $true
        $harnessCleanup.succeeded = $false
    }

    if ($acceptanceResult -ceq 'PASS' -and -not [bool]$harnessCleanup.succeeded) {
        $acceptanceResult = 'FAIL'
        $classification = 'LAB_TEST_HARNESS_CLEANUP_FAILED'
    }

    $evidence = [ordered]@{
        schema = $script:Schema
        collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        source_sha = $ExpectedSourceSha
        application_id = $PackageName
        acceptance_result = $acceptanceResult
        classification = $classification
        mesh_vpn_loss_recovery = $lossEvidence
        cellular_e3 = $cellularEvidence
        dns_lifetime = $dnsLifetimeEvidence
        lifecycle_latency_budget = $lifecycleLatencyBudget
        restart = $restartEvidence
        instrumentation_handoff = $instrumentationHandoff
        test_harness = $harnessCleanup
        lab_effects = [ordered]@{
            external_mesh_owner_fault_injection = 'NOT_PERFORMED'
            cellular_loss = 'exact-head CellularE3InstrumentedTest uses cmd phone data disable/enable'
            cloudflare_app_mutated = $false
            product_routes_or_iptables_mutated_by_lab = $false
        }
    }

    $fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $fullEvidencePath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullEvidencePath,
        (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

Write-Host "MISH_RECOVERY_LIFECYCLE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_RECOVERY_LIFECYCLE_CLASSIFICATION=$classification"
Write-Host "MISH_RECOVERY_LIFECYCLE_EVIDENCE=$([IO.Path]::GetFullPath($EvidencePath))"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_RECOVERY_RESULT|$acceptanceResult|$classification"
}
