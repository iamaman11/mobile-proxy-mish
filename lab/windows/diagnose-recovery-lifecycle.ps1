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
$script:DnsObservationPollMs = 100
$script:DnsStimulusMaxAttempts = 32
$script:DnsStimulusMaxConcurrency = 4
$script:DnsStimulusRequestTimeoutSeconds = 5
$script:DnsStimulusUrl = 'https://example.com/'

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

function Start-MishDnsStimulusRequest {
    param(
        [Parameter(Mandatory)][int] $Ordinal,
        [Parameter(Mandatory)][int] $ProxyPort,
        [Parameter(Mandatory)] $Lease
    )

    $proxy = [Net.WebProxy]::new("http://127.0.0.1:$ProxyPort")
    $proxy.Credentials = [Net.NetworkCredential]::new(
        [string]$Lease.ProxyUserName,
        [Security.SecureString]$Lease.ProxyPassword
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $true
    $handler.Proxy = $proxy
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($script:DnsStimulusRequestTimeoutSeconds)
    $separator = if ($script:DnsStimulusUrl.Contains('?')) { '&' } else { '?' }
    $url = "$($script:DnsStimulusUrl)$($separator)mish_dns_lifetime=$Ordinal"
    return [pscustomobject]@{
        Ordinal = $Ordinal
        Client = $client
        Handler = $handler
        Task = $client.GetAsync($url)
    }
}

function Complete-MishDnsStimulusRequest {
    param([Parameter(Mandatory)] $Entry)

    if (-not [bool]$Entry.Task.IsCompleted) { return $null }

    $result = 'FAIL'
    $reason = 'TRANSPORT_FAILED'
    $response = $null
    try {
        $response = $Entry.Task.GetAwaiter().GetResult()
        $result = if ($response.IsSuccessStatusCode) { 'PASS' } else { 'FAIL' }
        $reason = if ($response.IsSuccessStatusCode) { 'NONE' } else { "HTTP_$([int]$response.StatusCode)" }
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        $reason = 'TIMEOUT'
    }
    catch {
        $reason = $_.Exception.GetType().FullName
    }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        $Entry.Client.Dispose()
        $Entry.Handler.Dispose()
    }

    return [ordered]@{
        ordinal = [int]$Entry.Ordinal
        result = $result
        reason = $reason
    }
}

