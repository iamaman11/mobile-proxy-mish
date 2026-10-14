[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [ValidateRange(5, 30)][int] $ExternalProbeTimeoutSeconds = 15,
    [ValidateRange(5, 60)][int] $LossTimeoutSeconds = 30,
    [ValidateRange(5, 90)][int] $RecoveryTimeoutSeconds = 45,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-cellular-data-detach-pilot-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.cellular-data-detach-pilot/v1'
$script:SnapshotSchema = 'mish.diagnostics/v2'
$script:PollMilliseconds = 100

function Stop-MishCandidateA {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_CANDIDATE_A_FAILURE|$Classification|$Message"
}

function Invoke-MishAdbCapture {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 120)][int] $TimeoutSeconds = 30
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $AdbPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Stop-MishCandidateA 'LAB_PROCESS_START_FAILED' 'Required ADB subprocess could not be started.'
    }
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            Stop-MishCandidateA 'LAB_PROCESS_TIMEOUT' 'Required ADB subprocess exceeded its bounded timeout.'
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

function Read-MishSnapshot {
    $capture = Invoke-MishAdbCapture -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', 'snapshot_v2'
    ) -TimeoutSeconds 15
    if ($capture.ExitCode -ne 0) { return $null }

    $match = [regex]::Match($capture.StdOut, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { return $null }

    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        $snapshot = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        if (
            [string]$snapshot.schema -cne $script:SnapshotSchema -or
            [string]$snapshot.application_id -cne $PackageName -or
            -not [bool]$snapshot.consistent
        ) {
            return $null
        }
        return $snapshot
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-MishMobileDataSetting {
    $capture = Invoke-MishAdbCapture -Arguments @('shell', 'settings', 'get', 'global', 'mobile_data') -TimeoutSeconds 10
    if ($capture.ExitCode -ne 0) { return 'UNKNOWN' }
    switch ($capture.StdOut.Trim()) {
        '1' { return 'ENABLED' }
        '0' { return 'DISABLED' }
        default { return 'UNKNOWN' }
    }
}

function Get-MishAirplaneSetting {
    $capture = Invoke-MishAdbCapture -Arguments @('shell', 'settings', 'get', 'global', 'airplane_mode_on') -TimeoutSeconds 10
    if ($capture.ExitCode -ne 0) { return 'UNKNOWN' }
    switch ($capture.StdOut.Trim()) {
        '1' { return 'ENABLED' }
        '0' { return 'DISABLED' }
        default { return 'UNKNOWN' }
    }
}

function Invoke-MishDataTransition {
    param([Parameter(Mandatory)][ValidateSet('enable','disable')][string] $State)
    $capture = Invoke-MishAdbCapture -Arguments @('shell', 'cmd', 'phone', 'data', $State) -TimeoutSeconds 20
    if ($capture.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($capture.StdOut)) {
        Stop-MishCandidateA 'LAB_DATA_CONTROL_FAILED' "Bounded mobile-data $State request failed."
    }
}

function Invoke-MishExistingDiagnostic {
    param(
        [Parameter(Mandatory)][string] $ScriptName,
        [Parameter(Mandatory)][string] $OutputPath,
        [switch] $IncludeMeshCidr
    )
    $scriptPath = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        Stop-MishCandidateA 'LAB_REQUIRED_TOOL_MISSING' "Required existing diagnostic is missing: $ScriptName"
    }
    if ($IncludeMeshCidr) {
        & $scriptPath -AdbPath $AdbPath -PackageName $PackageName -MeshCidr $MeshCidr -EvidencePath $OutputPath | Out-Host
    } else {
        & $scriptPath -AdbPath $AdbPath -PackageName $PackageName -EvidencePath $OutputPath | Out-Host
    }
    if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
        Stop-MishCandidateA 'LAB_DIAGNOSTIC_EVIDENCE_MISSING' "Existing diagnostic did not produce evidence: $ScriptName"
    }
    return (Get-Content -Raw -LiteralPath $OutputPath | ConvertFrom-Json)
}

