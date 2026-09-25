[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [ValidateRange(5, 30)][int] $ExternalProbeTimeoutSeconds = 15,
    [ValidateRange(5, 30)][int] $SafetyEnvelopeSeconds = 15,
    [ValidateRange(50, 500)][int] $ObservationSampleMilliseconds = 100,
    [ValidateRange(10, 90)][int] $RecoveryDeadlineSeconds = 45,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-radio-poweroff-public-egress-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.radio-poweroff-public-egress/v1'

Import-Module (Join-Path $PSScriptRoot 'PublicEgressObservation.psm1') -Force

function Stop-MishRadioPoweroffPublicEgress {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_RADIO_POWEROFF_PUBLIC_EGRESS_FAILURE|$Classification|$Message"
}

function Write-MishEvidence {
    param([Parameter(Mandatory)] $Evidence)
    $full = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $full
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $full,
        (($Evidence | ConvertTo-Json -Depth 14) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "MISH_RADIO_POWEROFF_PUBLIC_EGRESS_EVIDENCE=$full"
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishRadioPoweroffPublicEgress 'LAB_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
$innerEvidencePath = Join-Path $tempRoot ('mish-radio-poweroff-inner-' + [Guid]::NewGuid().ToString('N') + '.json')
$observationContext = $null
$beforeAddress = $null
$afterAddress = $null

$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'FAIL'
    classification = 'LAB_RADIO_POWEROFF_PUBLIC_EGRESS_UNCLASSIFIED'
    path = 'authenticated_PRODUCT_proxy_via_bounded_adb_forward'
    radio_cycle = 'LAB_HOLD_TO_TYPED_POWER_OFF_THEN_RESTORE'
    radio_cycles = 1
    external_observations = 2
    power_off_observed = $false
    external_outcome = 'FAILED'
    inner_classification = $null
    timings = $null
    restore = $null
    mutation = [ordered]@{
        adb_lab_radio_mutation_performed = $true
        product_mutation_performed = $false
        product_rotation_triggered = $false
        manager_command_issued = $false
        public_ip_observed_before_after = $true
        automatic_repeat_rotation = $false
    }
    raw_public_ip_persisted = $false
    subscription_id_persisted = $false
    operator_identity_persisted = $false
    secrets_persisted_in_evidence = $false
}

try {
    $observationContext = New-MishPublicEgressObservationContext -AdbPath $AdbPath -PackageName $PackageName

    $before = Invoke-MishExternalPublicIpObservation -Context $observationContext -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $beforeAddress = [string]$before.Address

    $innerError = $null
    try {
        & (Join-Path $PSScriptRoot 'characterize-radio-poweroff.ps1') -AdbPath $AdbPath -PackageName $PackageName -SafetyEnvelopeSeconds $SafetyEnvelopeSeconds -ObservationSampleMilliseconds $ObservationSampleMilliseconds -RecoveryDeadlineSeconds $RecoveryDeadlineSeconds -EvidencePath $innerEvidencePath
    }
    catch {
        $innerError = [string]$_
    }

    $inner = if (Test-Path -LiteralPath $innerEvidencePath -PathType Leaf) {
        Get-Content -Raw -LiteralPath $innerEvidencePath | ConvertFrom-Json
    } else {
        $null
    }
    if ($null -eq $inner) {
        $evidence.classification = 'LAB_POWEROFF_INNER_EVIDENCE_MISSING'
        Write-MishEvidence -Evidence $evidence
        Stop-MishRadioPoweroffPublicEgress $evidence.classification 'Hold-to-POWER_OFF characterization produced no evidence.'
    }

    $evidence.inner_classification = [string]$inner.classification
    $evidence.power_off_observed = [bool]$inner.observation.power_off_observed
    $evidence.restore = $inner.restore
    $evidence.timings = [ordered]@{
        external_before_ms = [int64]$before.ElapsedMs
        power_off_from_airplane_enable_lower_ms = if ($null -eq $inner.observation.first_power_off) { $null } else { [int64]$inner.observation.first_power_off.from_airplane_enable_lower_ms }
        power_off_from_airplane_enable_upper_ms = if ($null -eq $inner.observation.first_power_off) { $null } else { [int64]$inner.observation.first_power_off.from_airplane_enable_upper_ms }
        safety_envelope_ms = [int64]$inner.observation.safety_envelope_ms
    }

    if (
        $null -ne $innerError -or
        [string]$inner.result -cne 'PASS' -or
        -not [bool]$inner.observation.power_off_observed -or
        [string]$inner.classification -notin @('POWER_OFF_OBSERVED', 'POWER_OFF_OBSERVED_BEFORE_RESTORE_COMPLETION') -or
        -not [bool]$inner.restore.airplane_off_verified -or
        -not [bool]$inner.restore.product_recovered -or
        -not [bool]$inner.restore.rotation_operation_id_unchanged -or
        [bool]$inner.mutation.product_mutation_performed -or
        [bool]$inner.mutation.product_rotation_triggered -or
        [bool]$inner.mutation.manager_command_issued -or
        [bool]$inner.mutation.public_ip_polled -or
        [bool]$inner.mutation.automatic_repeat_rotation
    ) {
        $evidence.classification = 'LAB_POWEROFF_INNER_CONTRACT_FAILED'
        Write-MishEvidence -Evidence $evidence
        Stop-MishRadioPoweroffPublicEgress $evidence.classification 'Hold-to-POWER_OFF inner contract did not complete with proven restore.'
    }

    $after = Invoke-MishExternalPublicIpObservation -Context $observationContext -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $afterAddress = [string]$after.Address

    $changed = $beforeAddress -cne $afterAddress
    $externalOutcome = if ($changed) { 'CHANGED' } else { 'UNCHANGED' }

    $evidence.external_outcome = $externalOutcome
    $evidence.timings.external_after_ms = [int64]$after.ElapsedMs
    $evidence.acceptance_result = 'PASS'
    $evidence.classification = if ($changed) {
        'POWER_OFF_PUBLIC_EGRESS_CHANGED'
    } else {
        'POWER_OFF_PUBLIC_EGRESS_UNCHANGED'
    }

    Write-MishEvidence -Evidence $evidence
    Write-Host 'MISH_RADIO_POWEROFF_PUBLIC_EGRESS=PASS'
    Write-Host "MISH_RADIO_POWEROFF_PUBLIC_EGRESS_OUTCOME=$externalOutcome"
    Write-Host 'MISH_RADIO_POWEROFF_PUBLIC_EGRESS_POWER_OFF_OBSERVED=true'
    Write-Host 'MISH_RADIO_POWEROFF_PUBLIC_EGRESS_RADIO_CYCLES=1'
    Write-Host 'MISH_RADIO_POWEROFF_PUBLIC_EGRESS_PRODUCT_ROTATION_TRIGGERED=false'
    Write-Host 'MISH_RADIO_POWEROFF_PUBLIC_EGRESS_MANAGER_COMMAND_ISSUED=false'
    Write-Host 'MISH_RADIO_POWEROFF_PUBLIC_EGRESS_RAW_IP_PERSISTED=false'
}
finally {
    $beforeAddress = $null
    $afterAddress = $null
    Close-MishPublicEgressObservationContext -Context $observationContext
    $observationContext = $null
    if (Test-Path -LiteralPath $innerEvidencePath -PathType Leaf) {
        Remove-Item -LiteralPath $innerEvidencePath -Force -ErrorAction SilentlyContinue
    }
}
