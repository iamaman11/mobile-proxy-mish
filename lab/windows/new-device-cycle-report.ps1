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

$launch = Read-OptionalJson -Path $LaunchReceiptPath
$diagnostic = Read-OptionalJson -Path $DiagnosticEvidencePath
$targeted = Read-OptionalJson -Path $TargetedEvidencePath

$launchFailed = $null -ne $launch -and [string]$launch.result -ceq 'FAIL'
$launchFailureCategory = if ($launchFailed) { [string]$launch.failure_category } else { '' }
if ($launchFailed -and $launchFailureCategory -notmatch '^[A-Z0-9_]+$') {
    $launchFailureCategory = 'UNKNOWN'
}

$classification = switch ($Mode) {
    'install_only' { 'INSTALL_ONLY_PASS'; break }
    'probe_only' {
        if ($RequestedProbe -notin @('runtime_identity', 'loopback_connect')) {
            'LAB_PROBE_NOT_EXPLICIT'
        }
        elseif ($null -eq $targeted) {
            'LAB_TARGETED_PROBE_COLLECTION_FAILED'
        }
        else {
            'MANUAL_PROBE_COMPLETED'
        }
        break
    }
    default {
        if ($launchFailed) {
            "LAB_LAUNCH_$launchFailureCategory"
        }
        elseif ($null -eq $diagnostic) {
            'DIAGNOSTIC_COLLECTION_FAILED'
        }
        else {
            [string]$diagnostic.classification
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
            $classification -eq 'DIAGNOSTIC_COLLECTION_FAILED' -or
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
    control_sha = $ControlSha
    source_identity_claim = $sourceIdentityClaim
    hosted_run_id = $HostedRunId
    install_run_id = $InstallRunId
    cycle_result = $cycleResult
    classification = $classification
    launch = $launch
    diagnostic = $diagnostic
    targeted_probe = [ordered]@{
        requested = $RequestedProbe
        automatic = $false
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
Write-Host "MISH_DEVICE_CYCLE_CONTROL_SHA=$ControlSha"
Write-Host "MISH_DEVICE_CYCLE_REPORT=$fullOutputPath"

$report | ConvertTo-Json -Depth 16 -Compress
