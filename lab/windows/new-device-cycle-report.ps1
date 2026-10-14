[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('full', 'install_only', 'diagnose_only', 'probe_only')]
    [string] $Mode,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int] $PrNumber,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $SourceSha,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $ControlSha,
    [string] $HostedRunId = '',
    [string] $InstallRunId = '',
    [string] $LaunchReceiptPath = '',
    [string] $DiagnosticEvidencePath = '',
    [string] $RequestedProbe = 'none',
    [string] $TargetedEvidencePath = '',
    [Parameter(Mandatory)][string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$schema = 'mish.device-cycle/v1'

function Read-OptionalJson {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json)
}

function Get-MishTargetedAcceptance {
    param($Evidence)
    if ($null -eq $Evidence) { return 'MISSING' }
    if ([string]$Evidence.schema -ceq 'mish.lab.radio-poweroff-public-egress/v1') {
        if (
            [string]$Evidence.acceptance_result -notin @('PASS', 'FAIL') -or
            [string]$Evidence.classification -notin @(
                'POWER_OFF_PUBLIC_EGRESS_CHANGED',
                'POWER_OFF_PUBLIC_EGRESS_UNCHANGED',
                'LAB_RADIO_POWEROFF_PUBLIC_EGRESS_UNCLASSIFIED',
                'LAB_POWEROFF_INNER_EVIDENCE_MISSING',
                'LAB_POWEROFF_INNER_CONTRACT_FAILED'
            ) -or
            [int]$Evidence.radio_cycles -ne 1 -or
            [int]$Evidence.external_observations -ne 2 -or
            -not [bool]$Evidence.power_off_observed -or
            $null -eq $Evidence.restore -or
            -not [bool]$Evidence.restore.airplane_off_verified -or
            -not [bool]$Evidence.restore.product_pid_stable -or
            -not [bool]$Evidence.restore.product_recovered -or
            -not [bool]$Evidence.restore.rotation_operation_id_unchanged -or
            [bool]$Evidence.mutation.product_mutation_performed -or
            [bool]$Evidence.mutation.product_rotation_triggered -or
            [bool]$Evidence.mutation.manager_command_issued -or
            [bool]$Evidence.mutation.automatic_repeat_rotation -or
            [bool]$Evidence.raw_public_ip_persisted -or
            [bool]$Evidence.secrets_persisted_in_evidence
        ) {
            return 'INVALID'
        }
        return [string]$Evidence.acceptance_result
    }
    if ([string]$Evidence.schema -ceq 'mish.lab.cellular-primitive-capabilities/v1') {
        if (
            [string]$Evidence.acceptance_result -cne 'PASS' -or
            [string]$Evidence.classification -cne 'CELLULAR_PRIMITIVE_CAPABILITY_AUDIT_PASS' -or
            [string]$Evidence.device.model -cne 'SM-A022G' -or
            [int]$Evidence.device.api -ne 30 -or
            [string]$Evidence.device.abi -cne 'armeabi-v7a' -or
            [string]$Evidence.architecture_decision -cne 'NOT_MADE' -or
            [bool]$Evidence.mutation.product_mutation_performed -or
            [bool]$Evidence.mutation.data_mutation_performed -or
            [bool]$Evidence.mutation.radio_mutation_performed -or
            [bool]$Evidence.mutation.modem_mutation_performed -or
            [bool]$Evidence.mutation.rotation_triggered -or
            [bool]$Evidence.mutation.app_restart_performed -or
            [bool]$Evidence.mutation.install_performed -or
            [bool]$Evidence.raw_command_help_persisted -or
            [bool]$Evidence.raw_public_ip_persisted -or
            [bool]$Evidence.subscription_id_persisted -or
            [bool]$Evidence.operator_identity_persisted -or
            [bool]$Evidence.secrets_persisted_in_evidence
        ) {
            return 'INVALID'
        }
        return 'PASS'
    }
    if ($Evidence.PSObject.Properties.Name -contains 'acceptance_result') {
        $value = [string]$Evidence.acceptance_result
        if ($value -in @('PASS', 'FAIL')) { return $value }
        return 'INVALID'
    }
    if ([string]$Evidence.schema -ceq 'mish.lab.radio-poweroff-characterization/v1') {
        if (
            [string]$Evidence.result -notin @('PASS', 'FAIL') -or
            [string]$Evidence.classification -notin @(
                'POWER_OFF_OBSERVED',
                'POWER_OFF_OBSERVED_BEFORE_RESTORE_COMPLETION',
                'POWER_OFF_NOT_OBSERVED_WITHIN_SAFETY_ENVELOPE'
            ) -or
            $null -eq $Evidence.restore -or
            -not [bool]$Evidence.restore.attempted -or
            -not [bool]$Evidence.restore.airplane_off_verified -or
            -not [bool]$Evidence.restore.product_pid_stable -or
            -not [bool]$Evidence.restore.product_recovered -or
            -not [bool]$Evidence.restore.rotation_operation_id_unchanged -or
            [bool]$Evidence.mutation.product_mutation_performed -or
            [bool]$Evidence.mutation.product_rotation_triggered -or
            [bool]$Evidence.mutation.manager_command_issued -or
            [bool]$Evidence.mutation.public_ip_polled -or
            [bool]$Evidence.mutation.automatic_repeat_rotation
        ) {
            return 'INVALID'
        }
        return [string]$Evidence.result
    }
    # Compatibility with the accepted #207 loopback schema. File existence is not success.
    if (
        [string]$Evidence.schema -ceq 'mish.lab.loopback-connect-diagnostic/v1' -and
        $Evidence.PSObject.Properties.Name -contains 'protocol_matrix_pass' -and
        $Evidence.PSObject.Properties.Name -contains 'pid_stable' -and
        $null -ne $Evidence.connect_probe
    ) {
        if (
            [bool]$Evidence.pid_stable -and
            [bool]$Evidence.protocol_matrix_pass -and
            [string]$Evidence.connect_probe.result -ceq 'PASS' -and
            [string]$Evidence.classification -ceq 'U2_PROXY_PROTOCOL_MATRIX_PASS'
        ) { return 'PASS' }
        return 'FAIL'
    }
    return 'INVALID'
}

