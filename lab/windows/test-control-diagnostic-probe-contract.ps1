Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptPath = Join-Path $PSScriptRoot 'collect-control-diagnostic.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path $scriptPath),
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'CONTROL diagnostic PowerShell parse failed.'
}

$source = Get-Content -Raw -LiteralPath $scriptPath
foreach ($required in @(
    '2>$null',
    "Stop-MishControlDiagnostic 'ADB_FAILED'",
    "Stop-MishControlDiagnostic 'PRODUCT_PROCESS_NOT_RUNNING'",
    "Stop-MishControlDiagnostic 'PRODUCT_PID_CHANGED'",
    'control_snapshot_v1',
    'mutation_performed = $false'
)) {
    if (-not $source.Contains($required)) {
        throw "CONTROL diagnostic contract drifted: $required"
    }
}
if ($source.Contains('2>&1')) {
    throw 'CONTROL diagnostic must not merge ADB stderr into structured stdout.'
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
        throw "CONTROL diagnostic must remain read-only with respect to PRODUCT/device policy: $forbidden"
    }
}

if (-not $IsLinux) {
    Write-Host 'CONTROL cold-ADB behavioral regression is Linux-hosted; static contract passed.'
    exit 0
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mish-control-contract-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$fakeAdb = Join-Path $tempRoot 'adb'
$evidencePath = Join-Path $tempRoot 'control-evidence.json'
$packageName = 'com.mobileproxymish.app.debug'

$native = [ordered]@{
    schema = 'mish.control.diagnostics/v1'
    application_id = $packageName
    captured_elapsed_ms = 42
    control = [ordered]@{
        state = 'READY'
        operation_timing = [ordered]@{
            operation_id = $null
            rotation_terminal_control_state = $null
            rotation_terminal_ms = 0
            post_terminal_connect_started_ms = 0
            post_terminal_connect_attempts = 0
            post_terminal_transport_connected_ms = 0
            post_terminal_transport_connections = 0
            reconnect_ready_ms = 0
            result_sent_ms = 0
            result_ack_ms = 0
        }
    }
}
$payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($native | ConvertTo-Json -Depth 8 -Compress)))

$fakeSource = @'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == "shell pidof __PACKAGE__" ]]; then
  echo "* daemon not running; starting now at tcp:5037" >&2
  echo "* daemon started successfully" >&2
  printf '%s\n' "${MISH_FAKE_PID:-1435}"
  exit 0
fi
if [[ "$*" == *"--method control_snapshot_v1"* ]]; then
  printf '%s\n' 'Result: Bundle[{payload_b64=__PAYLOAD__}]'
  exit 0
fi
echo "unsupported fake adb invocation: $*" >&2
exit 9
'@
$fakeSource = $fakeSource.Replace('__PACKAGE__', $packageName).Replace('__PAYLOAD__', $payload)
[IO.File]::WriteAllText($fakeAdb, $fakeSource, [Text.UTF8Encoding]::new($false))
& chmod '+x' $fakeAdb
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to make fake ADB executable.'
}

try {
    & $scriptPath -AdbPath $fakeAdb -PackageName $packageName -EvidencePath $evidencePath
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw 'Cold-ADB regression did not produce CONTROL evidence.'
    }
    $evidence = Get-Content -Raw -LiteralPath $evidencePath | ConvertFrom-Json
    if ([int64]$evidence.pid -ne 1435 -or -not [bool]$evidence.pid_stable) {
        throw 'Cold-ADB stderr noise contaminated the PRODUCT PID observation.'
    }
    if ([string]$evidence.control.state -cne 'READY' -or [bool]$evidence.mutation_performed) {
        throw 'CONTROL diagnostic evidence contract drifted.'
    }

    $env:MISH_FAKE_PID = '1435 2000'
    $multiplePidRejected = $false
    try {
        & $scriptPath -AdbPath $fakeAdb -PackageName $packageName -EvidencePath (Join-Path $tempRoot 'multiple-pid.json')
    }
    catch {
        if ($_.Exception.Message -match 'PRODUCT_PROCESS_NOT_RUNNING') {
            $multiplePidRejected = $true
        } else {
            throw
        }
    }
    if (-not $multiplePidRejected) {
        throw 'CONTROL diagnostic must fail closed when more than one PRODUCT PID is observed.'
    }
}
finally {
    Remove-Item Env:MISH_FAKE_PID -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'CONTROL diagnostic cold-ADB regression contract passed.'
