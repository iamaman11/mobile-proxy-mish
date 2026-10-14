[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [ValidateRange(10, 60)][int] $RotationTimeoutSeconds = 30,
    [ValidateRange(5, 30)][int] $ExternalProbeTimeoutSeconds = 15,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8-public-egress-rotation-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.u8-public-egress-rotation/v1'
$script:SnapshotMethod = 'snapshot_v2'
$script:ControlSnapshotMethod = 'control_snapshot_v1'
$script:RotationComponent = "$PackageName/com.mobileproxymish.app.DebugRotationActivity"
$script:PollMilliseconds = 100
$script:Evidence = $null

# Protected-main delivery guard migration markers. These names are deliberately non-executable;
# test-u8-public-egress-rotation-probe-contract.ps1 forbids the retired delegation itself.
# diagnose-u5-rotation.ps1
# -SuccessfulOperations 1
# -SkipShutdownRestoreAfterOn

function Write-MishEvidence {
    if ($null -eq $script:Evidence) { return }
    $full = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $full
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $full,
        (($script:Evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "MISH_U8_PUBLIC_EGRESS_EVIDENCE=$full"
}

function Stop-MishU8PublicEgress {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    if ($null -ne $script:Evidence) {
        $script:Evidence.acceptance_result = 'FAIL'
        $script:Evidence.classification = $Classification
        Write-MishEvidence
    }
    throw "MISH_U8_PUBLIC_EGRESS_FAILURE|$Classification|$Message"
}

function Invoke-MishAdbCapture {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Operation
    )
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Text = ($rows -join [Environment]::NewLine).Trim()
        Operation = $Operation
    }
}

function ConvertFrom-MishPayload {
    param(
        [Parameter(Mandatory)][string] $Text,
        [Parameter(Mandatory)][string] $ExpectedSchema
    )
    $payloadMatch = [regex]::Match($Text, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $payloadMatch.Success) {
        Stop-MishU8PublicEgress 'PRODUCT_SNAPSHOT_INVALID' 'Diagnostics bridge returned no payload.'
    }

    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
        $snapshot = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch {
        Stop-MishU8PublicEgress 'PRODUCT_SNAPSHOT_INVALID' 'Diagnostics payload is malformed.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }

    if ([string]$snapshot.schema -cne $ExpectedSchema -or
        [string]$snapshot.application_id -cne $PackageName) {
        Stop-MishU8PublicEgress 'PRODUCT_SNAPSHOT_IDENTITY_MISMATCH' 'Diagnostics schema/package identity mismatch.'
    }
    return $snapshot
}

function Get-MishProductSnapshot {
    $capture = Invoke-MishAdbCapture -Operation 'snapshot_v2' -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    )
    if ($capture.ExitCode -ne 0) {
        Stop-MishU8PublicEgress 'PRODUCT_SNAPSHOT_FAILED' 'PRODUCT snapshot call failed.'
    }
    $snapshot = ConvertFrom-MishPayload -Text $capture.Text -ExpectedSchema 'mish.diagnostics/v2'
    if (-not [bool]$snapshot.consistent) {
        Stop-MishU8PublicEgress 'PRODUCT_SNAPSHOT_INCONSISTENT' 'PRODUCT snapshot is not atomic/consistent.'
    }
    return $snapshot
}

function Get-MishControlSnapshot {
    $capture = Invoke-MishAdbCapture -Operation 'control_snapshot_v1' -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:ControlSnapshotMethod
    )
    if ($capture.ExitCode -ne 0) {
        Stop-MishU8PublicEgress 'CONTROL_SNAPSHOT_FAILED' 'DUMP-only control snapshot call failed.'
    }
    return (ConvertFrom-MishPayload -Text $capture.Text -ExpectedSchema 'mish.control.diagnostics/v1')
}

function Get-MishOptionalInt64 {
    param($Value)
    if ($null -eq $Value) { return $null }
    return [int64]$Value
}

