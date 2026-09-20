[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u7-512-lifecycle-stability-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Schema = 'mish.lab.u7-512-lifecycle-stability/v1'
$script:SnapshotMethod = 'snapshot_v2'

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = @(& $AdbPath @Arguments 2>$null | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "MISH_U7_512_LIFECYCLE_FAILURE|LAB_ADB_FAILED|ADB exited with code $exitCode."
    }
    return ($output -join "`n").Trim()
}

function Get-MishProductPid {
    $value = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
    if ([string]::IsNullOrWhiteSpace($value) -or $value -match '\s') {
        throw 'MISH_U7_512_LIFECYCLE_FAILURE|PRODUCT_PROCESS_IDENTITY_INVALID|Exactly one PRODUCT process is required.'
    }
    return [int]$value
}

function Get-MishSnapshot {
    $output = Invoke-MishAdbText -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    )
    $match = [regex]::Match($output, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) {
        throw 'MISH_U7_512_LIFECYCLE_FAILURE|LAB_SNAPSHOT_INVALID|Android diagnostics returned no payload.'
    }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-MishFailureClassification {
    param(
        [Parameter(Mandatory)][Exception] $Exception,
        [Parameter(Mandatory)][string] $Fallback
    )
    $match = [regex]::Match($Exception.Message, 'MISH_[A-Z0-9_]+_FAILURE\|(?<classification>[A-Z0-9_]+)\|')
    if ($match.Success) { return [string]$match.Groups['classification'].Value }
    return $Fallback
}

