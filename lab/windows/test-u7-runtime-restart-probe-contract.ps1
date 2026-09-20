$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$probePath = Join-Path $PSScriptRoot 'diagnose-u7-runtime-restart-resources.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'U7 runtime restart resource probe must parse under PowerShell.'
}
if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
    throw 'U7 runtime restart resource probe must not shadow the PowerShell automatic PID variable.'
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    "mish.lab.u7-runtime-restart-resources/v1",
    'DebugRuntimeStopActivity',
    'DebugRuntimeStartActivity',
    'Cycles = 3',
    'snapshot_v2',
    'Wait-MishStopped',
    'Wait-MishReady',
    'Wait-MishResourceQuiescence',
    '''shell'', ''run-as'', $PackageName, ''cat'', "/proc/$processId/status"',
    '''shell'', ''run-as'', $PackageName, ''ls'', ''-1'', "/proc/$processId/fd"',
    '''shell'', ''dumpsys'', ''meminfo'', ''-s'', [string]$processId',
    'runtime_generation_must_advance = $true',
    'credential_version_must_survive = $true',
    'threads_must_return_to_initial_bound = $true',
    'fd_must_return_to_initial_bound = $true',
    'owner_sessions_must_return_to_zero = $true',
    'rss_pss_are_observational = $true',
    'root_session_generation_stable = $rootSessionStable',
    'U7_RUNTIME_RESTART_RESOURCES_PASS',
    'MISH_U7_RUNTIME_RESTART_ACCEPTANCE=',
    'failure_restore_start'
)) {
    if (-not $source.Contains($required)) {
        throw "U7 restart resource probe lost required bounded contract: $required"
    }
}

foreach ($forbidden in @(
    "'shell', 'su'",
    "'shell', 'iptables'",
    "'shell', 'ip6tables'",
    'airplane-mode',
    'settings put',
    "'cmd', 'phone', 'data'",
    'warp-cli',
    'com.cloudflare',
    'sing-box',
    'gradle ',
    'cargo build',
    'assembleDebug',
    'ProxyUserName =',
    'ProxyPassword =',
    'before_ip',
    'after_ip',
    'runtime_io_thread_name_observation_required',
    'new_multi_thread',
    'worker_threads',
    'tokio'
)) {
    if ($source.Contains($forbidden)) {
        throw "U7 restart resource probe contains forbidden PRODUCT/root/network/build path: $forbidden"
    }
}

Write-Host 'U7_RUNTIME_RESTART_PROBE_CONTRACT=PASS'
