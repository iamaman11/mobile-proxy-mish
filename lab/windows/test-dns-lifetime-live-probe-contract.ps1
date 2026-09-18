Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-dns-lifetime-live.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'DNS lifetime live probe must parse under PowerShell.'
}
if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
    throw 'DNS lifetime live probe must not shadow the PowerShell automatic PID variable.'
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'mish.lab.dns-lifetime-live/v1',
    'snapshot_v2',
    'CredentialProvisioning.psm1',
    'Invoke-MishExternalProxyCredentialProvisioning',
    'Open-MishExternalProxyCredentialLease',
    '@(''forward'', ''tcp:0'', ''tcp:3128'')',
    '''shell'', ''cmd'', ''phone'', ''data''',
    'LAB_DNS_LIFETIME_PROCESS_CHANGED',
    'LAB_DNS_LIFETIME_TARGET_NOT_EXERCISED',
    'LAB_DNS_LIFETIME_LOSS_NOT_OBSERVED',
    'LAB_DNS_LIFETIME_RECOVERY_SEQUENCE_UNOBSERVED',
    'U3_DNS_LIFETIME_LIVE_OBSERVATION_COMPLETE',
    'last_started_owner_sequence',
    'completed_after_owner_change',
    'discarded_after_deadline',
    'discarded_stale',
    'max_observed_active',
    'quiescent_after_recovery',
    'final_completion_gap',
    'observation_only = $true',
    'same_process = $true',
    'product_routes_or_iptables_mutated_by_lab = $false',
    'cloudflare_app_mutated = $false',
    'mish-dns-$RunTag-$Ordinal.example.com',
    '''forward'', ''--remove'''
)) {
    if (-not $source.Contains($required)) {
        throw "DNS lifetime live probe lost required bounded evidence contract: $required"
    }
}

$disableIndex = $source.IndexOf("Invoke-MishMobileDataTransition -State 'disable'", [StringComparison]::Ordinal)
$enableIndex = $source.IndexOf("Invoke-MishMobileDataTransition -State 'enable'", [StringComparison]::Ordinal)
$recoveryIndex = $source.IndexOf('LAB_DNS_LIFETIME_RECOVERY_SEQUENCE_UNOBSERVED', [StringComparison]::Ordinal)
if ($disableIndex -lt 0 -or $enableIndex -le $disableIndex -or $recoveryIndex -le $enableIndex) {
    throw 'DNS lifetime live probe must preserve one ordered disable -> enable -> fresh-sequence observation.'
}

foreach ($forbidden in @(
    '''shell'', ''su''',
    '''shell'', ''iptables''',
    '''shell'', ''ip6tables''',
    'airplane-mode',
    'settings put',
    'svc data',
    '''am'', ''instrument''',
    'gradle ',
    'cargo build',
    'assembleDebug',
    'ConvertFrom-SecureString',
    'ProxyUserName =',
    'ProxyPassword =',
    'public_ip'
)) {
    if ($source.Contains($forbidden)) {
        throw "DNS lifetime live probe contains forbidden duplicate PRODUCT/root/build/secret path: $forbidden"
    }
}

Write-Host 'DNS_LIFETIME_LIVE_PROBE_CONTRACT=PASS'
exit 0