function Assert-MishReady {
    param([Parameter(Mandatory)] $Snapshot)

    $owner = Get-MishOptionalInt64 $Snapshot.cellular.owner_sequence
    $rootGeneration = Get-MishOptionalInt64 $Snapshot.root.policy_authorized_generation
    if (-not [bool]$Snapshot.runtime.running -or
        -not [bool]$Snapshot.cellular.admitted -or
        $null -eq $owner -or
        -not [bool]$Snapshot.root.policy_authorized -or
        $rootGeneration -ne $owner -or
        [string]$Snapshot.proxy.state -cne 'RUNNING' -or
        -not [bool]$Snapshot.proxy.healthy -or
        -not [bool]$Snapshot.mesh.admitted -or
        -not [bool]$Snapshot.mesh.ingress_running -or
        [string]$Snapshot.readiness.state -cne 'READY' -or
        -not [bool]$Snapshot.credential.active) {
        Stop-MishU8PublicEgress 'PRODUCT_NOT_READY' 'Candidate A acceptance requires READY Cellular/root/Proxy/Mesh/readiness/credential state.'
    }
    if ([bool]$Snapshot.rotation.raw_ip_persisted) {
        Stop-MishU8PublicEgress 'PRODUCT_RAW_IP_PERSISTED' 'PRODUCT diagnostics reported raw public-IP persistence.'
    }
    return $owner
}

function Get-MishRotationTiming {
    param(
        [Parameter(Mandatory)][int64] $OperationId,
        [Parameter(Mandatory)][int64] $AfterGeneration
    )

    $control = Get-MishControlSnapshot
    $timing = $control.control.operation_timing.rotation
    if ($null -eq $timing -or
        $null -eq $timing.operation_id -or
        [int64]$timing.operation_id -ne $OperationId) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_TIMING_MISMATCH' 'Rotation timing is not correlated to the completed local PRODUCT operation.'
    }

    foreach ($field in @(
        'activated_ms',
        'pre_rotation_probe_started_ms',
        'pre_rotation_probe_completed_ms',
        'mobile_data_precondition_observed_ms',
        'data_disable_started_ms',
        'data_disable_effect_completed_ms',
        'cellular_loss_observed_ms',
        'data_enable_started_ms',
        'data_enable_effect_completed_ms',
        'fresh_cellular_observed_ms',
        'fresh_cellular_generation',
        'root_authorized_ms',
        'root_authorized_generation',
        'post_rotation_probe_started_ms',
        'post_rotation_probe_completed_ms',
        'terminal_ms'
    )) {
        if ($null -eq $timing.$field -or [int64]$timing.$field -lt 0) {
            Stop-MishU8PublicEgress 'PRODUCT_ROTATION_TIMING_INCOMPLETE' "Missing/invalid Candidate A timing field: $field."
        }
    }

    if ($timing.mobile_data_precondition_enabled -ne $true) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_PRECONDITION_INVALID' 'Candidate A requires authoritative mobile-data ENABLED precondition.'
    }
    if ([int64]$timing.fresh_cellular_generation -ne $AfterGeneration -or
        [int64]$timing.root_authorized_generation -ne $AfterGeneration) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_GENERATION_MISMATCH' 'Fresh Cellular, root authorization and terminal generation are not exact.'
    }

    # Preserve only causal ordering owned by Candidate A. There is deliberately no dwell/sleep gate.
    if ([int64]$timing.activated_ms -gt [int64]$timing.pre_rotation_probe_started_ms -or
        [int64]$timing.pre_rotation_probe_started_ms -gt [int64]$timing.pre_rotation_probe_completed_ms -or
        [int64]$timing.pre_rotation_probe_completed_ms -gt [int64]$timing.mobile_data_precondition_observed_ms -or
        [int64]$timing.mobile_data_precondition_observed_ms -gt [int64]$timing.data_disable_started_ms -or
        [int64]$timing.data_disable_started_ms -gt [int64]$timing.data_disable_effect_completed_ms -or
        [int64]$timing.data_disable_started_ms -gt [int64]$timing.cellular_loss_observed_ms -or
        [int64]$timing.data_disable_effect_completed_ms -gt [int64]$timing.data_enable_started_ms -or
        [int64]$timing.cellular_loss_observed_ms -gt [int64]$timing.data_enable_started_ms -or
        [int64]$timing.data_enable_started_ms -gt [int64]$timing.data_enable_effect_completed_ms -or
        [int64]$timing.data_enable_effect_completed_ms -gt [int64]$timing.post_rotation_probe_started_ms -or
        [int64]$timing.fresh_cellular_observed_ms -gt [int64]$timing.post_rotation_probe_started_ms -or
        [int64]$timing.root_authorized_ms -gt [int64]$timing.post_rotation_probe_started_ms -or
        [int64]$timing.post_rotation_probe_started_ms -gt [int64]$timing.post_rotation_probe_completed_ms -or
        [int64]$timing.post_rotation_probe_completed_ms -gt [int64]$timing.terminal_ms) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_TIMING_ORDER_INVALID' 'Candidate A timing violates event-driven detach/attach ordering.'
    }

    return $timing
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    throw 'MISH_U8_PUBLIC_EGRESS_FAILURE|LAB_ADB_MISSING|Canonical ADB executable is unavailable.'
}

