[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $DiagnosticEvidencePath,
    [ValidateSet('auto', 'none', 'loopback_connect', 'runtime_identity')]
    [string] $RequestedProbe = 'auto',
    [string] $OutputPath = (Join-Path $env:TEMP 'mish-device-cycle-probe-selection-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$schema = 'mish.device-cycle-probe-selection/v1'

if (-not (Test-Path -LiteralPath $DiagnosticEvidencePath -PathType Leaf)) {
    throw 'MISH_DEVICE_CYCLE_PROBE_SELECTION_FAILURE|EVIDENCE_MISSING|Diagnostic evidence is missing.'
}

$evidence = Get-Content -Raw -LiteralPath $DiagnosticEvidencePath | ConvertFrom-Json
$classification = [string]$evidence.classification
$proxyFailure = if ($null -ne $evidence.android -and $null -ne $evidence.android.proxy) {
    [string]$evidence.android.proxy.failure
} else {
    ''
}

$selected = $RequestedProbe
if ($RequestedProbe -ceq 'auto') {
    if ($proxyFailure -in @('STALE_PROCESS_IDENTITY_MISMATCH', 'CHILD_EXITED', 'CLEANUP_FAILED')) {
        $selected = 'runtime_identity'
    }
    elseif ($classification -like 'PRODUCT_LOOPBACK_E2E_*') {
        $selected = 'loopback_connect'
    }
    else {
        $selected = 'none'
    }
}

$projection = [ordered]@{
    schema = $schema
    requested = $RequestedProbe
    selected = $selected
    classification = $classification
    proxy_failure = $proxyFailure
}

$fullOutputPath = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $fullOutputPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullOutputPath,
    (($projection | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

$projection | ConvertTo-Json -Depth 4 -Compress
