[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [ValidateRange(5, 30)][int] $ExternalProbeTimeoutSeconds = 15,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8-public-egress-rotation-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.u8-public-egress-rotation/v1'
$script:Endpoint = 'https://checkip.amazonaws.com/'

function Stop-MishU8PublicEgress {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_U8_PUBLIC_EGRESS_FAILURE|$Classification|$Message"
}

function Write-MishEvidence {
    param([Parameter(Mandatory)] $Evidence)
    $full = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $full
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $full,
        (($Evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "MISH_U8_PUBLIC_EGRESS_EVIDENCE=$full"
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishU8PublicEgress 'LAB_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

Import-Module (Join-Path $PSScriptRoot 'PublicEgressObservation.psm1') -Force

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
$rotationEvidencePath = Join-Path $tempRoot ('mish-u8-egress-inner-rotation-' + [Guid]::NewGuid().ToString('N') + '.json')
$observationContext = $null
$beforeAddress = $null
$afterAddress = $null
$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'FAIL'
    classification = 'LAB_U8_PUBLIC_EGRESS_UNCLASSIFIED'
    endpoint_host = 'checkip.amazonaws.com'
    path = 'authenticated_PRODUCT_proxy_via_bounded_adb_forward'
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
    $observationContext = New-MishPublicEgressObservationContext `
        -AdbPath $AdbPath `
        -PackageName $PackageName
    $before = Invoke-MishExternalPublicIpObservation `
        -Context $observationContext `
        -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $beforeAddress = [string]$before.Address

    $rotationError = $null
    try {
        & (Join-Path $PSScriptRoot 'diagnose-u5-rotation.ps1') `
            -AdbPath $AdbPath `
            -PackageName $PackageName `
            -SuccessfulOperations 1 `
            -SkipShutdownRestoreAfterOn `
            -EvidencePath $rotationEvidencePath
    }
    catch {
        $rotationError = [string]$_
    }

    $rotationEvidence = if (Test-Path -LiteralPath $rotationEvidencePath -PathType Leaf) {
        Get-Content -Raw -LiteralPath $rotationEvidencePath | ConvertFrom-Json
    } else {
        $null
    }
    if ($null -eq $rotationEvidence) {
        Stop-MishU8PublicEgress 'LAB_INNER_ROTATION_EVIDENCE_MISSING' 'Single-rotation evidence was not produced.'
    }
    if ($null -ne $rotationError -or [string]$rotationEvidence.acceptance_result -cne 'PASS') {
        $innerClass = [string]$rotationEvidence.classification
        if ($innerClass -notmatch '^[A-Z0-9_]+$') { $innerClass = 'PRODUCT_ROTATION_FAILED' }
        $evidence.classification = $innerClass
        $evidence.product_terminal_result = 'FAILED'
        Write-MishEvidence -Evidence $evidence
        Stop-MishU8PublicEgress $innerClass 'The existing PRODUCT rotation owner did not complete the bounded single-operation contract.'
    }

    $operation = @($rotationEvidence.successful_operations)[0]
    if ($null -eq $operation) {
        Stop-MishU8PublicEgress 'LAB_INNER_ROTATION_EVIDENCE_INVALID' 'Single-rotation evidence contains no operation.'
    }
    $terminal = [string]$operation.terminal_result
    if ($terminal -notin @('CHANGED', 'UNCHANGED')) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_TERMINAL_INVALID' 'PRODUCT terminal result is not CHANGED or UNCHANGED.'
    }

    $after = Invoke-MishExternalPublicIpObservation `
        -Context $observationContext `
        -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $afterAddress = [string]$after.Address
    $externalChanged = $beforeAddress -cne $afterAddress
    $externalOutcome = if ($externalChanged) { 'CHANGED' } else { 'UNCHANGED' }
    $consensus = $terminal -ceq $externalOutcome

    $evidence.product_terminal_result = $terminal
    $evidence.product_operation_id = [int64]$operation.operation_id
    $evidence.generation_a = [int64]$operation.generation_a
    $evidence.generation_b = [int64]$operation.generation_b
    $evidence.external_outcome = $externalOutcome
    $evidence.observer_consensus = $consensus
    $evidence.timings = [ordered]@{
        external_before_ms = [int64]$before.ElapsedMs
        external_after_ms = [int64]$after.ElapsedMs
        request_to_airplane_on_ms = [int64]$operation.timings.request_to_airplane_on_ms
        request_to_cellular_loss_ms = [int64]$operation.timings.request_to_cellular_loss_ms
        off_to_fresh_owner_ms = [int64]$operation.timings.off_to_fresh_owner_ms
        off_to_root_policy_authorized_ms = [int64]$operation.timings.off_to_root_policy_authorized_ms
        off_to_readiness_ready_ms = [int64]$operation.timings.off_to_readiness_ready_ms
        off_to_functional_public_ip_ms = [int64]$operation.timings.off_to_functional_public_ip_ms
        total_rotation_ms = [int64]$operation.timings.total_rotation_ms
    }

    if (-not $consensus) {
        $evidence.classification = 'PRODUCT_EXTERNAL_EGRESS_RESULT_MISMATCH'
        Write-MishEvidence -Evidence $evidence
        Stop-MishU8PublicEgress $evidence.classification 'External proxy-observed public egress disagrees with the PRODUCT rotation terminal result.'
    }

    $evidence.acceptance_result = 'PASS'
    $evidence.classification = 'U8_PUBLIC_EGRESS_ROTATION_PASS'
    Write-MishEvidence -Evidence $evidence
    Write-Host 'MISH_U8_PUBLIC_EGRESS_ACCEPTANCE=PASS'
    Write-Host "MISH_U8_PUBLIC_EGRESS_OUTCOME=$externalOutcome"
    Write-Host 'MISH_U8_PUBLIC_EGRESS_OBSERVER_CONSENSUS=true'
    Write-Host 'MISH_U8_PUBLIC_EGRESS_RAW_IP_PERSISTED=false'
}
finally {
    $beforeAddress = $null
    $afterAddress = $null
    Close-MishPublicEgressObservationContext -Context $observationContext
    $observationContext = $null
    if (Test-Path -LiteralPath $rotationEvidencePath -PathType Leaf) {
        Remove-Item -LiteralPath $rotationEvidencePath -Force -ErrorAction SilentlyContinue
    }
}
