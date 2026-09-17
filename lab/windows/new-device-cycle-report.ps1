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
    if ($Evidence.PSObject.Properties.Name -contains 'acceptance_result') {
        $value = [string]$Evidence.acceptance_result
        if ($value -in @('PASS', 'FAIL')) { return $value }
        return 'INVALID'
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
    return $Probe -in @('capacity_resources', 'recovery_lifecycle')
}

$launch = Read-OptionalJson -Path $LaunchReceiptPath
$diagnostic = Read-OptionalJson -Path $DiagnosticEvidencePath
$targeted = Read-OptionalJson -Path $TargetedEvidencePath
$targetedAcceptance = Get-MishTargetedAcceptance -Evidence $targeted
$targetedClassification = Get-MishTargetedClassification -Evidence $targeted

$launchFailed = $null -ne $launch -and [string]$launch.result -ceq 'FAIL'
$launchFailureCategory = if ($launchFailed) { [string]$launch.failure_category } else { '' }
if ($launchFailed -and $launchFailureCategory -notmatch '^[A-Z0-9_]+$') { $launchFailureCategory = 'UNKNOWN' }

$classification = switch ($Mode) {
    'install_only' { 'INSTALL_ONLY_PASS'; break }
    'probe_only' {
        if ($RequestedProbe -cne 'loopback_connect') { 'LAB_PROBE_NOT_EXPLICIT' }
        elseif ($targetedAcceptance -eq 'MISSING') { 'LAB_TARGETED_PROBE_COLLECTION_FAILED' }
        elseif ($targetedAcceptance -eq 'INVALID') { 'LAB_TARGETED_PROBE_SCHEMA_INVALID' }
        else { $targetedClassification }
        break
    }
    'full' {
        if ($launchFailed) { "LAB_LAUNCH_$launchFailureCategory" }
        elseif ($null -eq $diagnostic) { 'DIAGNOSTIC_COLLECTION_FAILED' }
        elseif ([string]$diagnostic.classification -cne 'PASS') { [string]$diagnostic.classification }
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
        else { [string]$diagnostic.classification }
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
        if ($launchFailed -or $null -eq $diagnostic) { 'LAB_FAIL' }
        elseif ([string]$diagnostic.classification -cne 'PASS') {
            Get-MishCycleFailureKind -Classification ([string]$diagnostic.classification)
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
elseif ($cycleResult -ceq 'PASS') {
    'PASS'
}
elseif ($cycleResult -ceq 'PRODUCT_FAIL') {
    'FAIL'
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
Write-Host "MISH_DEVICE_CYCLE_EXACT_CANDIDATE_ACCEPTANCE=$exactCandidateAcceptance"
Write-Host "MISH_DEVICE_CYCLE_SOURCE_IDENTITY=$sourceIdentityClaim"
Write-Host "MISH_DEVICE_CYCLE_CONTROL_SHA=$ControlSha"
Write-Host "MISH_DEVICE_CYCLE_REPORT=$fullOutputPath"
$report | ConvertTo-Json -Depth 16 -Compress