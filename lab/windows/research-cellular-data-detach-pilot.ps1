[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [ValidateRange(5, 30)][int] $ExternalProbeTimeoutSeconds = 15,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-cellular-data-detach-pilot-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.cellular-data-detach-pilot/v1'
$script:SnapshotSchema = 'mish.diagnostics/v2'

function Stop-MishCandidateA {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_CANDIDATE_A_FAILURE|$Classification|$Message"
}

function Read-MishSnapshot {
    $output = @(& $AdbPath shell content call `
        --uri "content://$PackageName.diagnostics" `
        --method snapshot_v2 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    $match = [regex]::Match(($output -join "`n"), 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { return $null }

    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        $snapshot = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        if (
            [string]$snapshot.schema -cne $script:SnapshotSchema -or
            [string]$snapshot.application_id -cne $PackageName -or
            -not [bool]$snapshot.consistent
        ) { return $null }
        return $snapshot
    }
    catch { return $null }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Test-MishExactReadySnapshot {
    param([AllowNull()] $Snapshot)
    if ($null -eq $Snapshot) { return $false }
    return (
        [bool]$Snapshot.runtime.running -and
        [bool]$Snapshot.cellular.admitted -and
        $null -ne $Snapshot.cellular.owner_sequence -and
        [bool]$Snapshot.root.policy_authorized -and
        $null -ne $Snapshot.root.policy_authorized_generation -and
        [int64]$Snapshot.root.policy_authorized_generation -eq [int64]$Snapshot.cellular.owner_sequence -and
        [string]$Snapshot.proxy.state -ceq 'RUNNING' -and
        [bool]$Snapshot.proxy.healthy -and
        [bool]$Snapshot.mesh.admitted -and
        [bool]$Snapshot.mesh.ingress_running -and
        [string]$Snapshot.readiness.state -ceq 'READY' -and
        $null -ne $Snapshot.readiness.binding.cellular_owner_generation -and
        [int64]$Snapshot.readiness.binding.cellular_owner_generation -eq [int64]$Snapshot.cellular.owner_sequence
    )
}

function Convert-MishRotationOperationId {
    param([AllowNull()] $Value)
    if ($null -eq $Value) { return 'NONE' }
    return [string][int64]$Value
}

function Read-RequiredJson {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Classification
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-MishCandidateA $Classification "Required evidence is missing: $Path"
    }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
    catch { Stop-MishCandidateA $Classification "Required evidence is invalid JSON: $Path" }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishCandidateA 'LAB_RESEARCH_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}
$devices = @(& $AdbPath devices 2>$null | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {
    Stop-MishCandidateA 'LAB_RESEARCH_DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.'
}
$model = (& $AdbPath shell getprop ro.product.model 2>$null).Trim()
$api = (& $AdbPath shell getprop ro.build.version.sdk 2>$null).Trim()
$abi = (& $AdbPath shell getprop ro.product.cpu.abi 2>$null).Trim()
if ($model -cne 'SM-A022G' -or $api -cne '30' -or $abi -cne 'armeabi-v7a') {
    Stop-MishCandidateA 'LAB_RESEARCH_DEVICE_IDENTITY_MISMATCH' "Expected SM-A022G/API30/armeabi-v7a; observed $model/API$api/$abi."
}

$dnsHarness = Join-Path $PSScriptRoot 'diagnose-dns-lifetime-live.ps1'
$deviceDiagnostic = Join-Path $PSScriptRoot 'collect-device-diagnostic.ps1'
$controlDiagnostic = Join-Path $PSScriptRoot 'collect-control-diagnostic.ps1'
foreach ($required in @($dnsHarness, $deviceDiagnostic, $controlDiagnostic)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Stop-MishCandidateA 'LAB_RESEARCH_REQUIRED_TOOL_MISSING' "Required existing LAB owner is missing: $required"
    }
}
Import-Module (Join-Path $PSScriptRoot 'PublicEgressObservation.psm1') -Force

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    Stop-MishCandidateA 'LAB_RESEARCH_TEMP_UNAVAILABLE' 'A temporary directory is unavailable.'
}
$beforeDevicePath = Join-Path $tempRoot 'mish-candidate-a-before-device.json'
$beforeControlPath = Join-Path $tempRoot 'mish-candidate-a-before-control.json'
$dnsEvidencePath = Join-Path $tempRoot 'mish-candidate-a-dns-owner.json'
$afterDevicePath = Join-Path $tempRoot 'mish-candidate-a-after-device.json'
$afterControlPath = Join-Path $tempRoot 'mish-candidate-a-after-control.json'

$publicContext = $null
$beforeAddress = $null
$afterAddress = $null
$fatal = $null
$pilotWatch = $null
$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'FAIL'
    classification = 'LAB_RESEARCH_CANDIDATE_A_NOT_COMPLETED'
    candidate = 'A_MOBILE_DATA_DETACH_ATTACH'
    mutation_owner = 'diagnose-dns-lifetime-live.ps1'
    cycles = 1
    product_install_performed = $false
    product_restart_performed = $false
    product_rotation_triggered = $false
    manager_command_issued = $false
    automatic_repeat = $false
    raw_public_ip_persisted = $false
    secrets_persisted_in_evidence = $false
    process = [ordered]@{ pid = $null; pid_stable = $false; runtime_generation = $null; runtime_generation_stable = $false }
    generation = [ordered]@{
        before_owner_sequence = $null
        after_owner_sequence = $null
        advanced = $false
        exact_root_authorized = $false
        readiness_bound_to_fresh_owner = $false
    }
    control_effect = [ordered]@{
        mobile_data_disable_requested = $false
        cellular_loss_observed = $false
        mobile_data_enable_requested = $false
        fresh_recovery_observed = $false
    }
    external_public_egress = [ordered]@{ observations = 0; outcome = 'FAILED' }
    before = [ordered]@{ product = 'UNKNOWN'; mesh_e2e = 'UNKNOWN'; control = 'UNKNOWN' }
    after = [ordered]@{ product = 'UNKNOWN'; mesh_e2e = 'UNKNOWN'; control = 'UNKNOWN' }
    timings_ms = [ordered]@{
        cellular_loss_to_recovery = $null
        disable_command = $null
        disable_start_to_loss = $null
        enable_command = $null
        enable_complete_to_first_reconcile = $null
        first_reconcile_to_fresh_cellular = $null
        fresh_cellular_to_root_authorized = $null
        root_authorized_to_readiness_ready = $null
        disable_start_to_readiness_ready = $null
        readiness_ready_to_public_egress_proof = $null
        primitive_start_to_functional_public_egress = $null
        existing_owner_harness_total = $null
        full_pilot = $null
    }
}

try {
    & $deviceDiagnostic -AdbPath $AdbPath -PackageName $PackageName -MeshCidr $MeshCidr -EvidencePath $beforeDevicePath | Out-Host
    $beforeDevice = Read-RequiredJson $beforeDevicePath 'LAB_RESEARCH_BASELINE_DIAGNOSTIC_MISSING'
    $evidence.before.product = [string]$beforeDevice.classification
    $evidence.before.mesh_e2e = [string]$beforeDevice.external.mesh_proxy_e2e.result
    if ($evidence.before.product -cne 'PASS' -or $evidence.before.mesh_e2e -cne 'PASS') {
        Stop-MishCandidateA 'LAB_RESEARCH_BASELINE_NOT_HEALTHY' 'Standard PRODUCT and Windows->Mesh E2E baseline must PASS before Candidate A.'
    }

    & $controlDiagnostic -AdbPath $AdbPath -PackageName $PackageName -EvidencePath $beforeControlPath | Out-Host
    $beforeControl = Read-RequiredJson $beforeControlPath 'LAB_RESEARCH_BASELINE_CONTROL_MISSING'
    $evidence.before.control = [string]$beforeControl.control.state
    if ($evidence.before.control -cne 'READY') {
        Stop-MishCandidateA 'LAB_RESEARCH_BASELINE_CONTROL_NOT_READY' 'CONTROL must be READY before Candidate A.'
    }

    $baseline = Read-MishSnapshot
    if (-not (Test-MishExactReadySnapshot $baseline) -or [int64]$baseline.rotation.active_tasks -ne 0) {
        Stop-MishCandidateA 'LAB_RESEARCH_BASELINE_SNAPSHOT_INVALID' 'Canonical baseline must be exact-generation READY with Rotation idle.'
    }
    $baselinePid = [int64]$baseline.pid
    $baselineRuntimeGeneration = [int64]$baseline.runtime.generation
    $baselineOwner = [int64]$baseline.cellular.owner_sequence
    $baselineRotationId = Convert-MishRotationOperationId $baseline.rotation.operation_id
    $evidence.process.pid = $baselinePid
    $evidence.process.runtime_generation = $baselineRuntimeGeneration
    $evidence.generation.before_owner_sequence = $baselineOwner

    $publicContext = New-MishPublicEgressObservationContext -AdbPath $AdbPath -PackageName $PackageName
    $beforePublic = Invoke-MishExternalPublicIpObservation -Context $publicContext -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $beforeAddress = [string]$beforePublic.Address
    $evidence.external_public_egress.observations = 1

    $pilotWatch = [Diagnostics.Stopwatch]::StartNew()
    $ownerWatch = [Diagnostics.Stopwatch]::StartNew()
    & $dnsHarness -AdbPath $AdbPath -PackageName $PackageName -EvidencePath $dnsEvidencePath -TimelineStopwatch $pilotWatch | Out-Host
    $ownerWatch.Stop()
    $evidence.timings_ms.existing_owner_harness_total = [int64]$ownerWatch.ElapsedMilliseconds

    $dns = Read-RequiredJson $dnsEvidencePath 'LAB_RESEARCH_OWNER_EVIDENCE_MISSING'
    if (
        [string]$dns.schema -cne 'mish.lab.dns-lifetime-live/v1' -or
        [string]$dns.acceptance_result -cne 'PASS' -or
        [string]$dns.classification -cne 'U3_DNS_LIFETIME_LIVE_OBSERVATION_COMPLETE' -or
        -not [bool]$dns.same_process -or
        [int]$dns.product_pid -ne $baselinePid -or
        -not [bool]$dns.control_effect.mobile_data_disable_requested -or
        -not [bool]$dns.control_effect.loss_observed -or
        -not [bool]$dns.control_effect.mobile_data_enable_requested -or
        -not [bool]$dns.control_effect.recovery_observed -or
        -not [bool]$dns.dns.owner_sequence_advanced -or
        [string]$dns.lab_effects.cellular_loss -cne 'adb shell cmd phone data disable/enable' -or
        [bool]$dns.lab_effects.cloudflare_app_mutated -or
        [bool]$dns.lab_effects.product_routes_or_iptables_mutated_by_lab -or
        [string]$dns.timing.clock -cne 'System.Diagnostics.Stopwatch' -or
        -not [bool]$dns.timing.shared_external_clock
    ) {
        Stop-MishCandidateA 'LAB_RESEARCH_OWNER_EVIDENCE_INVALID' 'Existing DNS-lifetime owner did not prove one bounded same-process data detach/attach recovery on the shared timing clock.'
    }

    $disableStart = [int64]$dns.timing.disable_start_ms
    $disableComplete = [int64]$dns.timing.disable_complete_ms
    $lossObserved = [int64]$dns.timing.loss_observed_ms
    $enableStart = [int64]$dns.timing.enable_start_ms
    $enableComplete = [int64]$dns.timing.enable_complete_ms
    $firstReconcile = [int64]$dns.timing.first_post_enable_reconcile_ms
    $freshCellular = [int64]$dns.timing.fresh_cellular_admitted_ms
    $rootAuthorized = [int64]$dns.timing.root_authorized_ms
    $readinessReady = [int64]$dns.timing.readiness_ready_ms
    if (
        $disableStart -lt 0 -or
        $disableComplete -lt $disableStart -or
        $lossObserved -lt $disableComplete -or
        $enableStart -lt $lossObserved -or
        $enableComplete -lt $enableStart -or
        $firstReconcile -lt $enableComplete -or
        $freshCellular -lt $firstReconcile -or
        $rootAuthorized -lt $freshCellular -or
        $readinessReady -lt $rootAuthorized
    ) {
        Stop-MishCandidateA 'LAB_RESEARCH_OWNER_TIMELINE_INVALID' 'Shared Candidate A timing milestones are missing or non-monotonic.'
    }

    $evidence.control_effect.mobile_data_disable_requested = $true
    $evidence.control_effect.cellular_loss_observed = $true
    $evidence.control_effect.mobile_data_enable_requested = $true
    $evidence.control_effect.fresh_recovery_observed = $true
    $lossElapsed = [int64]$dns.dns.loss.captured_elapsed_ms
    $recoveryElapsed = [int64]$dns.dns.recovery.captured_elapsed_ms
    if ($recoveryElapsed -lt $lossElapsed) {
        Stop-MishCandidateA 'LAB_RESEARCH_OWNER_TIMELINE_INVALID' 'Existing owner evidence has a non-monotonic Android loss/recovery timeline.'
    }
    $evidence.timings_ms.cellular_loss_to_recovery = $recoveryElapsed - $lossElapsed
    $evidence.timings_ms.disable_command = [int64]$dns.timing.intervals_ms.disable_command
    $evidence.timings_ms.disable_start_to_loss = [int64]$dns.timing.intervals_ms.disable_start_to_loss
    $evidence.timings_ms.enable_command = [int64]$dns.timing.intervals_ms.enable_command
    $evidence.timings_ms.enable_complete_to_first_reconcile = [int64]$dns.timing.intervals_ms.enable_complete_to_first_reconcile
    $evidence.timings_ms.first_reconcile_to_fresh_cellular = [int64]$dns.timing.intervals_ms.first_reconcile_to_fresh_cellular
    $evidence.timings_ms.fresh_cellular_to_root_authorized = [int64]$dns.timing.intervals_ms.fresh_cellular_to_root_authorized
    $evidence.timings_ms.root_authorized_to_readiness_ready = [int64]$dns.timing.intervals_ms.root_authorized_to_readiness_ready
    $evidence.timings_ms.disable_start_to_readiness_ready = [int64]$dns.timing.intervals_ms.disable_start_to_readiness_ready

    $afterPublic = Invoke-MishExternalPublicIpObservation -Context $publicContext -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $afterPublicProofMs = [int64]$pilotWatch.ElapsedMilliseconds
    $afterAddress = [string]$afterPublic.Address
    $evidence.external_public_egress.observations = 2
    $evidence.external_public_egress.outcome = if ($beforeAddress -cne $afterAddress) { 'CHANGED' } else { 'UNCHANGED' }
    if ($afterPublicProofMs -lt $readinessReady) {
        Stop-MishCandidateA 'LAB_RESEARCH_PUBLIC_EGRESS_TIMELINE_INVALID' 'Public-egress proof completed before the recorded readiness milestone.'
    }
    $evidence.timings_ms.readiness_ready_to_public_egress_proof = $afterPublicProofMs - $readinessReady
    $evidence.timings_ms.primitive_start_to_functional_public_egress = $afterPublicProofMs - $disableStart

    & $deviceDiagnostic -AdbPath $AdbPath -PackageName $PackageName -MeshCidr $MeshCidr -EvidencePath $afterDevicePath | Out-Host
    $afterDevice = Read-RequiredJson $afterDevicePath 'LAB_RESEARCH_POST_DIAGNOSTIC_MISSING'
    $evidence.after.product = [string]$afterDevice.classification
    $evidence.after.mesh_e2e = [string]$afterDevice.external.mesh_proxy_e2e.result
    if ($evidence.after.product -cne 'PASS' -or $evidence.after.mesh_e2e -cne 'PASS') {
        Stop-MishCandidateA 'LAB_RESEARCH_POST_MESH_NOT_HEALTHY' 'Standard PRODUCT and Windows->Mesh E2E postcondition must PASS.'
    }

    & $controlDiagnostic -AdbPath $AdbPath -PackageName $PackageName -EvidencePath $afterControlPath | Out-Host
    $afterControl = Read-RequiredJson $afterControlPath 'LAB_RESEARCH_POST_CONTROL_MISSING'
    $evidence.after.control = [string]$afterControl.control.state
    if ($evidence.after.control -cne 'READY') {
        Stop-MishCandidateA 'LAB_RESEARCH_POST_CONTROL_NOT_READY' 'CONTROL must be READY after Candidate A.'
    }

    $post = Read-MishSnapshot
    if (-not (Test-MishExactReadySnapshot $post)) {
        Stop-MishCandidateA 'LAB_RESEARCH_POST_SNAPSHOT_INVALID' 'Canonical postcondition is not exact-generation READY.'
    }
    $postOwner = [int64]$post.cellular.owner_sequence
    if (
        [int64]$post.pid -ne $baselinePid -or
        [int64]$post.runtime.generation -ne $baselineRuntimeGeneration -or
        $postOwner -le $baselineOwner -or
        [int64]$post.root.policy_authorized_generation -ne $postOwner -or
        [int64]$post.readiness.binding.cellular_owner_generation -ne $postOwner -or
        [int64]$post.rotation.active_tasks -ne 0 -or
        (Convert-MishRotationOperationId $post.rotation.operation_id) -cne $baselineRotationId
    ) {
        Stop-MishCandidateA 'LAB_RESEARCH_POST_GENERATION_INVALID' 'Candidate A did not end on one strictly fresh exact-authorized owner generation in the same PRODUCT runtime with Rotation untouched.'
    }

    $evidence.process.pid_stable = $true
    $evidence.process.runtime_generation_stable = $true
    $evidence.generation.after_owner_sequence = $postOwner
    $evidence.generation.advanced = $true
    $evidence.generation.exact_root_authorized = $true
    $evidence.generation.readiness_bound_to_fresh_owner = $true
    $evidence.product_rotation_triggered = $false
    $pilotWatch.Stop()
    $evidence.timings_ms.full_pilot = [int64]$pilotWatch.ElapsedMilliseconds
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
        $evidence.classification = [string]$Matches[1]
    } else {
        $evidence.classification = 'LAB_RESEARCH_CANDIDATE_A_UNEXPECTED_FAILURE'
    }
}
finally {
    if ($null -ne $pilotWatch -and $pilotWatch.IsRunning) { $pilotWatch.Stop() }
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
    Write-Host 'MISH_CANDIDATE_A_MUTATION_OWNER=diagnose-dns-lifetime-live.ps1'
    Write-Host 'MISH_CANDIDATE_A_RAW_IP_PERSISTED=false'
    Write-Host "MISH_CANDIDATE_A_EVIDENCE=$fullPath"
}

if ($null -ne $fatal) { throw $fatal }