function Get-MishTargetedClassification {
    param($Evidence)
    if ($null -eq $Evidence) { return 'LAB_TARGETED_PROBE_COLLECTION_FAILED' }
    if ($Evidence.PSObject.Properties.Name -contains 'classification') {
        $value = [string]$Evidence.classification
        if ($value -match '^[A-Z0-9_]+$') { return $value }
    }
    return 'LAB_TARGETED_PROBE_SCHEMA_INVALID'
}

function Get-MishCycleFailureKind {
    param([Parameter(Mandatory)][string] $Classification)
    if (
        $Classification -like 'LAB_*' -or
        $Classification -like 'WINDOWS_*' -or
        $Classification -like 'INVALID_*' -or
        $Classification -eq 'DIAGNOSTIC_COLLECTION_FAILED'
    ) { return 'LAB_FAIL' }
    return 'PRODUCT_FAIL'
}

function Test-MishSupportedFullProbe {
    param([Parameter(Mandatory)][string] $Probe)
    return $Probe -in @('capacity_resources', 'recovery_lifecycle', 'dns_lifetime_live', 'u5_rotation', 'u7_runtime_restart_resources', 'u7_512_lifecycle_stability', 'u8_reboot_install_durability', 'u8_public_egress_rotation', 'u8_radio_poweroff_characterization', 'u8_radio_poweroff_public_egress', 'u8_durability_soak', 'u8g_final_clean_client')
}

$launch = Read-OptionalJson -Path $LaunchReceiptPath
$diagnostic = Read-OptionalJson -Path $DiagnosticEvidencePath
$targeted = Read-OptionalJson -Path $TargetedEvidencePath
$targetedAcceptance = Get-MishTargetedAcceptance -Evidence $targeted
$targetedClassification = Get-MishTargetedClassification -Evidence $targeted
$diagnosticClassification = if ($null -eq $diagnostic) { '' } else { [string]$diagnostic.classification }
$externalMeshBaselineBlocked = (
    $Mode -ceq 'full' -and
    $RequestedProbe -ceq 'recovery_lifecycle' -and
    $diagnosticClassification -ceq 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED'
)

$launchFailed = $null -ne $launch -and [string]$launch.result -ceq 'FAIL'
$launchFailureCategory = if ($launchFailed) { [string]$launch.failure_category } else { '' }
if ($launchFailed -and $launchFailureCategory -notmatch '^[A-Z0-9_]+$') { $launchFailureCategory = 'UNKNOWN' }

