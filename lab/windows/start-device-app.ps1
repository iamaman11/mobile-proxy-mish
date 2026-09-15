[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $ComponentName = 'com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity',
    [ValidateRange(5, 180)][int] $StartupTimeoutSeconds = 75,
    [ValidateRange(1, 10)][int] $StablePidSamples = 3,
    [ValidateRange(100, 5000)][int] $PollIntervalMs = 1000,
    [string] $ReceiptPath = (Join-Path $env:TEMP 'mish-device-start-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$schema = 'mish.device-start/v1'
$snapshotMethod = 'snapshot_v1'

function Stop-MishDeviceStart {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_DEVICE_START_FAILURE|$Category|$Message"
}

function Invoke-AdbCapture {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $lines = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    return [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Text = ($lines -join "`n").Trim()
    }
}

function Read-AndroidSnapshot {
    $result = Invoke-AdbCapture -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $snapshotMethod
    )
    if ($result.ExitCode -ne 0) { return $null }
    $match = [regex]::Match($result.Text, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { return $null }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        return ($json | ConvertFrom-Json)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishDeviceStart 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

$deviceRows = @(& $AdbPath devices | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $deviceRows.Count -ne 1) {
    Stop-MishDeviceStart 'DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.'
}

$forceStop = Invoke-AdbCapture -Arguments @('shell', 'am', 'force-stop', $PackageName)
if ($forceStop.ExitCode -ne 0) {
    Stop-MishDeviceStart 'FORCE_STOP_FAILED' 'Could not stop the previous application process.'
}

$startedAt = [Diagnostics.Stopwatch]::StartNew()
$launch = Invoke-AdbCapture -Arguments @('shell', 'am', 'start', '-W', '-n', $ComponentName)
if ($launch.ExitCode -ne 0 -or $launch.Text -match '(?im)^Error:') {
    Stop-MishDeviceStart 'LAUNCH_FAILED' 'Explicit launcher activity start failed.'
}

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($StartupTimeoutSeconds)
$lastPid = $null
$stableCount = 0
$stablePid = $null
$proxyRunningSamples = 0
$proxyState = 'UNKNOWN'
$readinessState = 'UNKNOWN'
$terminalObservation = 'TIMEOUT'

while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $processIdResult = Invoke-AdbCapture -Arguments @('shell', 'pidof', $PackageName)
    $processId = if ($processIdResult.ExitCode -eq 0 -and $processIdResult.Text -match '^\d+$') { $processIdResult.Text } else { $null }
    if ($null -eq $processId) {
        $lastPid = $null
        $stableCount = 0
        $proxyRunningSamples = 0
        Start-Sleep -Milliseconds $PollIntervalMs
        continue
    }

    if ($processId -ceq $lastPid) {
        $stableCount += 1
    }
    else {
        $lastPid = $processId
        $stableCount = 1
        $proxyRunningSamples = 0
    }

    if ($stableCount -ge $StablePidSamples) {
        $stablePid = $processId
        $snapshot = Read-AndroidSnapshot
        if ($null -ne $snapshot) {
            $proxyState = [string]$snapshot.proxy.state
            $readinessState = [string]$snapshot.readiness.state
            if ($proxyState -ceq 'FAILED') {
                $terminalObservation = 'PRODUCT_TERMINAL_FAILURE'
                break
            }
            if ($readinessState -ceq 'READY') {
                $terminalObservation = 'READY'
                break
            }
            if ($proxyState -ceq 'RUNNING') {
                $proxyRunningSamples += 1
                if ($proxyRunningSamples -ge 2) {
                    $terminalObservation = 'PROXY_RUNNING'
                    break
                }
            }
            else {
                $proxyRunningSamples = 0
            }
        }
    }

    Start-Sleep -Milliseconds $PollIntervalMs
}

$startedAt.Stop()
if ($null -eq $stablePid) {
    Stop-MishDeviceStart 'PROCESS_NOT_STABLE' 'Application did not reach one stable PID inside the bounded startup window.'
}

$finalPid = Invoke-AdbCapture -Arguments @('shell', 'pidof', $PackageName)
if ($finalPid.ExitCode -ne 0 -or $finalPid.Text -cne $stablePid) {
    Stop-MishDeviceStart 'PROCESS_CHANGED' 'Application PID changed after startup stabilization.'
}

$receipt = [ordered]@{
    schema = $schema
    result = 'PASS'
    package = $PackageName
    component = $ComponentName
    pid = [int]$stablePid
    pid_stable = $true
    terminal_observation = $terminalObservation
    proxy_state = $proxyState
    readiness_state = $readinessState
    elapsed_ms = [int64]$startedAt.ElapsedMilliseconds
}

$fullReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
$parent = Split-Path -Parent $fullReceiptPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullReceiptPath,
    (($receipt | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_DEVICE_START=PASS'
Write-Host "MISH_DEVICE_START_PID=$stablePid"
Write-Host "MISH_DEVICE_START_TERMINAL=$terminalObservation"
Write-Host "MISH_DEVICE_START_PROXY=$proxyState"
Write-Host "MISH_DEVICE_START_READINESS=$readinessState"
Write-Host "MISH_DEVICE_START_RECEIPT=$fullReceiptPath"
