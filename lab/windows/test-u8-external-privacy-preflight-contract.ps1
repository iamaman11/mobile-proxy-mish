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
    'u8g-camoufox-toolchain.json',
    '.mish-u8g-browser.json',
    'official_archive_sha256',
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
    "'C:\\mish-lab\\runner\\.state'",
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


$workflowPath = Join-Path (Split-Path -Parent $PSScriptRoot) '..\.github\workflows\u8-external-privacy-preflight.yml'
$workflowPath = [IO.Path]::GetFullPath($workflowPath)
if (-not (Test-Path -LiteralPath $workflowPath -PathType Leaf)) {
    throw 'U8-G privacy preflight workflow is missing.'
}
$workflow = Get-Content -Raw -LiteralPath $workflowPath
foreach ($required in @(
    'name: U8 External Privacy Preflight',
    'workflow_dispatch:',
    'issue_comment:',
    "github.actor == 'iamaman11'",
    'github.event.issue.number == 315',
    "github.event.comment.body == '/mish-u8g-preflight'",
    'runs-on: [self-hosted, windows, x64, mobile-proxy-mish-lab]',
    "github.ref == 'refs/heads/main'",
    'github.ref_protected == true',
    'ref: ${{ github.sha }}',
    'persist-credentials: false',
    'diagnose-u8-external-privacy-preflight.ps1',
    'mish-u8g-clean-client-preflight-v1.json',
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
    'if-no-files-found: warn'
)) {
    if (-not $workflow.Contains($required)) {
        throw "U8-G privacy preflight workflow lost required trust marker: $required"
    }
}
foreach ($forbidden in @(
    'secrets.',
    'CLOUDFLARE_API_TOKEN',
    'MISH_MANAGER_TOKEN',
    'pull_request:',
    'push:'
)) {
    if ($workflow.Contains($forbidden)) {
        throw "U8-G privacy preflight workflow must stay explicit/read-only: $forbidden"
    }
}

Write-Host 'U8_EXTERNAL_PRIVACY_PREFLIGHT_CONTRACT=PASS'
