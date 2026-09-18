Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'diagnose-protocol-parity.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $scriptPath),
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'Protocol parity probe PowerShell parse failed.'
}

$source = Get-Content -Raw -LiteralPath $scriptPath
foreach ($required in @(
    'Invoke-MishDiagnosticHttpRelayProbe',
    'Invoke-MishDiagnosticSocks5RelayProbe',
    '-ProxyPort 3128',
    '-ProxyPort 1081',
    '-ProxyPort 1080',
    '-ExpectAuthRejection',
    'U2_PROTOCOL_PARITY_PASS',
    'PACKAGE_IDENTITY_MISMATCH',
    'exact_installed_bytes',
    'product_pid_stable'
)) {
    if (-not $source.Contains($required)) {
        throw "Protocol parity contract drifted: $required"
    }
}

if (($source.Split('-ExpectAuthRejection').Count - 1) -lt 4) {
    throw 'Protocol parity must prove negative authentication on HTTP, SOCKS5 and both mixed-ingress modes.'
}

foreach ($forbidden in @(
    'adb install',
    'force-stop',
    'am start',
    'reboot',
    'su -c',
    'iptables',
    'ip6tables',
    'ip rule add',
    'ip rule del'
)) {
    if ($source -match [regex]::Escape($forbidden)) {
        throw "Protocol parity probe must remain read-only with respect to PRODUCT/device policy: $forbidden"
    }
}

Write-Host 'Protocol parity probe contract passed.'
