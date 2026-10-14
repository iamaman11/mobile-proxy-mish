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
    'HTTPS through the accepted HTTP proxy forces CONNECT',
    '@(''forward'', ''tcp:0'', ''tcp:3128'')',
    '''shell'', ''cmd'', ''phone'', ''data''',
    'LAB_DNS_LIFETIME_PROCESS_CHANGED',
    'LAB_DNS_LIFETIME_TARGET_NOT_EXERCISED',
    'LAB_DNS_LIFETIME_LOSS_NOT_OBSERVED',
    'LAB_DNS_LIFETIME_RECOVERY_SEQUENCE_UNOBSERVED',
    'U3_DNS_LIFETIME_LIVE_OBSERVATION_COMPLETE',
    "readiness_state -ceq 'READY'",
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
    'https://mish-dns-$RunTag-$Ordinal.example.com/',
    '''forward'', ''--remove''',
    '[System.Diagnostics.Stopwatch] $TimelineStopwatch',
    "clock = 'System.Diagnostics.Stopwatch'",
    'shared_external_clock = -not $timelineOwned',
    'disable_start_ms',
    'disable_complete_ms',
    'loss_observed_ms',
    'enable_start_ms',
    'enable_complete_ms',
    'first_post_enable_reconcile_ms',
    'fresh_cellular_admitted_ms',
    'root_authorized_ms',
    'readiness_ready_ms',
    'disable_start_to_readiness_ready',
    'cellular_reconcile_requested',
    'root_policy_authorized_generation',
    'readiness_cellular_owner_generation'
)) {
    if (-not $source.Contains($required)) {
        throw "DNS lifetime live probe lost required bounded evidence contract: $required"
    }
}

$disableNeedle = "Invoke-MishMobileDataTransition -State 'disable'"
$enableNeedle = "Invoke-MishMobileDataTransition -State 'enable'"
$disableIndex = $source.IndexOf($disableNeedle, [StringComparison]::Ordinal)
$enableIndex = $source.IndexOf($enableNeedle, [StringComparison]::Ordinal)
$recoveryIndex = $source.IndexOf('LAB_DNS_LIFETIME_RECOVERY_SEQUENCE_UNOBSERVED', [StringComparison]::Ordinal)
if ($disableIndex -lt 0 -or $enableIndex -le $disableIndex -or $recoveryIndex -le $enableIndex) {
    throw 'DNS lifetime live probe must preserve one ordered disable -> enable -> fresh-sequence observation.'
}
if (($source.Split($disableNeedle).Count - 1) -ne 1 -or ($source.Split($enableNeedle).Count - 1) -ne 1) {
    throw 'DNS lifetime live probe must keep exactly one primary disable and one primary enable transition.'
}

$disableStartIndex = $source.IndexOf('$disableStartMs = [int64]$TimelineStopwatch.ElapsedMilliseconds', [StringComparison]::Ordinal)
$disableCompleteIndex = $source.IndexOf('$disableCompleteMs = [int64]$TimelineStopwatch.ElapsedMilliseconds', [StringComparison]::Ordinal)
$enableStartIndex = $source.IndexOf('$enableStartMs = [int64]$TimelineStopwatch.ElapsedMilliseconds', [StringComparison]::Ordinal)
$enableCompleteIndex = $source.IndexOf('$enableCompleteMs = [int64]$TimelineStopwatch.ElapsedMilliseconds', [StringComparison]::Ordinal)
if (
    $disableStartIndex -lt 0 -or
    $disableStartIndex -ge $disableIndex -or
    $disableCompleteIndex -le $disableIndex -or
    $enableStartIndex -lt 0 -or
    $enableStartIndex -ge $enableIndex -or
    $enableCompleteIndex -le $enableIndex
) {
    throw 'DNS lifetime timing markers must observe the existing transition calls without moving or duplicating them.'
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