Import-Module (Join-Path $PSScriptRoot 'PublicEgressObservation.psm1') -Force

$observationContext = $null
$beforeAddress = $null
$afterAddress = $null
$script:Evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'FAIL'
    classification = 'LAB_U8_PUBLIC_EGRESS_UNCLASSIFIED'
    endpoint_host = 'checkip.amazonaws.com'
    path = 'local_PRODUCT_rotation_plus_authenticated_proxy_observer'
    rotation_requests = 1
    product_terminal_result = $null
    product_operation_id = $null
    generation_a = $null
    generation_b = $null
    external_outcome = 'FAILED'
    observer_consensus = $false
    timings = $null
    raw_ip_persisted = $false
    secrets_persisted_in_evidence = $false
}

try {
    $baseline = Get-MishProductSnapshot
    $generationA = Assert-MishReady -Snapshot $baseline
    if ([int64]$baseline.rotation.active_tasks -ne 0) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_BUSY' 'A Rotation task is already active before the single acceptance request.'
    }
    $baselineOperationId = Get-MishOptionalInt64 $baseline.rotation.operation_id
    $script:Evidence.generation_a = $generationA

    $observationContext = New-MishPublicEgressObservationContext `
        -AdbPath $AdbPath `
        -PackageName $PackageName
    $before = Invoke-MishExternalPublicIpObservation `
        -Context $observationContext `
        -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $beforeAddress = [string]$before.Address

    # Exactly one local PRODUCT request. This is the same Rust-owned operation used by the UI.
    $trigger = Invoke-MishAdbCapture -Operation 'start_public_ip_rotation' -Arguments @(
        'shell', 'am', 'start', '-n', $script:RotationComponent
    )
    if ($trigger.ExitCode -ne 0 -or
        $trigger.Text -match '(?im)^\s*(Error|Exception):' -or
        $trigger.Text -notmatch '(?im)^\s*Starting: Intent') {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_TRIGGER_FAILED' 'Debug PRODUCT rotation trigger was not accepted.'
    }

    $operationId = $null
    $terminalSnapshot = $null
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $RotationTimeoutSeconds) {
        $snapshot = Get-MishProductSnapshot
        $currentOperationId = Get-MishOptionalInt64 $snapshot.rotation.operation_id
        if ($null -ne $currentOperationId -and
            ($null -eq $baselineOperationId -or $currentOperationId -ne $baselineOperationId)) {
            if ($null -eq $operationId) { $operationId = $currentOperationId }
            if ($currentOperationId -ne $operationId) {
                Stop-MishU8PublicEgress 'PRODUCT_ROTATION_OPERATION_CHANGED' 'More than one PRODUCT Rotation operation appeared during bounded acceptance.'
            }
            if ([string]$snapshot.rotation.state -ceq 'FAILED') {
                Stop-MishU8PublicEgress 'PRODUCT_ROTATION_FAILED' ("Rotation failed: " + [string]$snapshot.rotation.failure)
            }
            if ($null -ne $snapshot.rotation.terminal_result) {
                $terminalSnapshot = $snapshot
                break
            }
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }
    $watch.Stop()

    if ($null -eq $terminalSnapshot -or $null -eq $operationId) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_DEADLINE' 'The single PRODUCT Rotation did not reach a terminal state within the bounded deadline.'
    }

    $terminal = [string]$terminalSnapshot.rotation.terminal_result
    if ($terminal -notin @('CHANGED', 'UNCHANGED')) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_TERMINAL_INVALID' 'PRODUCT terminal result is not CHANGED/UNCHANGED.'
    }
    $generationB = Get-MishOptionalInt64 $terminalSnapshot.rotation.after_generation
    if ($null -eq $generationB -or $generationB -le $generationA) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_GENERATION_NOT_FRESH' 'Rotation did not publish a strictly fresh Cellular generation.'
    }
    [void](Assert-MishReady -Snapshot $terminalSnapshot)
    if ([int64]$terminalSnapshot.cellular.owner_sequence -ne $generationB -or
        [int64]$terminalSnapshot.root.policy_authorized_generation -ne $generationB) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_POST_STATE_MISMATCH' 'Terminal Cellular/root state is not bound to the fresh Rotation generation.'
    }

    $rotationTiming = Get-MishRotationTiming -OperationId $operationId -AfterGeneration $generationB

    $after = Invoke-MishExternalPublicIpObservation `
        -Context $observationContext `
        -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $afterAddress = [string]$after.Address
    $externalOutcome = if ($beforeAddress -cne $afterAddress) { 'CHANGED' } else { 'UNCHANGED' }
    $consensus = $terminal -ceq $externalOutcome

    $script:Evidence.product_terminal_result = $terminal
    $script:Evidence.product_operation_id = $operationId
    $script:Evidence.generation_b = $generationB
    $script:Evidence.external_outcome = $externalOutcome
    $script:Evidence.observer_consensus = $consensus
    $script:Evidence.timings = [ordered]@{
        external_before_ms = [int64]$before.ElapsedMs
        external_after_ms = [int64]$after.ElapsedMs
        observed_total_rotation_ms = [int64]$watch.ElapsedMilliseconds
        activated_ms = [int64]$rotationTiming.activated_ms
        pre_rotation_probe_started_ms = [int64]$rotationTiming.pre_rotation_probe_started_ms
        pre_rotation_probe_completed_ms = [int64]$rotationTiming.pre_rotation_probe_completed_ms
        mobile_data_precondition_observed_ms = [int64]$rotationTiming.mobile_data_precondition_observed_ms
        mobile_data_precondition_enabled = [bool]$rotationTiming.mobile_data_precondition_enabled
        data_disable_started_ms = [int64]$rotationTiming.data_disable_started_ms
        data_disable_effect_completed_ms = [int64]$rotationTiming.data_disable_effect_completed_ms
        cellular_loss_observed_ms = [int64]$rotationTiming.cellular_loss_observed_ms
        data_enable_started_ms = [int64]$rotationTiming.data_enable_started_ms
        data_enable_effect_completed_ms = [int64]$rotationTiming.data_enable_effect_completed_ms
        fresh_cellular_observed_ms = [int64]$rotationTiming.fresh_cellular_observed_ms
        fresh_cellular_generation = [int64]$rotationTiming.fresh_cellular_generation
        root_authorized_ms = [int64]$rotationTiming.root_authorized_ms
        root_authorized_generation = [int64]$rotationTiming.root_authorized_generation
        post_rotation_probe_started_ms = [int64]$rotationTiming.post_rotation_probe_started_ms
        post_rotation_probe_completed_ms = [int64]$rotationTiming.post_rotation_probe_completed_ms
        terminal_ms = [int64]$rotationTiming.terminal_ms
    }

    if (-not $consensus) {
        Stop-MishU8PublicEgress 'PRODUCT_EXTERNAL_EGRESS_RESULT_MISMATCH' 'Independent public-egress observation disagrees with the PRODUCT terminal result.'
    }
    if ($terminal -cne 'CHANGED' -or $externalOutcome -cne 'CHANGED') {
        Stop-MishU8PublicEgress 'PRODUCT_IP_NOT_CHANGED' 'Candidate A promotion requires one real CHANGED result; UNCHANGED is evidence, not acceptance.'
    }

    $script:Evidence.acceptance_result = 'PASS'
    $script:Evidence.classification = 'U8_PUBLIC_EGRESS_ROTATION_PASS'
    Write-MishEvidence
    Write-Host 'MISH_U8_PUBLIC_EGRESS_ACCEPTANCE=PASS'
    Write-Host 'MISH_U8_PUBLIC_EGRESS_OUTCOME=CHANGED'
    Write-Host "MISH_U8_PUBLIC_EGRESS_GENERATION=$generationA->$generationB"
    Write-Host "MISH_U8_PUBLIC_EGRESS_MOBILE_DATA=PASS/disable_ms=$([int64]$rotationTiming.data_disable_started_ms)/loss_ms=$([int64]$rotationTiming.cellular_loss_observed_ms)/enable_ms=$([int64]$rotationTiming.data_enable_started_ms)/terminal_ms=$([int64]$rotationTiming.terminal_ms)"
    Write-Host 'MISH_U8_PUBLIC_EGRESS_OBSERVER_CONSENSUS=true'
    Write-Host 'MISH_U8_PUBLIC_EGRESS_RAW_IP_PERSISTED=false'
}
finally {
    $beforeAddress = $null
    $afterAddress = $null
    Close-MishPublicEgressObservationContext -Context $observationContext
    $observationContext = $null
}