function Invoke-MishE3WithDnsLifetimeObservation {
    param(
        [Parameter(Mandatory)][string[]] $InstrumentationArguments,
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 300
    )

    Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $AdbPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $InstrumentationArguments) { [void]$start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Stop-MishRecovery 'LAB_PROCESS_START_FAILED' 'Cellular E3 instrumentation process could not be started.'
    }

    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $observations = [Collections.Generic.List[object]]::new()
    $activeRequests = [Collections.Generic.List[object]]::new()
    $requestResults = [Collections.Generic.List[object]]::new()
    $credentialStorePath = $null
    $lease = $null
    $forwardPort = $null
    $stimulusStarted = 0
    $observationPid = $null

    try {
        while (-not $process.HasExited) {
            if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                try { $process.Kill($true) } catch { }
                Stop-MishRecovery 'LAB_PROCESS_TIMEOUT' 'Cellular E3 instrumentation exceeded its bounded timeout.'
            }

            $snapshot = Read-MishSnapshot
            $observation = Get-MishDnsLifetimeObservation -Snapshot $snapshot
            if ($null -ne $observation) {
                if ($null -eq $observationPid) {
                    $observationPid = [int]$observation.pid
                }
                elseif ([int]$observation.pid -ne [int]$observationPid) {
                    Stop-MishRecovery 'LAB_DNS_LIFETIME_PROCESS_CHANGED' 'Canonical DNS observation changed PRODUCT PID while E3 instrumentation was active.'
                }
                if ($observations.Count -lt 128) {
                    [void]$observations.Add($observation)
                }

                if (
                    $null -eq $lease -and
                    $null -ne $snapshot.proxy -and
                    [string]$snapshot.proxy.state -ceq 'RUNNING' -and
                    $null -ne $snapshot.credential -and
                    [bool]$snapshot.credential.active
                ) {
                    $tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
                    if (-not [string]::IsNullOrWhiteSpace($tempRoot)) {
                        $credentialStorePath = Join-Path ([IO.Path]::GetFullPath($tempRoot)) ('mish-dns-lifetime-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
                        try {
                            [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
                            $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
                            $forward = Invoke-MishAdb -Arguments @('forward', 'tcp:0', 'tcp:3128') -TimeoutSeconds 15
                            $forwardText = $forward.StdOut.Trim()
                            if ($forward.ExitCode -eq 0 -and $forwardText -match '^\d+
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
    before_instrumentation = $null
    during_instrumentation = $null
}
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

    $preDnsObservation = Get-MishDnsLifetimeObservation -Snapshot $preSnapshot
    if ($null -eq $preDnsObservation) {
        Stop-MishRecovery 'LAB_DNS_LIFETIME_BASELINE_INVALID' 'Baseline canonical snapshot omitted a consistent native DNS observation.'
    }
    $dnsLifetimeEvidence.before_instrumentation = $preDnsObservation

    $testPackagePath = Invoke-MishAdb -Arguments @('shell', 'pm', 'path', $script:TestPackage) -TimeoutSeconds 20
    $pathRows = @($testPackagePath.StdOut -split "`r?`n" | Where-Object { $_ -match '^package:.+/base\.apk$' })
    if ($testPackagePath.ExitCode -ne 0 -or $pathRows.Count -ne 1) {
        Stop-MishRecovery 'LAB_TEST_APK_INSTALL_IDENTITY_MISSING' 'Preinstalled LAB-signed androidTest package path could not be resolved uniquely.'
    }

    $instrumentation = Invoke-MishE3WithDnsLifetimeObservation -InstrumentationArguments @(
        'shell', 'am', 'instrument', '-w', '-r',
        '-e', 'class', $script:TestClass,
        '-e', 'e3Mode', 'lifecycle',
        $script:TestComponent
    ) -TimeoutSeconds 300
    $dnsLifetimeEvidence.during_instrumentation = $instrumentation.DnsLifetime

    $instrumentationOutput = (($instrumentation.StdOut, $instrumentation.StdErr) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"
    $testDispatched = $instrumentationOutput -match "(?im)^INSTRUMENTATION_STATUS:\s*test=$([regex]::Escape($script:TestMethod))\s*$"
    $instrumentationPass = $instrumentation.ExitCode -eq 0 -and $testDispatched -and $instrumentationOutput -match '(?m)^OK \(1 test\)\s*$'
    $positive = $instrumentationOutput -match '(?m)^INSTRUMENTATION_STATUS:\s*e3_evidence=phase=positive '
    $negative = $instrumentationOutput -match '(?m)^INSTRUMENTATION_STATUS:\s*e3_evidence=phase=negative '
    $recovery = $instrumentationOutput -match '(?m)^INSTRUMENTATION_STATUS:\s*e3_evidence=phase=recovery '

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

    if (
        $null -eq $instrumentation.DnsLifetime -or
        [int]$instrumentation.DnsLifetime.sample_count -lt 1
    ) {
        Stop-MishRecovery 'LAB_DNS_LIFETIME_INSTRUMENTATION_UNOBSERVED' 'No consistent canonical DNS snapshot was observed while E3 instrumentation was active.'
    }
    if (
        [int]$instrumentation.DnsLifetime.stimulus.started -lt 1 -or
        [int64]$instrumentation.DnsLifetime.started_delta -lt 1
    ) {
        Stop-MishRecovery 'LAB_DNS_LIFETIME_TARGET_NOT_EXERCISED' 'The live proxy-domain stimulus did not exercise the native DNS path while E3 instrumentation was active.'
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
        dns_lifetime = $dnsLifetimeEvidence
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
) {
                                $forwardPort = [int]$forwardText
                            }
                            else {
                                $lease = $null
                            }
                        }
                        catch {
                            $lease = $null
                        }
                    }
                }
            }

            for ($index = $activeRequests.Count - 1; $index -ge 0; $index--) {
                $completed = Complete-MishDnsStimulusRequest -Entry $activeRequests[$index]
                if ($null -ne $completed) {
                    [void]$requestResults.Add($completed)
                    $activeRequests.RemoveAt($index)
                }
            }

            while (
                $null -ne $lease -and
                $null -ne $forwardPort -and
                $stimulusStarted -lt $script:DnsStimulusMaxAttempts -and
                $activeRequests.Count -lt $script:DnsStimulusMaxConcurrency
            ) {
                $stimulusStarted++
                [void]$activeRequests.Add(
                    (Start-MishDnsStimulusRequest -Ordinal $stimulusStarted -ProxyPort $forwardPort -Lease $lease)
                )
            }

            Start-Sleep -Milliseconds $script:DnsObservationPollMs
        }

        $process.WaitForExit()
        foreach ($entry in @($activeRequests)) {
            $completed = Complete-MishDnsStimulusRequest -Entry $entry
            if ($null -ne $completed) { [void]$requestResults.Add($completed) }
        }

        $first = if ($observations.Count -gt 0) { $observations[0] } else { $null }
        $last = if ($observations.Count -gt 0) { $observations[$observations.Count - 1] } else { $null }
        $maxObservedActive = if ($observations.Count -gt 0) {
            [int64](($observations | Measure-Object -Property active -Maximum).Maximum)
        } else { 0 }
        $startedDelta = if ($null -ne $first -and $null -ne $last) {
            [int64]$last.started - [int64]$first.started
        } else { 0 }

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
            DnsLifetime = [ordered]@{
                observation_pid = $observationPid
                sample_count = $observations.Count
                first = $first
                last = $last
                max_observed_active = $maxObservedActive
                started_delta = $startedDelta
                completed_delta = if ($null -ne $first -and $null -ne $last) { [int64]$last.completed - [int64]$first.completed } else { 0 }
                completed_after_owner_change_delta = if ($null -ne $first -and $null -ne $last) { [int64]$last.completed_after_owner_change - [int64]$first.completed_after_owner_change } else { 0 }
                discarded_after_deadline_delta = if ($null -ne $first -and $null -ne $last) { [int64]$last.discarded_after_deadline - [int64]$first.discarded_after_deadline } else { 0 }
                discarded_stale_delta = if ($null -ne $first -and $null -ne $last) { [int64]$last.discarded_stale - [int64]$first.discarded_stale } else { 0 }
                stimulus = [ordered]@{
                    requested_max = $script:DnsStimulusMaxAttempts
                    started = $stimulusStarted
                    completed = $requestResults.Count
                    pass = @($requestResults | Where-Object { [string]$_.result -ceq 'PASS' }).Count
                    failed = @($requestResults | Where-Object { [string]$_.result -cne 'PASS' }).Count
                }
            }
        }
    }
    finally {
        $watch.Stop()
        foreach ($entry in @($activeRequests)) {
            try { $entry.Client.Dispose() } catch { }
            try { $entry.Handler.Dispose() } catch { }
        }
        if ($null -ne $forwardPort) {
            try { [void](Invoke-MishAdb -Arguments @('forward', '--remove', "tcp:$forwardPort") -TimeoutSeconds 15) } catch { }
        }
        $lease = $null
        if ($null -ne $credentialStorePath -and (Test-Path -LiteralPath $credentialStorePath -PathType Leaf)) {
            Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
        }
        if (-not $process.HasExited) {
            try { $process.Kill($true) } catch { }
        }
        $process.Dispose()
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
    same_process = $false
    before_e3 = $null
    after_e3_before_restart = $null
}
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

    # Capture the process-wide native DNS facts before the explicit force-stop/start below.
    # Restart creates a fresh process and would erase the very old-generation occupancy facts U3
    # needs to observe. This is read-only evidence; no DNS result is accepted/rejected here.
    $postE3Snapshot = Read-MishSnapshot
    $postE3DnsObservation = Get-MishDnsLifetimeObservation -Snapshot $postE3Snapshot
    if ($null -eq $postE3DnsObservation) {
        Stop-MishRecovery 'LAB_DNS_LIFETIME_POST_E3_INVALID' 'Post-E3 canonical snapshot omitted a consistent native DNS observation.'
    }
    if ([int]$postE3DnsObservation.pid -ne [int]$preDnsObservation.pid) {
        Stop-MishRecovery 'LAB_DNS_LIFETIME_PROCESS_CHANGED' 'Native DNS lifetime observation crossed a PRODUCT process boundary before the explicit restart.'
    }
    $dnsLifetimeEvidence.same_process = $true
    $dnsLifetimeEvidence.after_e3_before_restart = $postE3DnsObservation

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
        dns_lifetime = $dnsLifetimeEvidence
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
