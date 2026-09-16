[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-loopback-connect-diagnostic-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-MishLoopbackDiagnostic {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_LOOPBACK_DIAGNOSTIC_FAILURE|$Category|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = @(& $AdbPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        Stop-MishLoopbackDiagnostic 'ADB_FAILED' "ADB command failed with exit code $exitCode."
    }
    return ($output -join "`n").Trim()
}

function Invoke-MishAdbCapture {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $lines = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = ($lines -join "`n").Trim()
    }
}

function Get-MishTargetLines {
    param(
        [string] $Text,
        [Parameter(Mandatory)][string] $Pattern,
        [int] $Limit = 40
    )
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @(
        $Text -split "`r?`n" |
            Where-Object { $_ -match $Pattern } |
            Select-Object -First $Limit
    )
}

function Get-MishListenerStateObservation {
    $ss = Invoke-MishAdbCapture -Arguments @('shell', 'ss', '-H', '-tanp')
    $ssRows = Get-MishTargetLines `
        -Text $ss.Text `
        -Pattern '(^|[\s:])(1080|1081|3128)(?=\s|$)'

    $procTcp = Invoke-MishAdbCapture -Arguments @('shell', 'cat', '/proc/net/tcp')
    $procTcpRows = Get-MishTargetLines `
        -Text $procTcp.Text `
        -Pattern '^\s*\d+:\s+[0-9A-Fa-f]+:(0438|0439|0C38)\s'

    $procTcp6 = Invoke-MishAdbCapture -Arguments @('shell', 'cat', '/proc/net/tcp6')
    $procTcp6Rows = Get-MishTargetLines `
        -Text $procTcp6.Text `
        -Pattern '^\s*\d+:\s+[0-9A-Fa-f]+:(0438|0439|0C38)\s'

    $processes = Invoke-MishAdbCapture -Arguments @('shell', 'ps', '-A')
    $processRows = Get-MishTargetLines `
        -Text $processes.Text `
        -Pattern '(?i)(sing-box|mobileproxymish)'

    $singBox = Invoke-MishAdbCapture -Arguments @('shell', 'pidof', 'sing-box')
    $source = if ($ss.ExitCode -eq 0) {
        'ss'
    }
    elseif ($procTcp.ExitCode -eq 0 -or $procTcp6.ExitCode -eq 0) {
        'proc_net_tcp'
    }
    else {
        'unavailable'
    }

    return [ordered]@{
        source = $source
        ss_exit_code = $ss.ExitCode
        ss_target_rows = @($ssRows)
        proc_tcp_exit_code = $procTcp.ExitCode
        proc_tcp_target_rows = @($procTcpRows)
        proc_tcp6_exit_code = $procTcp6.ExitCode
        proc_tcp6_target_rows = @($procTcp6Rows)
        process_exit_code = $processes.ExitCode
        process_target_rows = @($processRows)
        sing_box_pid = if ($singBox.ExitCode -eq 0) { [string]$singBox.Text } else { '' }
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishLoopbackDiagnostic 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DiagnosticConnectProbe.psm1') -Force

$pidBefore = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
if ([string]::IsNullOrWhiteSpace($pidBefore) -or $pidBefore -match '\s') {
    Stop-MishLoopbackDiagnostic 'PRODUCT_PROCESS_NOT_RUNNING' 'Exactly one already-running PRODUCT process is required.'
}

# Read-only mechanism evidence collected before the CONNECT probe. This never uses su, kills a
# process, changes a socket, or attempts repair. It exists only to explain a typed listener failure.
$listenerState = Get-MishListenerStateObservation

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    Stop-MishLoopbackDiagnostic 'TEMP_UNAVAILABLE' 'A temporary directory is unavailable.'
}
$credentialStorePath = Join-Path ([IO.Path]::GetFullPath($tempRoot)) `
    ('mish-loopback-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')

$lease = $null
$adbForwardPort = $null
$credentialLeaseAvailable = $false
$probe = [ordered]@{ result = 'NOT_RUN'; reason = 'CREDENTIAL_OR_FORWARD_UNAVAILABLE'; elapsed_ms = 0 }
try {
    [void](Invoke-MishExternalProxyCredentialProvisioning `
        -AdbPath $AdbPath `
        -PackageName $PackageName `
        -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    $credentialLeaseAvailable = $null -ne $lease
    if (-not $credentialLeaseAvailable) {
        Stop-MishLoopbackDiagnostic 'CREDENTIAL_LEASE_UNAVAILABLE' 'Bounded package credential lease is unavailable.'
    }

    $forwardOutput = @(& $AdbPath forward 'tcp:0' 'tcp:3128' 2>$null)
    $forwardExit = $LASTEXITCODE
    $forwardText = ($forwardOutput -join "`n").Trim()
    if ($forwardExit -ne 0 -or $forwardText -notmatch '^\d+$') {
        Stop-MishLoopbackDiagnostic 'ADB_FORWARD_FAILED' 'Bounded ADB loopback forward could not be created.'
    }
    $adbForwardPort = [int]$forwardText

    $probe = Invoke-MishDiagnosticProxyConnectProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort $adbForwardPort `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 443 `
        -TimeoutMs 5000
}
finally {
    if ($null -ne $adbForwardPort) {
        & $AdbPath forward --remove "tcp:$adbForwardPort" 2>$null | Out-Null
    }
    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
$classification = if (-not $pidStable) {
    'INVALID_PROCESS_CHANGED_DURING_CAPTURE'
} elseif ([string]$probe.result -eq 'PASS') {
    'LOOPBACK_CONNECT_PASS'
} else {
    "LOOPBACK_CONNECT_$([string]$probe.reason)"
}

$evidence = [ordered]@{
    schema = 'mish.lab.loopback-connect-diagnostic/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    package = $PackageName
    pid_stable = $pidStable
    product_pid = [string]$pidBefore
    listener_state = $listenerState
    credential_lease_available = $credentialLeaseAvailable
    connect_probe = $probe
    classification = $classification
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_LOOPBACK_DIAGNOSTIC_COLLECTION=PASS'
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_CLASSIFICATION=$classification"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_PID_STABLE=$pidStable"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_RESULT=$([string]$probe.result)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_REASON=$([string]$probe.reason)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_LISTENER_SOURCE=$([string]$listenerState.source)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_TARGET_SOCKET_ROWS=$(@($listenerState.ss_target_rows).Count + @($listenerState.proc_tcp_target_rows).Count + @($listenerState.proc_tcp6_target_rows).Count)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_SING_BOX_PID=$([string]$listenerState.sing_box_pid)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_EVIDENCE=$fullEvidencePath"
