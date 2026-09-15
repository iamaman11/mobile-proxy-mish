[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('full', 'install_only', 'diagnose_only', 'probe_only')]
    [string] $Mode,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int] $PrNumber,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $SourceSha,
    [string] $HostedRunId = '',
    [string] $InstallRunId = '',
    [string] $LaunchReceiptPath = '',
    [string] $DiagnosticEvidencePath = '',
    [string] $ProbeSelectionPath = '',
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

$launch = Read-OptionalJson -Path $LaunchReceiptPath
$diagnostic = Read-OptionalJson -Path $DiagnosticEvidencePath
$selection = Read-OptionalJson -Path $ProbeSelectionPath
$targeted = Read-OptionalJson -Path $TargetedEvidencePath

$launchFailed = $null -ne $launch -and [string]$launch.result -ceq 'FAIL'
$launchFailureCategory = if ($launchFailed) { [string]$launch.failure_category } else { '' }
if ($launchFailed -and $launchFailureCategory -notmatch '^[A-Z0-9_]+$') {
    $launchFailureCategory = 'UNKNOWN'
}
$selectedProbe = if ($null -ne $selection) { [string]$selection.selected } else { '' }
$targetedRequired = $selectedProbe -notin @('', 'none')
$targetedMissing = $targetedRequired -and $null -eq $targeted

$classification = switch ($Mode) {
    'install_only' { 'INSTALL_ONLY_PASS'; break }
    'probe_only' {
        if ($null -eq $selection) { 'LAB_PROBE_SELECTION_FAILED' }
        elseif (-not $targetedRequired) { 'LAB_PROBE_NOT_SELECTED' }
        elseif ($targetedMissing) { 'LAB_TARGETED_PROBE_COLLECTION_FAILED' }
        else { 'MANUAL_PROBE_COMPLETED' }
        break
    }
    default {
        if ($launchFailed) {
            "LAB_LAUNCH_$launchFailureCategory"
        }
        elseif ($null -eq $diagnostic) {
            'DIAGNOSTIC_COLLECTION_FAILED'
        }
        elseif ($null -eq $selection) {
            'LAB_PROBE_SELECTION_FAILED'
        }
        else {
            $diagnosticClassification = [string]$diagnostic.classification
            if ($diagnosticClassification -ceq 'PASS' -and $targetedMissing) {
                'LAB_TARGETED_PROBE_COLLECTION_FAILED'
            }
            else {
                $diagnosticClassification
            }
        }
    }
}

$cycleResult = switch ($Mode) {
    'install_only' { 'PASS'; break }
    'probe_only' {
        if ($classification -ceq 'MANUAL_PROBE_COMPLETED') { 'PASS' } else { 'LAB_FAIL' }
        break
    }
    default {
        if ($classification -ceq 'PASS') {
            'PASS'
        }
        elseif (
            $null -eq $diagnostic -or
            $classification -like 'LAB_*' -or
            $classification -like 'WINDOWS_*' -or
            $classification -like 'INVALID_*'
        ) {
            'LAB_FAIL'
        }
        else {
            'PRODUCT_FAIL'
        }
    }
}

$sourceIdentityClaim = if ($Mode -in @('full', 'install_only')) {
    'EXACT_INSTALLED_CANDIDATE'
}
else {
    'REQUEST_CONTEXT_ONLY'
}

$report = [ordered]@{
    schema = $schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    mode = $Mode
    acceptance_scope = switch ($Mode) {
        'full' { 'FULL_BASELINE' }
        'install_only' { 'INSTALL_ONLY' }
        'diagnose_only' { 'DIAGNOSE_ONLY' }
        'probe_only' { 'PROBE_ONLY' }
    }
    pr_number = $PrNumber
    source_sha = $SourceSha
    source_identity_claim = $sourceIdentityClaim
    hosted_run_id = $HostedRunId
    install_run_id = $InstallRunId
    cycle_result = $cycleResult
    classification = $classification
    launch = $launch
    diagnostic = $diagnostic
    targeted_probe = [ordered]@{
        selection = $selection
        required = $targetedRequired
        evidence_present = $null -ne $targeted
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
Write-Host "MISH_DEVICE_CYCLE_SOURCE_IDENTITY=$sourceIdentityClaim"
Write-Host "MISH_DEVICE_CYCLE_REPORT=$fullOutputPath"

$report | ConvertTo-Json -Depth 16 -Compress
