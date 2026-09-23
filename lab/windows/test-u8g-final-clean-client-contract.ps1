Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-u8g-final-clean-client.ps1'
$repositoryRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$deviceCyclePath = Join-Path $repositoryRoot '.github\workflows\device-cycle.yml'
$retiredWorkflowPath = Join-Path $repositoryRoot '.github\workflows\u8g-final-clean-client.yml'

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
    'Get-DnsClientCache',
    'Select-MishCleanDnsProofUrl',
    'WINDOWS_DNS_CACHE_NO_CLEAN_TARGET',
    'target_present_after',
    'CredentialProvisioning.psm1',
    'DiagnosticConnectProbe.psm1',
    'Invoke-MishDiagnosticHttpRelayProbe',
    'Invoke-MishDiagnosticProxyConnectProbe',
    '-TargetPort 443',
    'HTTPS_CONNECT_REGRESSION',
    'https_connect_443',
    '-ExpectAuthRejection',
    "owner = 'DiagnosticConnectProbe.psm1'",
    'Invoke-MishExternalProxyCredentialProvisioning',
    'Open-MishExternalProxyCredentialLease',
    'u8g-camoufox-toolchain.json',
    'headless=False',
    '[Environment]::UserInteractive',
    '[Diagnostics.Process]::GetCurrentProcess().SessionId',
    "browser_mode = 'headful'",
    '$script:PublicIpUrls',
    'Invoke-MishPublicIpPair',
    'Get-MishBrowserEgressClassification',
    'EXPECTED_PROXY_EGRESS',
    'HOST_DEFAULT',
    'AMBIGUOUS_PROXY_EQUALS_HOST',
    'matches_expected_proxy_egress',
    'matches_host_default_egress',
    'proxy_mode = ''HTTP_CONNECT''',
    'network.trr.mode',
    'network.dns.disablePrefetch',
    'network.prefetch-next',
    'network.predictor.enabled',
    'network.http.speculative-parallel-limit',
    'geoip=False',
    'block_webrtc=True',
    'accepted_current',
    'product_dns_advanced',
    "observer = 'Get-DnsClientCache'",
    'diagnose-u5-rotation.ps1',
    '-SuccessfulOperations 1',
    '-SkipShutdownRestoreAfterOn',
    'requests = 1',
    'raw_public_ip_persisted = $false',
    'raw_private_ip_persisted = $false',
    'raw_dns_server_persisted = $false',
    'proxy_credentials_persisted = $false',
    'error_class',
    'error_category',
    'error_code',
    'request_failure_present',
    'request_failure_code',
    'page.on("requestfailed", on_request_failed)',
    'request.failure',
    'stage',
    'def extract_error_code(exc):',
    'NS_ERROR',
    'SEC_ERROR',
    'MOZILLA_PKIX_ERROR',
    'result["error_code"] = extract_error_code(exc)',
    'result["error_class"] = type(exc).__name__',
    'result["error_category"] = classify_error(exc)',
    'def classify_error(exc):',
    'PROXY_AUTH',
    'PROXY_CONNECT',
    'TIMEOUT',
    'DNS',
    'TLS',
    'RESET',
    'REFUSED',
    'PLAYWRIGHT_ERROR_OTHER',
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
    'FullControl',
    'Get-WinEvent',
    'wevtutil',
    'Microsoft-Windows-DNS-Client/Operational',
    'function Invoke-MishHttpProxyRequest',
    'str(exc)',
    'repr(exc)',
    'print(message)',
    'print(getattr(exc',
    'request.url',
    'error_message',
    'headless=True',
    'NT AUTHORITY\NETWORK SERVICE',
    'DESKTOP-0E1F6UQ\Bose'
)) {
    if ($probe.Contains($forbidden)) {
        throw "Final U8-G clean-client probe contains forbidden duplicate/workaround path: $forbidden"
    }
}

if (($probe.Split('diagnose-u5-rotation.ps1').Count - 1) -ne 1) {
    throw 'Final U8-G acceptance must invoke exactly one existing PRODUCT rotation owner.'
}
if (-not $probe.Contains('$proxyServer = ''http://'' + $meshAddress + '':3128''')) {
    throw 'Final U8-G acceptance must target the exact current Mesh HTTP CONNECT listener.'
}
if ($probe -match '(?i)(before_ip|after_ip|raw_ip)\s*=') {
    throw 'Final U8-G evidence must not introduce raw IP persistence fields.'
}

$deviceCycle = Get-Content -Raw -LiteralPath $deviceCyclePath
if ($deviceCycle.Contains('u8g_final_clean_client') -or $deviceCycle.Contains('diagnose-u8g-final-clean-client.ps1')) {
    throw 'U8-G Camoufox acceptance must remain outside the Android Device Cycle execution boundary.'
}
if (Test-Path -LiteralPath $retiredWorkflowPath -PathType Leaf) {
    throw 'U8-G final clean-client acceptance must not recreate a standalone self-hosted physical workflow.'
}
if ($deviceCycle.Contains('/mish-u8g-final-acceptance')) {
    throw 'Retired standalone U8-G trigger must not survive in Device Cycle.'
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
