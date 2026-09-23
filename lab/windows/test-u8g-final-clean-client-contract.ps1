Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-u8g-final-clean-client.ps1'
$workflowPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) '.github\workflows\u8g-final-clean-client.yml'

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'Final U8-G clean-client probe must parse under PowerShell.'
}

$probe = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'mish.lab.u8g-final-clean-client/v1',
    'Microsoft-Windows-DNS-Client/Operational',
    'CredentialProvisioning.psm1',
    'Invoke-MishExternalProxyCredentialProvisioning',
    'Open-MishExternalProxyCredentialLease',
    'u8g-camoufox-toolchain.json',
    'NT AUTHORITY\NETWORK SERVICE',
    'proxy_mode = ''HTTP_CONNECT''',
    'network.trr.mode',
    'network.dns.disablePrefetch',
    'network.prefetch-next',
    'network.predictor.enabled',
    'network.http.speculative-parallel-limit',
    'geoip=False',
    'block_webrtc=True',
    'Get-WinEvent',
    'accepted_current',
    'product_dns_advanced',
    'windows_target_query_events',
    'diagnose-u5-rotation.ps1',
    '-SuccessfulOperations 1',
    '-SkipShutdownRestoreAfterOn',
    'requests = 1',
    'raw_public_ip_persisted = $false',
    'raw_private_ip_persisted = $false',
    'raw_dns_server_persisted = $false',
    'proxy_credentials_persisted = $false',
    'MISH_U8G_FINAL_DNS_NO_BYPASS=PASS',
    'MISH_U8G_FINAL_RAW_ADDRESSES_PERSISTED=NO'
)) {
    if (-not $probe.Contains($required)) {
        throw "Final U8-G clean-client probe lost required contract: $required"
    }
}

foreach ($forbidden in @(
    'tcp:0',
    'tcp:3128',
    'socks5://',
    'SOCKS5',
    'camoufox fetch',
    'playwright install',
    'Restart-Service',
    'Stop-Service',
    'Start-Service',
    'Set-DnsClientServerAddress',
    'Set-NetRoute',
    'New-NetRoute',
    'Remove-NetRoute',
    'Set-NetIPInterface',
    'Set-NetFirewall',
    'airplane-mode enable',
    'airplane-mode disable',
    'retry-until',
    'retry_until',
    'FullControl'
)) {
    if ($probe.Contains($forbidden)) {
        throw "Final U8-G clean-client probe contains forbidden duplicate/workaround path: $forbidden"
    }
}

if (($probe.Split('diagnose-u5-rotation.ps1').Count - 1) -ne 1) {
    throw 'Final U8-G acceptance must invoke exactly one existing PRODUCT rotation owner.'
}
if (-not $probe.Contains("$proxyServer = 'http://' + $meshAddress + ':3128'")) {
    throw 'Final U8-G acceptance must target the exact current Mesh HTTP CONNECT listener.'
}
if ($probe -match '(?i)(before_ip|after_ip|raw_ip)\s*=') {
    throw 'Final U8-G evidence must not introduce raw IP persistence fields.'
}

$workflow = Get-Content -Raw -LiteralPath $workflowPath
foreach ($required in @(
    'workflow_dispatch:',
    "github.ref == 'refs/heads/main'",
    'github.ref_protected == true',
    "github.event.issue.number == 315",
    "github.event.comment.body == '/mish-u8g-final-acceptance'",
    'runs-on: [self-hosted, windows, x64, mobile-proxy-mish-lab]',
    'persist-credentials: false',
    'diagnose-u8g-final-clean-client.ps1',
    'mish-u8g-final-clean-client-v1.json',
    'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02'
)) {
    if (-not $workflow.Contains($required)) {
        throw "Final U8-G workflow lost required trust/acceptance contract: $required"
    }
}

foreach ($forbidden in @(
    '(?m)^\s*pull_request\s*:',
    '(?m)^\s*push\s*:',
    '(?i)CLOUDFLARE_API_TOKEN',
    '(?i)Restart-Service',
    '(?i)workflow_run:'
)) {
    if ($workflow -match $forbidden) {
        throw "Final U8-G workflow contains forbidden trigger/authority/workaround: $forbidden"
    }
}

$preflight = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'diagnose-u8-external-privacy-preflight.ps1')
foreach ($required in @(
    'u8g-camoufox-toolchain.json',
    '.mish-u8g-browser.json',
    'official_archive_sha256'
)) {
    if (-not $preflight.Contains($required)) {
        throw "U8-G preflight must discover the canonical LAB-owned Camoufox toolchain: $required"
    }
}
if ($preflight.Contains("'C:\mish-lab\runner\.state'")) {
    throw 'U8-G preflight must not use the retired runner-state Camoufox discovery path.'
}

Write-Host 'U8_G_FINAL_CLEAN_CLIENT_CONTRACT=PASS'
exit 0
