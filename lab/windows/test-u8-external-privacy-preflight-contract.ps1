[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-u8-external-privacy-preflight.ps1'
if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    throw 'U8-G privacy preflight is missing.'
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $probePath,
    [ref]$tokens,
    [ref]$errors
)
if (@($errors).Count -ne 0) {
    $messages = @($errors | ForEach-Object { $_.Message }) -join '; '
    throw "U8-G privacy preflight does not parse: $messages"
}

$source = Get-Content -Raw -LiteralPath $probePath

foreach ($required in @(
    'mish.lab.u8-external-privacy-preflight/v1',
    'snapshot_v2',
    'READY_REQUIRES_PROFILE_DNS_ISOLATION',
    'READY_FOR_CLEAN_PROFILE_ACCEPTANCE',
    'BLOCKED_MESH_PEER_UNREACHABLE',
    'sing_box_running',
    'non_warp_tunnel_adapter_count',
    'raw_dns_servers_persisted = $false',
    'camoufox_available',
    'kameleo_local_api_available',
    'firefox_available',
    'browser_profile_changed = $false',
    'product_changed = $false',
    'raw_public_private_or_dns_addresses_persisted = $false'
)) {
    if (-not $source.Contains($required)) {
        throw "U8-G privacy preflight lost required marker: $required"
    }
}

foreach ($forbidden in @(
    'Stop-Process',
    'taskkill',
    'Disable-NetAdapter',
    'Enable-NetAdapter',
    'Restart-NetAdapter',
    'New-NetRoute',
    'Remove-NetRoute',
    'Set-NetRoute',
    'New-NetFirewallRule',
    'Set-NetFirewallRule',
    'Remove-NetFirewallRule',
    'Restart-Service',
    'Stop-Service',
    'Start-Service',
    'warp-cli disconnect',
    'warp-cli connect',
    "'shell', 'su'",
    'pm uninstall',
    'am force-stop'
)) {
    if ($source.Contains($forbidden)) {
        throw "U8-G preflight must remain read-only: $forbidden"
    }
}

Write-Host 'U8_EXTERNAL_PRIVACY_PREFLIGHT_CONTRACT=PASS'
