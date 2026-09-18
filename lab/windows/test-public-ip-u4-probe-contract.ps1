Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probe = Join-Path $PSScriptRoot 'diagnose-public-ip-u4.ps1'
if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) {
    throw 'U4 public-IP physical probe script is missing.'
}

$text = Get-Content -Raw -LiteralPath $probe
[void][ScriptBlock]::Create($text)

foreach ($required in @(
    'mish.lab.public-ip-u4/v1',
    'PublicIpU4InstrumentedTest',
    'U4_PUBLIC_IP_PASS',
    'stale_generation_rejected',
    'no_default_fallback',
    'fresh_generation_observed',
    'repeated_observations_bounded',
    'raw_public_ip_persisted = $false'
)) {
    if (-not $text.Contains($required, [StringComparison]::Ordinal)) {
        throw "U4 public-IP probe contract is missing: $required"
    }
}

foreach ($forbidden in @(
    'checkip.amazonaws.com',
    'instrumentation_output',
    'public_ip =',
    'address ='
)) {
    if ($text.Contains($forbidden, [StringComparison]::Ordinal)) {
        throw "U4 public-IP probe must not persist endpoint/raw response data: $forbidden"
    }
}

Write-Host 'U4_PUBLIC_IP_PROBE_CONTRACT=PASS'
exit 0