$classification = switch ($Mode) {
    'install_only' { 'INSTALL_ONLY_PASS'; break }
    'probe_only' {
        if ($RequestedProbe -notin @('loopback_connect', 'cellular_primitive_capabilities')) { 'LAB_PROBE_NOT_EXPLICIT' }
        elseif ($targetedAcceptance -eq 'MISSING') { 'LAB_TARGETED_PROBE_COLLECTION_FAILED' }
        elseif ($targetedAcceptance -eq 'INVALID') { 'LAB_TARGETED_PROBE_SCHEMA_INVALID' }
        else { $targetedClassification }
        break
    }
    'full' {
        if ($launchFailed) { "LAB_LAUNCH_$launchFailureCategory" }
        elseif ($null -eq $diagnostic) { 'DIAGNOSTIC_COLLECTION_FAILED' }
        elseif ($externalMeshBaselineBlocked) {
            if ($targetedAcceptance -eq 'MISSING') { 'LAB_TARGETED_PROBE_COLLECTION_FAILED' }
            elseif ($targetedAcceptance -eq 'INVALID') { 'LAB_TARGETED_PROBE_SCHEMA_INVALID' }
            elseif ($targetedAcceptance -ceq 'PASS') { $diagnosticClassification }
            else { $targetedClassification }
        }
        elseif ($diagnosticClassification -cne 'PASS') { $diagnosticClassification }
        elseif ($RequestedProbe -ceq 'none') { 'PASS' }
        elseif (-not (Test-MishSupportedFullProbe -Probe $RequestedProbe)) { 'LAB_PROBE_NOT_EXPLICIT' }
        elseif ($targetedAcceptance -eq 'MISSING') { 'LAB_TARGETED_PROBE_COLLECTION_FAILED' }
        elseif ($targetedAcceptance -eq 'INVALID') { 'LAB_TARGETED_PROBE_SCHEMA_INVALID' }
        else { $targetedClassification }
        break
    }
    default {
        if ($launchFailed) { "LAB_LAUNCH_$launchFailureCategory" }
        elseif ($null -eq $diagnostic) { 'DIAGNOSTIC_COLLECTION_FAILED' }
        else { $diagnosticClassification }
    }
}

$cycleResult = switch ($Mode) {
    'install_only' { 'PASS'; break }
    'probe_only' {
        if ($classification -eq 'LAB_PROBE_NOT_EXPLICIT' -or $targetedAcceptance -in @('MISSING', 'INVALID')) { 'LAB_FAIL' }
        elseif ($targetedAcceptance -ceq 'PASS') { 'PASS' }
        else { Get-MishCycleFailureKind -Classification $classification }
        break
    }
    'full' {
        # Baseline facts outrank targeted-probe absence/failure. A baseline PRODUCT failure must not
        # be reclassified as LAB failure merely because an explicit targeted acceptance could not run.
        # The one accepted exception is the proven Windows sandbox external-Mesh blocker for
        # recovery_lifecycle: it must not mask an independently observed targeted PRODUCT failure,
        # and it can never produce PASS on its own.
        if ($launchFailed -or $null -eq $diagnostic) { 'LAB_FAIL' }
        elseif ($externalMeshBaselineBlocked) {
            if ($targetedAcceptance -in @('MISSING', 'INVALID', 'PASS')) { 'LAB_FAIL' }
            else { Get-MishCycleFailureKind -Classification $classification }
        }
        elseif ($diagnosticClassification -cne 'PASS') {
            Get-MishCycleFailureKind -Classification $diagnosticClassification
        }
        elseif ($RequestedProbe -ceq 'none') { 'PASS' }
        elseif (-not (Test-MishSupportedFullProbe -Probe $RequestedProbe)) { 'LAB_FAIL' }
        elseif ($targetedAcceptance -in @('MISSING', 'INVALID')) { 'LAB_FAIL' }
        elseif ($targetedAcceptance -ceq 'PASS') { 'PASS' }
        else { Get-MishCycleFailureKind -Classification $classification }
        break
    }
    default {
        if ($classification -ceq 'PASS') { 'PASS' }
        else { Get-MishCycleFailureKind -Classification $classification }
    }
}

$exactCandidateAcceptance = if ($Mode -cne 'full') {
    'NOT_EVALUATED'
}
elseif ($cycleResult -ceq 'PRODUCT_FAIL') {
    'FAIL'
}
elseif ($RequestedProbe -in @('dns_lifetime_live', 'u8_radio_poweroff_characterization', 'u8_radio_poweroff_public_egress')) {
    # Measurement/characterization probes can guide an engineering decision, but they do not
    # independently accept PRODUCT behavior.
    'NOT_EVALUATED'
}
elseif ($cycleResult -ceq 'PASS') {
    'PASS'
}
else {
    'NOT_EVALUATED'
}