function Test-MishReadySnapshot {
    param([AllowNull()] $Snapshot)
    if ($null -eq $Snapshot) { return $false }
    if (
        -not [bool]$Snapshot.runtime.running -or
        -not [bool]$Snapshot.cellular.admitted -or
        $null -eq $Snapshot.cellular.owner_sequence -or
        -not [bool]$Snapshot.root.policy_authorized -or
        $null -eq $Snapshot.root.policy_authorized_generation -or
        [int64]$Snapshot.root.policy_authorized_generation -ne [int64]$Snapshot.cellular.owner_sequence -or
        [string]$Snapshot.proxy.state -cne 'RUNNING' -or
        -not [bool]$Snapshot.proxy.healthy -or
        -not [bool]$Snapshot.mesh.admitted -or
        -not [bool]$Snapshot.mesh.ingress_running -or
        [string]$Snapshot.readiness.state -cne 'READY' -or
        $null -eq $Snapshot.readiness.binding.cellular_owner_generation -or
        [int64]$Snapshot.readiness.binding.cellular_owner_generation -ne [int64]$Snapshot.cellular.owner_sequence
    ) { return $false }
    return $true
}

function Convert-MishRotationOperationId {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return 'NONE' }
    return [string][int64]$Value
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishCandidateA 'LAB_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}
$devices = @(& $AdbPath devices 2>$null | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {
    Stop-MishCandidateA 'LAB_DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.'
}
$model = (& $AdbPath shell getprop ro.product.model 2>$null).Trim()
$api = (& $AdbPath shell getprop ro.build.version.sdk 2>$null).Trim()
$abi = (& $AdbPath shell getprop ro.product.cpu.abi 2>$null).Trim()
if ($model -cne 'SM-A022G' -or $api -cne '30' -or $abi -cne 'armeabi-v7a') {
    Stop-MishCandidateA 'LAB_DEVICE_IDENTITY_MISMATCH' "Expected SM-A022G/API30/armeabi-v7a; observed $model/API$api/$abi."
}

Import-Module (Join-Path $PSScriptRoot 'PublicEgressObservation.psm1') -Force

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    Stop-MishCandidateA 'LAB_TEMP_UNAVAILABLE' 'A temporary directory is unavailable.'
}
$beforeDevicePath = Join-Path $tempRoot 'mish-candidate-a-before-device.json'
$beforeControlPath = Join-Path $tempRoot 'mish-candidate-a-before-control.json'
$afterDevicePath = Join-Path $tempRoot 'mish-candidate-a-after-device.json'
$afterControlPath = Join-Path $tempRoot 'mish-candidate-a-after-control.json'

$beforeAddress = $null
$afterAddress = $null
$publicContext = $null
$dataMayBeDisabled = $false
$fatal = $null
$pilotWatch = $null

$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'FAIL'
    classification = 'LAB_RESEARCH_CANDIDATE_A_NOT_COMPLETED'
    candidate = 'A_MOBILE_DATA_DETACH_ATTACH'
    primitive = 'cmd phone data disable -> cmd phone data enable'
    cycles = 1
    product_install_performed = $false
    product_restart_performed = $false
    product_rotation_triggered = $false
    manager_command_issued = $false
    automatic_repeat = $false
    raw_public_ip_persisted = $false
    secrets_persisted_in_evidence = $false
    initial_settings = [ordered]@{ mobile_data = 'UNKNOWN'; airplane_mode = 'UNKNOWN' }
    final_settings = [ordered]@{ mobile_data = 'UNKNOWN'; airplane_mode = 'UNKNOWN' }
    process = [ordered]@{ pid = $null; pid_stable = $false; runtime_generation = $null; runtime_generation_stable = $false }
    generation = [ordered]@{ before_owner_sequence = $null; after_owner_sequence = $null; advanced = $false; exact_root_authorized = $false; readiness_bound_to_fresh_owner = $false }
    external_public_egress = [ordered]@{ observations = 0; outcome = 'FAILED' }
    before = [ordered]@{ product = 'UNKNOWN'; mesh_e2e = 'UNKNOWN'; control = 'UNKNOWN' }
    after = [ordered]@{ product = 'UNKNOWN'; mesh_e2e = 'UNKNOWN'; control = 'UNKNOWN' }
    timings_ms = [ordered]@{
        disable_command = $null
        disable_start_to_loss = $null
        enable_command = $null
        enable_start_to_first_cellular_callback = $null
        enable_start_to_fresh_admission = $null
        first_callback_to_fresh_admission = $null
        fresh_admission_to_root_authorized = $null
        root_authorized_to_readiness_ready = $null
        enable_start_to_readiness_ready = $null
        primitive_start_to_functional_public_egress = $null
        primitive_start_to_mesh_e2e = $null
        primitive_start_to_control_ready = $null
    }
}

