[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-u8-durability-soak.ps1'
if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    throw 'U8-F durability soak probe is missing.'
}

$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $probePath,
    [ref]$null,
    [ref]$parseErrors
)
if (@($parseErrors).Count -ne 0) {
    $messages = @($parseErrors | ForEach-Object { $_.Message }) -join '; '
    throw "U8-F durability soak probe does not parse: $messages"
}

$source = Get-Content -Raw -LiteralPath $probePath

foreach ($required in @(
    'mish.lab.u8-durability-soak/v1',
    'control_snapshot_v1',
    'runtime.active_tasks',
    'application_heartbeat_count',
    'payload_tx_bytes',
    'payload_rx_bytes',
    'reconnect_count',
    'ControlPayloadMonthlyBudgetBytes = 10MB',
    'Open-MishLongLivedTunnel',
    'Invoke-MishTunnelPulse',
    'proxy_active_sessions',
    'mesh_active_sessions',
    'Wait-MishQuiescence',
    'threads_fd_tokio_tasks_must_return_to_baseline',
    'shell am crash',
    'Wait-MishFreshReadyProcess',
    'explicit_activity_launch_used = $false',
    'post_recovery_mesh_e2e',
    'U8_DURABILITY_SOAK_PASS',
    'no_512_stress = $true',
    'wire_bytes_claimed = $false',
    'secrets_persisted_in_evidence = $false',
    'raw_public_ip_persisted = $false'
)) {
    if (-not $source.Contains($required)) {
        throw "U8-F durability soak contract lost required marker: $required"
    }
}

foreach ($forbidden in @(
    'u7_512',
    'Capacity512Cycles',
    'MISH_MANAGER_TOKEN',
    'ROTATE_IP',
    'cmd connectivity airplane-mode',
    "'shell', 'su'",
    'ProcessBuilder',
    'start-device-app.ps1',
    'pm uninstall',
    'adb uninstall'
)) {
    if ($source.Contains($forbidden)) {
        throw "U8-F durability soak must remain bounded LAB observation/fault-injection only: $forbidden"
    }
}

Write-Host 'U8_DURABILITY_SOAK_PROBE_CONTRACT=PASS'