$sourceIdentityClaim = if ($Mode -in @('full', 'install_only')) { 'EXACT_INSTALLED_CANDIDATE' } else { 'REQUEST_CONTEXT_ONLY' }

$report = [ordered]@{
    schema = $schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    mode = $Mode
    acceptance_scope = switch ($Mode) {
        'full' {
            if ($RequestedProbe -ceq 'capacity_resources') { 'FULL_BASELINE_PLUS_CAPACITY_RESOURCES' }
            elseif ($RequestedProbe -ceq 'recovery_lifecycle') { 'FULL_BASELINE_PLUS_RECOVERY_LIFECYCLE' }
            elseif ($RequestedProbe -ceq 'dns_lifetime_live') { 'FULL_BASELINE_PLUS_DNS_LIFETIME_OBSERVATION' }
            elseif ($RequestedProbe -ceq 'u5_rotation') { 'FULL_BASELINE_PLUS_U5_ROTATION' }
            elseif ($RequestedProbe -ceq 'u7_runtime_restart_resources') { 'FULL_BASELINE_PLUS_U7_RUNTIME_RESTART_RESOURCES' }
            elseif ($RequestedProbe -ceq 'u7_512_lifecycle_stability') { 'FULL_BASELINE_PLUS_U7_512_LIFECYCLE_STABILITY' }
            elseif ($RequestedProbe -ceq 'u8_reboot_install_durability') { 'FULL_BASELINE_PLUS_U8_REBOOT_INSTALL_DURABILITY' }
            elseif ($RequestedProbe -ceq 'u8_public_egress_rotation') { 'FULL_BASELINE_PLUS_U8_PUBLIC_EGRESS_ROTATION' }
            elseif ($RequestedProbe -ceq 'u8_radio_poweroff_characterization') { 'FULL_BASELINE_PLUS_U8_RADIO_POWEROFF_CHARACTERIZATION' }
            elseif ($RequestedProbe -ceq 'u8_radio_poweroff_public_egress') { 'FULL_BASELINE_PLUS_U8_RADIO_POWEROFF_PUBLIC_EGRESS' }
            elseif ($RequestedProbe -ceq 'u8_durability_soak') { 'FULL_BASELINE_PLUS_U8_DURABILITY_SOAK' }
            elseif ($RequestedProbe -ceq 'u8g_final_clean_client') { 'FULL_BASELINE_PLUS_U8G_FINAL_CLEAN_CLIENT' }
            else { 'FULL_BASELINE' }
        }
        'install_only' { 'INSTALL_ONLY' }
        'diagnose_only' { 'DIAGNOSE_ONLY' }
        'probe_only' { 'PROBE_ONLY' }
    }
    pr_number = $PrNumber
    source_sha = $SourceSha
    control_sha = $ControlSha
    source_identity_claim = $sourceIdentityClaim
    hosted_run_id = $HostedRunId
    install_run_id = $InstallRunId
    cycle_result = $cycleResult
    classification = $classification
    baseline_classification = $diagnosticClassification
    exact_candidate_acceptance = $exactCandidateAcceptance
    targeted_probe = [ordered]@{
        requested = $RequestedProbe
        automatic = $false
        evidence_present = $null -ne $targeted
        acceptance_result = $targetedAcceptance
        evidence = $targeted
    }
}

$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $fullOutputPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullOutputPath,
    (($report | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_DEVICE_CYCLE_RESULT=$cycleResult"
Write-Host "MISH_DEVICE_CYCLE_CLASSIFICATION=$classification"
Write-Host "MISH_DEVICE_CYCLE_BASELINE_CLASSIFICATION=$diagnosticClassification"
Write-Host "MISH_DEVICE_CYCLE_EXACT_CANDIDATE_ACCEPTANCE=$exactCandidateAcceptance"
Write-Host "MISH_DEVICE_CYCLE_SOURCE_IDENTITY=$sourceIdentityClaim"
Write-Host "MISH_DEVICE_CYCLE_CONTROL_SHA=$ControlSha"
Write-Host "MISH_DEVICE_CYCLE_REPORT=$fullOutputPath"
$report | ConvertTo-Json -Depth 16 -Compress