try {
    $evidence.initial_settings.mobile_data = Get-MishMobileDataSetting
    $evidence.initial_settings.airplane_mode = Get-MishAirplaneSetting
    if ($evidence.initial_settings.mobile_data -cne 'ENABLED' -or $evidence.initial_settings.airplane_mode -cne 'DISABLED') {
        Stop-MishCandidateA 'CANDIDATE_A_BASELINE_SETTINGS_INVALID' 'Pilot requires mobile data enabled and airplane mode disabled before mutation.'
    }

    $beforeDevice = Invoke-MishExistingDiagnostic -ScriptName 'collect-device-diagnostic.ps1' -OutputPath $beforeDevicePath -IncludeMeshCidr
    if ([string]$beforeDevice.classification -cne 'PASS') {
        Stop-MishCandidateA 'CANDIDATE_A_BASELINE_PRODUCT_INVALID' "Standard pre-pilot diagnostic must PASS; observed $($beforeDevice.classification)."
    }
    $evidence.before.product = 'PASS'
    $evidence.before.mesh_e2e = [string]$beforeDevice.external.mesh_proxy_e2e.result
    if ($evidence.before.mesh_e2e -cne 'PASS') {
        Stop-MishCandidateA 'CANDIDATE_A_BASELINE_MESH_E2E_FAILED' 'Windows -> Mesh -> DEVICE-1 proxy E2E must PASS before the physical pilot.'
    }

    $beforeControl = Invoke-MishExistingDiagnostic -ScriptName 'collect-control-diagnostic.ps1' -OutputPath $beforeControlPath
    $evidence.before.control = [string]$beforeControl.control.state
    if ($evidence.before.control -cne 'READY') {
        Stop-MishCandidateA 'CANDIDATE_A_BASELINE_CONTROL_INVALID' "CONTROL must be READY before the physical pilot; observed $($evidence.before.control)."
    }

    $baseline = Read-MishSnapshot
    if (-not (Test-MishReadySnapshot -Snapshot $baseline)) {
        Stop-MishCandidateA 'CANDIDATE_A_BASELINE_SNAPSHOT_INVALID' 'Canonical PRODUCT snapshot is not READY with exact-generation root authorization.'
    }
    $baselinePid = [int64]$baseline.pid
    $baselineRuntimeGeneration = [int64]$baseline.runtime.generation
    $baselineOwner = [int64]$baseline.cellular.owner_sequence
    $baselineRequested = [int64]$baseline.cellular.reconcile.requested
    $baselineRotationId = Convert-MishRotationOperationId -Value $baseline.rotation.operation_id
    if ([int64]$baseline.rotation.active_tasks -ne 0) {
        Stop-MishCandidateA 'CANDIDATE_A_BASELINE_ROTATION_ACTIVE' 'PRODUCT Rotation must be idle before LAB-owned data detach.'
    }
    $evidence.process.pid = $baselinePid
    $evidence.process.runtime_generation = $baselineRuntimeGeneration
    $evidence.generation.before_owner_sequence = $baselineOwner

    $publicContext = New-MishPublicEgressObservationContext -AdbPath $AdbPath -PackageName $PackageName
    $beforePublic = Invoke-MishExternalPublicIpObservation -Context $publicContext -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $beforeAddress = [string]$beforePublic.Address
    $evidence.external_public_egress.observations = 1

    $pilotWatch = [Diagnostics.Stopwatch]::StartNew()
    $disableStartMs = [int64]$pilotWatch.ElapsedMilliseconds
    $commandWatch = [Diagnostics.Stopwatch]::StartNew()
    $dataMayBeDisabled = $true
    Invoke-MishDataTransition -State 'disable'
    $commandWatch.Stop()
    $evidence.timings_ms.disable_command = [int64]$commandWatch.ElapsedMilliseconds

    $loss = $null
    while ($pilotWatch.Elapsed.TotalSeconds -lt $LossTimeoutSeconds) {
        $snapshot = Read-MishSnapshot
        if ($null -ne $snapshot -and [int64]$snapshot.pid -ne $baselinePid) {
            Stop-MishCandidateA 'CANDIDATE_A_PRODUCT_PROCESS_CHANGED' 'PRODUCT PID changed during the same-process Candidate A pilot.'
        }
        if ($null -ne $snapshot -and -not [bool]$snapshot.cellular.admitted) {
            $loss = $snapshot
            break
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }
    if ($null -eq $loss) {
        Stop-MishCandidateA 'CANDIDATE_A_CELLULAR_LOSS_NOT_OBSERVED' 'Rust-owned Cellular admission did not observe loss within the bounded window.'
    }
    $lossObservedMs = [int64]$pilotWatch.ElapsedMilliseconds
    $evidence.timings_ms.disable_start_to_loss = $lossObservedMs - $disableStartMs
    $lossRequested = [int64]$loss.cellular.reconcile.requested
    if ($lossRequested -le $baselineRequested) {
        Stop-MishCandidateA 'CANDIDATE_A_LOSS_CALLBACK_NOT_PROVEN' 'Cellular reconcile request count did not advance for the loss observation.'
    }

    $enableStartMs = [int64]$pilotWatch.ElapsedMilliseconds
    $commandWatch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-MishDataTransition -State 'enable'
    $dataMayBeDisabled = $false
    $commandWatch.Stop()
    $evidence.timings_ms.enable_command = [int64]$commandWatch.ElapsedMilliseconds

    $firstCallbackMs = $null
    $freshAdmissionMs = $null
    $rootAuthorizedMs = $null
    $readyMs = $null
    $freshOwner = $null
    $finalSnapshot = $null
    $recoveryDeadlineMs = $enableStartMs + [int64]($RecoveryTimeoutSeconds * 1000)

    while ([int64]$pilotWatch.ElapsedMilliseconds -lt $recoveryDeadlineMs) {
        $snapshot = Read-MishSnapshot
        if ($null -eq $snapshot) {
            Start-Sleep -Milliseconds $script:PollMilliseconds
            continue
        }
        if ([int64]$snapshot.pid -ne $baselinePid -or [int64]$snapshot.runtime.generation -ne $baselineRuntimeGeneration) {
            Stop-MishCandidateA 'CANDIDATE_A_PRODUCT_PROCESS_CHANGED' 'PRODUCT process/runtime generation changed during Candidate A.'
        }
        $nowMs = [int64]$pilotWatch.ElapsedMilliseconds
        if ($null -eq $firstCallbackMs -and [int64]$snapshot.cellular.reconcile.requested -gt $lossRequested) {
            $firstCallbackMs = $nowMs
        }
        if (
            $null -eq $freshAdmissionMs -and
            [bool]$snapshot.cellular.admitted -and
            $null -ne $snapshot.cellular.owner_sequence -and
            [int64]$snapshot.cellular.owner_sequence -gt $baselineOwner
        ) {
            $freshOwner = [int64]$snapshot.cellular.owner_sequence
            $freshAdmissionMs = $nowMs
        }
        if (
            $null -ne $freshOwner -and
            $null -eq $rootAuthorizedMs -and
            [bool]$snapshot.root.policy_authorized -and
            $null -ne $snapshot.root.policy_authorized_generation -and
            [int64]$snapshot.root.policy_authorized_generation -eq $freshOwner -and
            [int64]$snapshot.cellular.owner_sequence -eq $freshOwner
        ) {
            $rootAuthorizedMs = $nowMs
        }
        if (
            $null -ne $freshOwner -and
            $null -ne $rootAuthorizedMs -and
            (Test-MishReadySnapshot -Snapshot $snapshot) -and
            [int64]$snapshot.cellular.owner_sequence -eq $freshOwner
        ) {
            $readyMs = $nowMs
            $finalSnapshot = $snapshot
            break
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }

    if ($null -eq $firstCallbackMs) {
        Stop-MishCandidateA 'CANDIDATE_A_RECOVERY_CALLBACK_NOT_OBSERVED' 'No post-enable Cellular callback/reconcile request was observed.'
    }
    if ($null -eq $freshAdmissionMs -or $null -eq $freshOwner) {
        Stop-MishCandidateA 'CANDIDATE_A_FRESH_GENERATION_NOT_ADMITTED' 'No strictly fresh admitted Cellular owner sequence was observed.'
    }
    if ($null -eq $rootAuthorizedMs) {
        Stop-MishCandidateA 'CANDIDATE_A_EXACT_ROOT_AUTHORIZATION_NOT_OBSERVED' 'Root policy did not authorize the exact fresh Cellular owner sequence.'
    }
    if ($null -eq $readyMs -or $null -eq $finalSnapshot) {
        Stop-MishCandidateA 'CANDIDATE_A_PRODUCT_NOT_READY' 'Proxy/Mesh/readiness did not reconverge on the exact fresh owner within the bounded window.'
    }

    $evidence.timings_ms.enable_start_to_first_cellular_callback = [int64]$firstCallbackMs - $enableStartMs
    $evidence.timings_ms.enable_start_to_fresh_admission = [int64]$freshAdmissionMs - $enableStartMs
    $evidence.timings_ms.first_callback_to_fresh_admission = [int64]$freshAdmissionMs - [int64]$firstCallbackMs
    $evidence.timings_ms.fresh_admission_to_root_authorized = [int64]$rootAuthorizedMs - [int64]$freshAdmissionMs
    $evidence.timings_ms.root_authorized_to_readiness_ready = [int64]$readyMs - [int64]$rootAuthorizedMs
    $evidence.timings_ms.enable_start_to_readiness_ready = [int64]$readyMs - $enableStartMs

    $evidence.generation.after_owner_sequence = $freshOwner
    $evidence.generation.advanced = $freshOwner -gt $baselineOwner
    $evidence.generation.exact_root_authorized = (
        [bool]$finalSnapshot.root.policy_authorized -and
        [int64]$finalSnapshot.root.policy_authorized_generation -eq $freshOwner
    )
    $evidence.generation.readiness_bound_to_fresh_owner = (
        $null -ne $finalSnapshot.readiness.binding.cellular_owner_generation -and
        [int64]$finalSnapshot.readiness.binding.cellular_owner_generation -eq $freshOwner
    )

    $afterPublic = Invoke-MishExternalPublicIpObservation -Context $publicContext -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $afterAddress = [string]$afterPublic.Address
    $evidence.external_public_egress.observations = 2
    $evidence.external_public_egress.outcome = if ($beforeAddress -cne $afterAddress) { 'CHANGED' } else { 'UNCHANGED' }
    $evidence.timings_ms.primitive_start_to_functional_public_egress = [int64]$pilotWatch.ElapsedMilliseconds

    $afterDevice = Invoke-MishExistingDiagnostic -ScriptName 'collect-device-diagnostic.ps1' -OutputPath $afterDevicePath -IncludeMeshCidr
    $evidence.after.product = [string]$afterDevice.classification
    $evidence.after.mesh_e2e = [string]$afterDevice.external.mesh_proxy_e2e.result
    if ($evidence.after.product -cne 'PASS' -or $evidence.after.mesh_e2e -cne 'PASS') {
        Stop-MishCandidateA 'CANDIDATE_A_POST_MESH_E2E_FAILED' "Post-pilot standard diagnostic must PASS with Mesh E2E PASS; observed $($evidence.after.product)/$($evidence.after.mesh_e2e)."
    }
    $evidence.timings_ms.primitive_start_to_mesh_e2e = [int64]$pilotWatch.ElapsedMilliseconds

    $afterControl = Invoke-MishExistingDiagnostic -ScriptName 'collect-control-diagnostic.ps1' -OutputPath $afterControlPath
    $evidence.after.control = [string]$afterControl.control.state
    if ($evidence.after.control -cne 'READY') {
        Stop-MishCandidateA 'CANDIDATE_A_POST_CONTROL_NOT_READY' "CONTROL did not return READY after the pilot; observed $($evidence.after.control)."
    }
    $evidence.timings_ms.primitive_start_to_control_ready = [int64]$pilotWatch.ElapsedMilliseconds

    $postSnapshot = Read-MishSnapshot
    if (-not (Test-MishReadySnapshot -Snapshot $postSnapshot)) {
        Stop-MishCandidateA 'CANDIDATE_A_POST_SNAPSHOT_INVALID' 'Final canonical PRODUCT snapshot is not READY.'
    }
    $postRotationId = Convert-MishRotationOperationId -Value $postSnapshot.rotation.operation_id
    if ($postRotationId -cne $baselineRotationId -or [int64]$postSnapshot.rotation.active_tasks -ne 0) {
        Stop-MishCandidateA 'CANDIDATE_A_PRODUCT_ROTATION_MUTATED' 'LAB-owned data detach must not trigger or alter PRODUCT Rotation.'
    }
    if ([int64]$postSnapshot.pid -ne $baselinePid -or [int64]$postSnapshot.runtime.generation -ne $baselineRuntimeGeneration) {
        Stop-MishCandidateA 'CANDIDATE_A_PRODUCT_PROCESS_CHANGED' 'Final PRODUCT process/runtime generation differs from baseline.'
    }

    $evidence.process.pid_stable = $true
    $evidence.process.runtime_generation_stable = $true
    $evidence.product_rotation_triggered = $false
    $evidence.final_settings.mobile_data = Get-MishMobileDataSetting
    $evidence.final_settings.airplane_mode = Get-MishAirplaneSetting
    if ($evidence.final_settings.mobile_data -cne 'ENABLED' -or $evidence.final_settings.airplane_mode -cne 'DISABLED') {
        Stop-MishCandidateA 'CANDIDATE_A_SETTINGS_NOT_RESTORED' 'Pilot did not restore the original mobile-data/airplane settings.'
    }

    $evidence.acceptance_result = 'PASS'
    $evidence.classification = if ($evidence.external_public_egress.outcome -ceq 'CHANGED') {
        'CANDIDATE_A_CHANGED'
    } else {
        'CANDIDATE_A_UNCHANGED'
    }
}
catch {
    $fatal = $_
    $message = [string]$_
    if ($message -match 'MISH_CANDIDATE_A_FAILURE\|([A-Z0-9_]+)\|') {
        $inner = [string]$Matches[1]
        $evidence.classification = if ($inner.StartsWith('LAB_')) { "LAB_RESEARCH_$inner" } else { "LAB_RESEARCH_$inner" }
    } else {
        $evidence.classification = 'LAB_RESEARCH_CANDIDATE_A_UNEXPECTED_FAILURE'
    }
}
finally {
    if ($null -ne $pilotWatch) { $pilotWatch.Stop() }
    if ($dataMayBeDisabled) {
        try { Invoke-MishDataTransition -State 'enable' } catch { }
    }
    try { $evidence.final_settings.mobile_data = Get-MishMobileDataSetting } catch { }
    try { $evidence.final_settings.airplane_mode = Get-MishAirplaneSetting } catch { }
    Close-MishPublicEgressObservationContext -Context $publicContext
    $publicContext = $null
    $beforeAddress = $null
    $afterAddress = $null

    $fullPath = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $fullPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullPath,
        (($evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "MISH_CANDIDATE_A_RESULT=$($evidence.acceptance_result)"
    Write-Host "MISH_CANDIDATE_A_CLASSIFICATION=$($evidence.classification)"
    Write-Host "MISH_CANDIDATE_A_EXTERNAL_OUTCOME=$($evidence.external_public_egress.outcome)"
    Write-Host 'MISH_CANDIDATE_A_CYCLES=1'
    Write-Host 'MISH_CANDIDATE_A_RAW_IP_PERSISTED=false'
    Write-Host "MISH_CANDIDATE_A_EVIDENCE=$fullPath"
}

if ($null -ne $fatal) { throw $fatal }