function Get-MishRestartSnapshotSummary {
    param($Snapshot)
    if ($null -eq $Snapshot) { return $null }
    return [ordered]@{
        runtime_running = [bool]$Snapshot.runtime.running
        runtime_generation = [int64]$Snapshot.runtime.generation
        cellular_admitted = [bool]$Snapshot.cellular.admitted
        cellular_owner_sequence = if ($null -ne $Snapshot.cellular.owner_sequence) { [int64]$Snapshot.cellular.owner_sequence } else { $null }
        cellular_reconcile_pending = [bool]$Snapshot.cellular.reconcile.pending
        cellular_reconcile_requested = [int64]$Snapshot.cellular.reconcile.requested
        cellular_reconcile_executed = [int64]$Snapshot.cellular.reconcile.executed
        root_policy_authorized = [bool]$Snapshot.root.policy_authorized
        root_policy_authorized_generation = if ($null -ne $Snapshot.root.policy_authorized_generation) { [int64]$Snapshot.root.policy_authorized_generation } else { $null }
        root_recovery_pending = [bool]$Snapshot.root.recovery.pending
        readiness_state = [string]$Snapshot.readiness.state
        readiness_binding_eligible = [bool]$Snapshot.readiness.binding_eligible
        readiness_probe_state = [string]$Snapshot.readiness.probe_state
        mesh_admitted = [bool]$Snapshot.mesh.admitted
        mesh_ingress_running = [bool]$Snapshot.mesh.ingress_running
        rotation_state = [string]$Snapshot.rotation.state
        rotation_active_tasks = [int64]$Snapshot.rotation.active_tasks
        credential_active = [bool]$Snapshot.credential.active
        credential_version = if ($null -ne $Snapshot.credential.version) { [int64]$Snapshot.credential.version } else { $null }
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    throw 'MISH_U7_512_LIFECYCLE_FAILURE|LAB_ADB_MISSING|Canonical ADB executable is unavailable.'
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
$capacityEvidencePath = Join-Path $tempRoot 'mish-u7-repeated-512-capacity-v1.json'
$rotationEvidencePath = Join-Path $tempRoot 'mish-u7-repeated-512-rotation-v1.json'

$initialPid = Get-MishProductPid
$capacityError = $null
$rotationError = $null
$capacity = $null
$rotation = $null
$postFailureSnapshot = $null
$afterCapacityPid = $null
$finalPid = $null

try {
    try {
        & (Join-Path $PSScriptRoot 'diagnose-capacity-resources.ps1') `
            -AdbPath $AdbPath `
            -PackageName $PackageName `
            -Capacity512Cycles 3 `
            -EvidencePath $capacityEvidencePath
    }
    catch {
        $capacityError = $_.Exception
    }

    if (Test-Path -LiteralPath $capacityEvidencePath -PathType Leaf) {
        $capacity = Get-Content -Raw -LiteralPath $capacityEvidencePath | ConvertFrom-Json
    }
    $afterCapacityPid = Get-MishProductPid

    if ($null -eq $capacityError -and $null -ne $capacity -and [string]$capacity.acceptance_result -ceq 'PASS') {
        try {
            & (Join-Path $PSScriptRoot 'diagnose-u5-rotation.ps1') `
                -AdbPath $AdbPath `
                -PackageName $PackageName `
                -SuccessfulOperations 3 `
                -EvidencePath $rotationEvidencePath
        }
        catch {
            $rotationError = $_.Exception
            try { $postFailureSnapshot = Get-MishSnapshot } catch {}
        }
        if (Test-Path -LiteralPath $rotationEvidencePath -PathType Leaf) {
            $rotation = Get-Content -Raw -LiteralPath $rotationEvidencePath | ConvertFrom-Json
        }
    }
}
finally {
    try { $finalPid = Get-MishProductPid } catch {}
}

$capacityPass = (
    $null -eq $capacityError -and
    $null -ne $capacity -and
    [string]$capacity.acceptance_result -ceq 'PASS' -and
    [string]$capacity.classification -ceq 'U7_CAPACITY_512_REPEAT_PASS' -and
    [int]$capacity.capacity_512_cycles_requested -eq 3 -and
    [int]$capacity.capacity_512_cycles_completed -eq 3
)

$rotationPass = (
    $null -eq $rotationError -and
    $null -ne $rotation -and
    [string]$rotation.acceptance_result -ceq 'PASS' -and
    [int]$rotation.successful_operations.Count -eq 3
)

$restore = if ($null -ne $rotation) { $rotation.shutdown_restore_after_on } else { $null }
$restartState = if ($null -ne $restore -and $restore.PSObject.Properties.Name -contains 'restart_state') { $restore.restart_state } else { $null }
$restartReachedProduct = (
    $null -ne $restartState -and
    [bool]$restartState.runtime_running -and
    [int64]$restartState.cellular_reconcile_requested -gt 0 -and
    [int64]$restartState.cellular_reconcile_executed -eq [int64]$restartState.cellular_reconcile_requested -and
    -not [bool]$restartState.cellular_reconcile_pending -and
    [bool]$restartState.root_policy_authorized -and
    -not [bool]$restartState.root_recovery_pending -and
    [string]$restartState.readiness_state -ceq 'READY' -and
    [bool]$restartState.mesh_admitted -and
    [bool]$restartState.mesh_ingress_running
)
$stopOnRestorePass = (
    $null -ne $restore -and
    [bool]$restore.airplane_on_observed -and
    [bool]$restore.stop_requested_after_on -and
    [bool]$restore.runtime_stopped_observed -and
    [bool]$restore.runtime_credential_cleared -and
    [bool]$restore.restore_off_observed -and
    [bool]$restore.restart_process_stable -and
    [bool]$restore.runtime_restarted_ready -and
    $restartReachedProduct
)

$pidStable = (
    $null -ne $afterCapacityPid -and
    $null -ne $finalPid -and
    [int]$initialPid -eq [int]$afterCapacityPid -and
    [int]$initialPid -eq [int]$finalPid
)

$capacity512Stages = @()
if ($null -ne $capacity) {
    $capacity512Stages = @($capacity.stages | Where-Object { [string]$_.name -like 'sessions_512*' })
}
$cleanupRss = @($capacity512Stages | ForEach-Object { [int64]$_.cleanup.resources.rss_kb })
$cleanupPss = @($capacity512Stages | ForEach-Object { [int64]$_.cleanup.resources.pss_kb })
$cleanupFd = @($capacity512Stages | ForEach-Object { [int]$_.cleanup.resources.fd_count })
$cleanupThreads = @($capacity512Stages | ForEach-Object { [int]$_.cleanup.resources.threads })

$acceptance = $capacityPass -and $rotationPass -and $stopOnRestorePass -and $pidStable
$classification = if ($acceptance) {
    'U7_512_LIFECYCLE_STABILITY_PASS'
}
elseif (-not $capacityPass) {
    if ($null -ne $capacityError) { Get-MishFailureClassification -Exception $capacityError -Fallback 'PRODUCT_REPEATED_512_FAILED' }
    else { 'PRODUCT_REPEATED_512_FAILED' }
}
elseif (-not $rotationPass) {
    if ($null -ne $rotationError) { Get-MishFailureClassification -Exception $rotationError -Fallback 'PRODUCT_ROTATION_OR_RESTART_FAILED' }
    else { 'PRODUCT_ROTATION_OR_RESTART_FAILED' }
}
elseif (-not $stopOnRestorePass) {
    'PRODUCT_STOP_ON_RESTART_DID_NOT_REACH_PRODUCT'
}
else {
    'INVALID_PROCESS_CHANGED_DURING_U7_STABILITY'
}

$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = if ($acceptance) { 'PASS' } else { 'FAIL' }
    classification = $classification
    product_pid = [ordered]@{
        initial = $initialPid
        after_repeated_512 = $afterCapacityPid
        final = $finalPid
        stable = $pidStable
    }
    repeated_512 = [ordered]@{
        acceptance_result = if ($null -ne $capacity) { [string]$capacity.acceptance_result } else { 'MISSING' }
        classification = if ($null -ne $capacity) { [string]$capacity.classification } else { 'MISSING' }
        cycles_requested = 3
        cycles_completed = if ($null -ne $capacity) { [int]$capacity.capacity_512_cycles_completed } else { 0 }
        cleanup_rss_kb = @($cleanupRss)
        cleanup_pss_kb = @($cleanupPss)
        cleanup_fd_count = @($cleanupFd)
        cleanup_threads = @($cleanupThreads)
        rss_last_minus_first_kb = if ($cleanupRss.Count -eq 3) { [int64]$cleanupRss[2] - [int64]$cleanupRss[0] } else { $null }
        pss_last_minus_first_kb = if ($cleanupPss.Count -eq 3) { [int64]$cleanupPss[2] - [int64]$cleanupPss[0] } else { $null }
        memory_trend_is_observational = $true
        no_leak_claim_from_three_samples = $true
        evidence = $capacity
    }
    rotation_and_stop_on = [ordered]@{
        acceptance_result = if ($null -ne $rotation) { [string]$rotation.acceptance_result } else { 'MISSING' }
        classification = if ($null -ne $rotation) { [string]$rotation.classification } else { 'MISSING' }
        normal_rotations_requested = 3
        normal_rotations_completed = if ($null -ne $rotation) { [int]$rotation.successful_operations.Count } else { 0 }
        stop_during_airplane_on = $restore
        restart_reached_product = $restartReachedProduct
        post_failure_snapshot = Get-MishRestartSnapshotSummary -Snapshot $postFailureSnapshot
        evidence = $rotation
    }
}

[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 24) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_U7_512_LIFECYCLE_ACCEPTANCE=$([string]$evidence.acceptance_result)"
Write-Host "MISH_U7_512_LIFECYCLE_CLASSIFICATION=$classification"
Write-Host "MISH_U7_512_LIFECYCLE_PID_STABLE=$pidStable"
Write-Host "MISH_U7_512_LIFECYCLE_RESTART_REACHED_PRODUCT=$restartReachedProduct"
Write-Host "MISH_U7_512_LIFECYCLE_EVIDENCE=$fullEvidencePath"

if (-not $acceptance) {
    throw "MISH_U7_512_LIFECYCLE_FAILURE|$classification|Combined repeated-512 and stop-during-ON lifecycle acceptance failed."
}
