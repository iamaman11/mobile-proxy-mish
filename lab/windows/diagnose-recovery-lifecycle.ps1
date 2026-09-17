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
$restartEvidence = [ordered]@{}
$harnessCleanup = [ordered]@{
    package_id = $script:TestPackage
    attempted = $false
    succeeded = $false
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

    $testPackagePath = Invoke-MishAdb -Arguments @('shell', 'pm', 'path', $script:TestPackage) -TimeoutSeconds 20
    $pathRows = @($testPackagePath.StdOut -split "`r?`n" | Where-Object { $_ -match '^package:.+/base\.apk$' })
    if ($testPackagePath.ExitCode -ne 0 -or $pathRows.Count -ne 1) {
        Stop-MishRecovery 'LAB_TEST_APK_INSTALL_IDENTITY_MISSING' 'Preinstalled LAB-signed androidTest package path could not be resolved uniquely.'
    }

    $instrumentation = Invoke-MishAdb -Arguments @(
        'shell', 'am', 'instrument', '-w', '-r',
        '-e', 'class', $script:TestClass,
        '-e', 'e3Mode', 'lifecycle',
        $script:TestComponent
    ) -TimeoutSeconds 300

    $instrumentationOutput = (($instrumentation.StdOut, $instrumentation.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"
    $testDispatched = $instrumentationOutput -match "(?im)^INSTRUMENTATION_STATUS:\s*test=$([regex]::Escape($script:TestMethod))\s*$"
    $instrumentationPass = $instrumentation.ExitCode -eq 0 -and $testDispatched -and $instrumentationOutput -match '(?m)^OK \(1 test\)\s*$'
    $positive = $instrumentationOutput -match 'E3_EVIDENCE phase=positive '
    $negative = $instrumentationOutput -match 'E3_EVIDENCE phase=negative '
    $recovery = $instrumentationOutput -match 'E3_EVIDENCE phase=recovery '

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
        restart = $restartEvidence
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
