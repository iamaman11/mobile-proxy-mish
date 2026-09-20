$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$probePath = Join-Path $PSScriptRoot 'diagnose-u7-512-lifecycle-stability.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'U7 repeated-512 lifecycle stability probe must parse under PowerShell.'
}
if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
    throw 'U7 repeated-512 lifecycle stability probe must not shadow the PowerShell automatic PID variable.'
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'mish.lab.u7-512-lifecycle-stability/v1',
    'diagnose-capacity-resources.ps1',
    '-Capacity512Cycles 3',
    'diagnose-u5-rotation.ps1',
    '-SuccessfulOperations 3',
    'U7_CAPACITY_512_REPEAT_PASS',
    'capacity_512_cycles_requested',
    'capacity_512_cycles_completed',
    'cleanup_rss_kb',
    'cleanup_pss_kb',
    'rss_last_minus_first_kb',
    'pss_last_minus_first_kb',
    'memory_trend_is_observational = $true',
    'no_leak_claim_from_three_samples = $true',
    'shutdown_restore_after_on',
    'runtime_stopped_observed',
    'runtime_credential_cleared',
    'restart_process_stable',
    'runtime_restarted_ready',
    'cellular_reconcile_requested -gt 0',
    'cellular_reconcile_executed -eq [int64]$restartState.cellular_reconcile_requested',
    'restart_reached_product',
    'PRODUCT_STOP_ON_RESTART_DID_NOT_REACH_PRODUCT',
    'product_pid',
    'stable = $pidStable',
    'U7_512_LIFECYCLE_STABILITY_PASS'
)) {
    if (-not $source.Contains($required)) {
        throw "U7 repeated-512 lifecycle probe lost required composition/evidence contract: $required"
    }
}

foreach ($forbidden in @(
    "'shell', 'su'",
    "'shell', 'iptables'",
    "'shell', 'ip6tables'",
    "settings put",
    "airplane-mode enable",
    "airplane-mode disable",
    "'cmd', 'phone', 'data'",
    "DebugRotationActivity",
    "DebugRuntimeStopActivity",
    "DebugRuntimeStartActivity",
    "gradle ",
    "cargo build",
    "assembleDebug",
    "tokio::runtime",
    "ProcessBuilder"
)) {
    if ($source.Contains($forbidden)) {
        throw "U7 repeated-512 lifecycle probe duplicated PRODUCT/root/radio/build behavior instead of composing accepted probes: $forbidden"
    }
}

$capacityCall = $source.IndexOf("diagnose-capacity-resources.ps1", [StringComparison]::Ordinal)
$rotationCall = $source.IndexOf("diagnose-u5-rotation.ps1", [StringComparison]::Ordinal)
if ($capacityCall -lt 0 -or $rotationCall -lt 0 -or $capacityCall -gt $rotationCall) {
    throw 'Repeated 512 capacity acceptance must complete before rotation/stop-on lifecycle acceptance.'
}

Write-Host 'U7_512_LIFECYCLE_STABILITY_PROBE_CONTRACT=PASS'
exit 0
