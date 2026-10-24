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

# The script above remains an archival, explicit-U2-identity acceptance probe.
# It must not be silently advertised as a live current-PRODUCT diagnostic with
# a pinned historical source/APK digest. An authorized current-PRODUCT protocol
# command may be reintroduced only after deriving identity from verified
# installed-candidate provenance, not from a copied constant.
$workflowPath = Join-Path (Split-Path -Parent $PSScriptRoot) '..\.github\workflows\mish-lab-diagnostic.yml'
$workflowPath = [IO.Path]::GetFullPath($workflowPath)
$workflow = Get-Content -Raw -LiteralPath $workflowPath
foreach ($obsolete in @(
    "github.event.comment.body == '/mish-diag protocol-parity'",
    'CURRENT_ACCEPTED_SOURCE_SHA:',
    'CURRENT_ACCEPTED_INSTALLED_APK_SHA256:'
)) {
    if ($workflow.Contains($obsolete)) {
        throw "Active LAB diagnostic must not depend on archived U2 APK identity: $obsolete"
    }
}
foreach ($required in @(
    "github.event.comment.body == '/mish-diag snapshot'",
    "github.event.comment.body == '/mish-diag control-snapshot'",
    "github.event.comment.body == '/mish-diag mesh-route'"
)) {
    if (-not $workflow.Contains($required)) {
        throw "Current read-only LAB diagnostic command disappeared: $required"
    }
}

Write-Host 'Protocol parity probe contract passed.'
