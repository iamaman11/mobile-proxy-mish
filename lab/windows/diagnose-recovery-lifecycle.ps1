[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CandidateDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedSourceSha,
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $ComponentName = 'com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity',
    [string] $MeshCidr = '100.96.0.0/12',
    [string] $TargetHost = 'example.com',
    [ValidateRange(1, 65535)][int] $TargetPort = 443,
    [Parameter(Mandatory)][string] $InitialLaunchReceiptPath,
    [Parameter(Mandatory)][string] $PostRestartReceiptPath,
    [Parameter(Mandatory)][string] $PostRestartDiagnosticPath,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-recovery-lifecycle-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.recovery-lifecycle/v1'
$script:CandidateSchema = 'mish-device-candidate-v1'
$script:TestPackage = 'com.mobileproxymish.app.test'
$script:TestClass = 'com.mobileproxymish.app.cellular.CellularE3InstrumentedTest'
$script:TestComponent = 'com.mobileproxymish.app.test/androidx.test.runner.AndroidJUnitRunner'
$script:SnapshotMethod = 'snapshot_v2'
$script:IoTimeoutMs = 5000
$script:PollMs = 500

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
    finally { if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Test-MishIpv4InCidr {
    param(
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Cidr
    )
    try {
        $parts = $Cidr.Split('/')
        if ($parts.Count -ne 2) { return $false }
        $addressBytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
        $networkBytes = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $prefix = [int]$parts[1]
        if ($addressBytes.Length -ne 4 -or $networkBytes.Length -ne 4 -or $prefix -lt 0 -or $prefix -gt 32) { return $false }
        for ($index = 0; $index -lt 4; $index++) {
            $remaining = $prefix - ($index * 8)
            $bits = [Math]::Min(8, [Math]::Max(0, $remaining))
            if ($bits -eq 0) { continue }
            $mask = (0xff -shl (8 - $bits)) -band 0xff
            if ((([int]$addressBytes[$index]) -band $mask) -ne (([int]$networkBytes[$index]) -band $mask)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-MishMeshAddresses {
    $result = Invoke-MishAdb -Arguments @('shell', 'ip', '-o', '-4', 'addr', 'show') -TimeoutSeconds 15
    if ($result.ExitCode -ne 0) { return @() }
    @(
        [regex]::Matches($result.StdOut, '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/\d+') |
            ForEach-Object { $_.Groups['ip'].Value } |
            Where-Object { Test-MishIpv4InCidr -Address $_ -Cidr $MeshCidr } |
            Sort-Object -Unique
    )
}

function Wait-MishCondition {
    param(
        [Parameter(Mandatory)][scriptblock] $Condition,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $value = & $Condition
        if ($null -ne $value) { return $value }
        Start-Sleep -Milliseconds $script:PollMs
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    return $null
}

function Read-MishAsciiLine {
    param([Parameter(Mandatory)][IO.Stream] $Stream)
    $bytes = [Collections.Generic.List[byte]]::new()
    while ($bytes.Count -lt 16384) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { throw 'Unexpected EOF while reading protocol line.' }
        $bytes.Add([byte]$value)
        if ($bytes.Count -ge 2 -and $bytes[$bytes.Count - 2] -eq 13 -and $bytes[$bytes.Count - 1] -eq 10) {
            return [Text.Encoding]::ASCII.GetString($bytes.ToArray(), 0, $bytes.Count - 2)
        }
    }
    throw 'Protocol line exceeded the bounded length.'
}

function Read-MishHeaders {
    param([Parameter(Mandatory)][IO.Stream] $Stream)
    while ($true) {
        $line = Read-MishAsciiLine -Stream $Stream
        if ($line.Length -eq 0) { return }
    }
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-u2-recovery`r`n`r`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.TlsStream.Write($bytes, 0, $bytes.Length)
        $Session.TlsStream.Flush()
        $status = Read-MishAsciiLine -Stream $Session.TlsStream
        Read-MishHeaders -Stream $Session.TlsStream
        return $status -match '^HTTP/1\.[01]\s+2\d\d\b'
    }
    catch { return $false }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease
    )
    $client = [Net.Sockets.TcpClient]::new()
    $tls = $null
    try {
        $connect = $client.ConnectAsync($ProxyHost, 3128)
        if (-not $connect.Wait($script:IoTimeoutMs) -or -not $client.Connected) { throw 'Mesh proxy connect timeout.' }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:IoTimeoutMs
        $stream.WriteTimeout = $script:IoTimeoutMs

        $password = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::ASCII.GetBytes("$([string]$Lease.ProxyUserName):$password")
        try { $auth = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $connectRequest = "CONNECT ${TargetHost}:${TargetPort} HTTP/1.1`r`nHost: ${TargetHost}:${TargetPort}`r`nProxy-Authorization: Basic $auth`r`nConnection: keep-alive`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($connectRequest)
        $stream.Write($requestBytes, 0, $requestBytes.Length)
        $stream.Flush()
        $status = Read-MishAsciiLine -Stream $stream
        Read-MishHeaders -Stream $stream
        if ($status -notmatch '^HTTP/1\.[01]\s+2\d\d\b') { throw 'Mesh proxy did not admit CONNECT.' }

        $tls = [Net.Security.SslStream]::new($stream, $false)
        $tls.ReadTimeout = $script:IoTimeoutMs
        $tls.WriteTimeout = $script:IoTimeoutMs
        $tls.AuthenticateAsClient($TargetHost)
        $session = [pscustomobject]@{ Client = $client; TlsStream = $tls }
        if (-not (Invoke-MishApplicationRoundTrip -Session $session)) { throw 'Initial application round-trip failed.' }
        return $session
    }
    catch {
        if ($null -ne $tls) { $tls.Dispose() } else { $client.Dispose() }
        throw
    }
}

function Close-MishApplicationSession {
    param($Session)
    if ($null -eq $Session) { return }
    try { $Session.TlsStream.Dispose() } catch { }
    try { $Session.Client.Dispose() } catch { }
}

function Set-MishAirplane {
    param([Parameter(Mandatory)][ValidateSet('enable', 'disable')][string] $State)
    $result = Invoke-MishAdb -Arguments @('shell', 'cmd', 'connectivity', 'airplane-mode', $State) -TimeoutSeconds 20
    if ($result.ExitCode -ne 0) {
        Stop-MishRecovery 'LAB_AIRPLANE_CONTROL_FAILED' "Bounded airplane-mode $State command failed."
    }
}

function Get-MishE3FailureClassification {
    param([Parameter(Mandatory)][string] $Output)
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
$airplaneMayBeEnabled = $false
$preLossSession = $null
$recoverySession = $null
$credentialStorePath = $null
$lossEvidence = [ordered]@{}
$cellularEvidence = [ordered]@{}
$restartEvidence = [ordered]@{}
$testApkSha = ''

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
    $preMesh = @(Get-MishMeshAddresses)
    if (
        $null -eq $preSnapshot -or -not [bool]$preSnapshot.consistent -or
        -not [bool]$preSnapshot.cellular.admitted -or
        -not [bool]$preSnapshot.mesh.admitted -or
        -not [bool]$preSnapshot.mesh.epoch_present -or
        -not [bool]$preSnapshot.mesh.ingress_running -or
        [string]$preSnapshot.readiness.state -cne 'READY' -or
        $preMesh.Count -ne 1
    ) {
        Stop-MishRecovery 'LAB_RECOVERY_PRECONDITION_NOT_READY' 'Baseline owner/network facts are not ready for the explicit recovery probe.'
    }

    Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
    $credentialRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
    $credentialStorePath = Join-Path $credentialRoot ('mish-recovery-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishRecovery 'LAB_CREDENTIAL_LEASE_UNAVAILABLE' 'External proxy credential lease is unavailable.' }

    $preLossSession = Open-MishApplicationSession -ProxyHost ([string]$preMesh[0]) -Lease $lease
    $sessionOwner = Wait-MishCondition -TimeoutSeconds 10 -Condition {
        $snapshot = Read-MishSnapshot
        if ($null -ne $snapshot -and [bool]$snapshot.consistent -and [int64]$snapshot.mesh.active_sessions -eq 1 -and [int]$snapshot.proxy.active_sessions -eq 1) { return $snapshot }
        return $null
    }
    if ($null -eq $sessionOwner) {
        Stop-MishRecovery 'U2_MESH_PRELOSS_OWNER_COUNT_MISMATCH' 'One application-live Mesh session was not reflected by both natural owners.'
    }

    $lossWatch = [Diagnostics.Stopwatch]::StartNew()
    $airplaneMayBeEnabled = $true
    Set-MishAirplane -State enable

    $externalLoss = Wait-MishCondition -TimeoutSeconds 45 -Condition {
        $addresses = @(Get-MishMeshAddresses)
        if ($addresses.Count -eq 0) { return $true }
        return $null
    }
    if ($null -eq $externalLoss) {
        Stop-MishRecovery 'LAB_MESH_LOSS_EFFECT_NOT_OBSERVED' 'Airplane control did not remove the external Mesh endpoint inside the bounded window.'
    }

    $ownerLoss = Wait-MishCondition -TimeoutSeconds 15 -Condition {
        $snapshot = Read-MishSnapshot
        if (
            $null -ne $snapshot -and [bool]$snapshot.consistent -and
            -not [bool]$snapshot.mesh.admitted -and
            -not [bool]$snapshot.mesh.epoch_present -and
            -not [bool]$snapshot.mesh.ingress_running -and
            [int64]$snapshot.mesh.active_sessions -eq 0
        ) { return $snapshot }
        return $null
    }
    if ($null -eq $ownerLoss) {
        Stop-MishRecovery 'U2_MESH_LOSS_NOT_REVOKED' 'Observed Mesh endpoint loss did not revoke admission/epoch/ingress and drain sessions.'
    }
    $lossWatch.Stop()

    $existingSessionBlocked = -not (Invoke-MishApplicationRoundTrip -Session $preLossSession)
    if (-not $existingSessionBlocked) {
        Stop-MishRecovery 'U2_MESH_SESSION_SURVIVED_REVOKE' 'The pre-loss application-live Mesh session still exchanged application data after owner revocation.'
    }
    Close-MishApplicationSession -Session $preLossSession
    $preLossSession = $null

    $recoveryWatch = [Diagnostics.Stopwatch]::StartNew()
    Set-MishAirplane -State disable
    $airplaneMayBeEnabled = $false

    $externalRecovery = Wait-MishCondition -TimeoutSeconds 120 -Condition {
        $addresses = @(Get-MishMeshAddresses)
        if ($addresses.Count -eq 1) { return [string]$addresses[0] }
        return $null
    }
    if ($null -eq $externalRecovery) {
        Stop-MishRecovery 'LAB_MESH_RECOVERY_EFFECT_NOT_OBSERVED' 'The external Mesh endpoint did not return inside the bounded recovery window.'
    }

    $ownerRecovery = Wait-MishCondition -TimeoutSeconds 60 -Condition {
        $snapshot = Read-MishSnapshot
        if (
            $null -ne $snapshot -and [bool]$snapshot.consistent -and
            [bool]$snapshot.cellular.admitted -and
            [bool]$snapshot.mesh.admitted -and
            [bool]$snapshot.mesh.epoch_present -and
            [bool]$snapshot.mesh.ingress_running -and
            [string]$snapshot.readiness.state -ceq 'READY'
        ) { return $snapshot }
        return $null
    }
    if ($null -eq $ownerRecovery) {
        Stop-MishRecovery 'U2_MESH_RECOVERY_OWNER_NOT_READY' 'Returned Mesh endpoint did not produce admitted owner/epoch/ingress readiness.'
    }

    $recoverySession = Open-MishApplicationSession -ProxyHost ([string]$externalRecovery) -Lease $lease
    if (-not (Invoke-MishApplicationRoundTrip -Session $recoverySession)) {
        Stop-MishRecovery 'U2_MESH_RECOVERY_E2E_FAILED' 'Fresh external Mesh application round-trip failed after owner recovery.'
    }
    Close-MishApplicationSession -Session $recoverySession
    $recoverySession = $null
    $recoveryWatch.Stop()

    $lossEvidence = [ordered]@{
        pre_loss_application_live = $true
        pre_loss_owner_counts = [ordered]@{ mesh = 1; proxy = 1 }
        external_mesh_absent = $true
        owner_revoked = $true
        epoch_revoked = $true
        ingress_stopped = $true
        sessions_drained = $true
        established_session_blocked = $true
        loss_elapsed_ms = [int64]$lossWatch.ElapsedMilliseconds
        external_mesh_returned = $true
        owner_readmitted = $true
        epoch_reestablished_after_absence = $true
        ingress_restarted = $true
        fresh_mesh_e2e = $true
        recovery_elapsed_ms = [int64]$recoveryWatch.ElapsedMilliseconds
    }

    $install = Invoke-MishAdb -Arguments @('install', '-r', '-t', $testApkPath) -TimeoutSeconds 120
    if ($install.ExitCode -ne 0 -or $install.StdOut -notmatch '(?m)^Success\s*$') {
        Stop-MishRecovery 'LAB_TEST_APK_INSTALL_FAILED' 'Exact androidTest APK installation failed.'
    }
    $testPackagePath = Invoke-MishAdb -Arguments @('shell', 'pm', 'path', $script:TestPackage) -TimeoutSeconds 20
    $pathRows = @($testPackagePath.StdOut -split "`r?`n" | Where-Object { $_ -match '^package:.+/base\.apk$' })
    if ($testPackagePath.ExitCode -ne 0 -or $pathRows.Count -ne 1) {
        Stop-MishRecovery 'LAB_TEST_APK_INSTALL_IDENTITY_MISSING' 'Installed exact androidTest package path could not be resolved uniquely.'
    }
    $remoteTestApk = $pathRows[0].Substring('package:'.Length)
    $pulledTestApk = Join-Path ([IO.Path]::GetTempPath()) ('mish-e3-installed-' + [Guid]::NewGuid().ToString('N') + '.apk')
    try {
        $pull = Invoke-MishAdb -Arguments @('pull', $remoteTestApk, $pulledTestApk) -TimeoutSeconds 60
        if ($pull.ExitCode -ne 0 -or (Get-MishSha256 -Path $pulledTestApk) -cne $testApkSha) {
            Stop-MishRecovery 'LAB_TEST_APK_INSTALLED_DIGEST_MISMATCH' 'Installed androidTest APK bytes differ from the exact hosted candidate.'
        }
    }
    finally { Remove-Item -LiteralPath $pulledTestApk -Force -ErrorAction SilentlyContinue }

    $instrumentation = Invoke-MishAdb -Arguments @(
        'shell', 'am', 'instrument', '-w', '-r',
        '-e', 'class', $script:TestClass,
        '-e', 'e3Mode', 'lifecycle',
        $script:TestComponent
    ) -TimeoutSeconds 300
    $instrumentationPass = $instrumentation.ExitCode -eq 0 -and $instrumentation.StdOut -match 'OK \(1 test\)'
    $positive = $instrumentation.StdOut -match 'E3_EVIDENCE phase=positive '
    $negative = $instrumentation.StdOut -match 'E3_EVIDENCE phase=negative '
    $recovery = $instrumentation.StdOut -match 'E3_EVIDENCE phase=recovery '
    if (-not $instrumentationPass -or -not $positive -or -not $negative -or -not $recovery) {
        Stop-MishRecovery (Get-MishE3FailureClassification -Output $instrumentation.StdOut) 'Exact-head Cellular E3 lifecycle instrumentation failed.'
    }
    $cellularEvidence = [ordered]@{
        exact_test_apk_sha256 = $testApkSha
        installed_exact_bytes_verified = $true
        instrumentation_pass = $true
        positive_phase = $positive
        negative_phase = $negative
        recovery_phase = $recovery
        established_flow_blocked = $instrumentation.StdOut -match 'established_flow_blocked=true'
        dns_blocked = $instrumentation.StdOut -match 'dns_blocked=true'
        public_socket_blocked = $instrumentation.StdOut -match 'public_socket_blocked=true'
        no_default_fallback = $instrumentation.StdOut -match 'no_default_fallback=true'
        fresh_generation = $instrumentation.StdOut -match 'fresh_generation=true'
        cleanup_verified = $instrumentation.StdOut -match 'cleanup_verified=true'
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
    if ([string]$postDiagnostic.classification -cne 'PASS') {
        $postClass = [string]$postDiagnostic.classification
        if ($postClass -like 'LAB_*') { Stop-MishRecovery $postClass 'Post-restart canonical diagnostic failed in LAB.' }
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
        diagnostic_classification = [string]$postDiagnostic.classification
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
    if (
        -not [bool]$restartEvidence.root_policy_authorized -or
        [string]$restartEvidence.root_authority_observation -cne 'READY_AT_POLICY_AUTHORIZATION' -or
        -not [bool]$restartEvidence.proxy_healthy -or
        -not [bool]$restartEvidence.mesh_admitted -or
        -not [bool]$restartEvidence.mesh_epoch_present -or
        -not [bool]$restartEvidence.mesh_ingress_running -or
        [string]$restartEvidence.loopback_e2e -cne 'PASS' -or
        [string]$restartEvidence.mesh_e2e -cne 'PASS'
    ) {
        Stop-MishRecovery 'U2_RESTART_RECOVERY_INCOMPLETE' 'Canonical post-restart owner/readiness/E2E evidence is incomplete.'
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
    Close-MishApplicationSession -Session $preLossSession
    Close-MishApplicationSession -Session $recoverySession
    if ($airplaneMayBeEnabled) {
        try { Set-MishAirplane -State disable } catch { }
    }
    if ($credentialStorePath -and (Test-Path -LiteralPath $credentialStorePath -PathType Leaf)) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
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
        lab_effects = [ordered]@{
            mesh_loss = 'adb shell cmd connectivity airplane-mode enable/disable'
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
