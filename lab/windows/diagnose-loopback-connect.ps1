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
        canonical_ports = @(1080, 1081, 3128)
        ss_exit_code = $ss.ExitCode
        ss_target_rows = @($ssRows)
        proc_tcp_exit_code = $procTcp.ExitCode
        proc_tcp_target_rows = @($procTcpRows)
        proc_tcp6_exit_code = $procTcp6.ExitCode
        proc_tcp6_target_rows = @($procTcp6Rows)
    }
}

function New-MishAdbForward {
    param([Parameter(Mandatory)][ValidateSet(1080, 1081, 3128)][int] $DevicePort)

    $forwardOutput = @(& $AdbPath forward 'tcp:0' "tcp:$DevicePort" 2>$null)
    $forwardExit = $LASTEXITCODE
    $forwardText = ($forwardOutput -join "`n").Trim()
    if ($forwardExit -ne 0 -or $forwardText -notmatch '^\d+$') {
        Stop-MishLoopbackDiagnostic 'ADB_FORWARD_FAILED' "Bounded ADB loopback forward for PRODUCT port $DevicePort could not be created."
    }
    return [int]$forwardText
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

# Read-only mechanism evidence collected before the protocol probes. It is deliberately product-
# agnostic: observe only canonical socket rows and whatever owner metadata the OS exposes there.
# Never infer current PRODUCT composition from historical process names.
$listenerState = Get-MishListenerStateObservation

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    Stop-MishLoopbackDiagnostic 'TEMP_UNAVAILABLE' 'A temporary directory is unavailable.'
}
$credentialStorePath = Join-Path ([IO.Path]::GetFullPath($tempRoot)) `
    ('mish-loopback-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')

$lease = $null
$forwardPorts = @{}
$credentialLeaseAvailable = $false
$connectProbe = [ordered]@{ result = 'NOT_RUN'; reason = 'CREDENTIAL_OR_FORWARD_UNAVAILABLE'; elapsed_ms = 0 }
$protocolMatrix = [ordered]@{
    http_connect = [ordered]@{ valid = $null; wrong_auth = $null }
    socks5 = [ordered]@{ valid = $null; wrong_auth = $null }
    mixed = [ordered]@{
        http_valid = $null
        http_wrong_auth = $null
        socks5_valid = $null
        socks5_wrong_auth = $null
    }
}
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

    # Canonical PRODUCT listener mapping is owned by mish-proxy:
    # 1080 mixed, 1081 SOCKS5, 3128 HTTP CONNECT. ADB forwards expose only the already-running
    # loopback listeners to this bounded LAB probe; no listener or alternate dataplane is created.
    $forwardPorts[1080] = New-MishAdbForward -DevicePort 1080
    $forwardPorts[1081] = New-MishAdbForward -DevicePort 1081
    $forwardPorts[3128] = New-MishAdbForward -DevicePort 3128

    # Preserve the original minimal CONNECT observation for continuity with earlier evidence.
    $connectProbe = Invoke-MishDiagnosticProxyConnectProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[3128]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 443 `
        -TimeoutMs 5000

    # U2 physical protocol/auth/relay evidence. Every valid probe tunnels to a domain target and
    # confirms bytes in both directions with an HTTP request/response after protocol admission.
    # Every wrong-auth probe must be rejected before relay. Results contain no credential material.
    $protocolMatrix.http_connect.valid = Invoke-MishDiagnosticHttpRelayProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[3128]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000
    $protocolMatrix.http_connect.wrong_auth = Invoke-MishDiagnosticHttpRelayProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[3128]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000 `
        -ExpectAuthRejection

    $protocolMatrix.socks5.valid = Invoke-MishDiagnosticSocks5RelayProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[1081]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000
    $protocolMatrix.socks5.wrong_auth = Invoke-MishDiagnosticSocks5RelayProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[1081]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000 `
        -ExpectAuthRejection

    $protocolMatrix.mixed.http_valid = Invoke-MishDiagnosticHttpRelayProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[1080]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000
    $protocolMatrix.mixed.http_wrong_auth = Invoke-MishDiagnosticHttpRelayProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[1080]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000 `
        -ExpectAuthRejection
    $protocolMatrix.mixed.socks5_valid = Invoke-MishDiagnosticSocks5RelayProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[1080]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000
    $protocolMatrix.mixed.socks5_wrong_auth = Invoke-MishDiagnosticSocks5RelayProbe `
        -ProxyHost '127.0.0.1' `
        -ProxyPort ([int]$forwardPorts[1080]) `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000 `
        -ExpectAuthRejection
}
finally {
    foreach ($localPort in @($forwardPorts.Values)) {
        if ($null -ne $localPort) {
            & $AdbPath forward --remove "tcp:$localPort" 2>$null | Out-Null
        }
    }
    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
}

$matrixResults = @(
    $protocolMatrix.http_connect.valid,
    $protocolMatrix.http_connect.wrong_auth,
    $protocolMatrix.socks5.valid,
    $protocolMatrix.socks5.wrong_auth,
    $protocolMatrix.mixed.http_valid,
    $protocolMatrix.mixed.http_wrong_auth,
    $protocolMatrix.mixed.socks5_valid,
    $protocolMatrix.mixed.socks5_wrong_auth
)
$protocolMatrixPass = @($matrixResults | Where-Object { $null -eq $_ -or [string]$_.result -cne 'PASS' }).Count -eq 0

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
$classification = if (-not $pidStable) {
    'INVALID_PROCESS_CHANGED_DURING_CAPTURE'
} elseif ([string]$connectProbe.result -cne 'PASS') {
    "LOOPBACK_CONNECT_$([string]$connectProbe.reason)"
} elseif (-not $protocolMatrixPass) {
    'U2_PROXY_PROTOCOL_MATRIX_FAILED'
} else {
    'U2_PROXY_PROTOCOL_MATRIX_PASS'
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
    connect_probe = $connectProbe
    protocol_matrix = $protocolMatrix
    protocol_matrix_pass = $protocolMatrixPass
    classification = $classification
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_LOOPBACK_DIAGNOSTIC_COLLECTION=PASS'
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_CLASSIFICATION=$classification"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_PID_STABLE=$pidStable"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_RESULT=$([string]$connectProbe.result)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_REASON=$([string]$connectProbe.reason)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_PROTOCOL_MATRIX_PASS=$protocolMatrixPass"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_LISTENER_SOURCE=$([string]$listenerState.source)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_TARGET_SOCKET_ROWS=$(@($listenerState.ss_target_rows).Count + @($listenerState.proc_tcp_target_rows).Count + @($listenerState.proc_tcp6_target_rows).Count)"
Write-Host "MISH_LOOPBACK_DIAGNOSTIC_EVIDENCE=$fullEvidencePath"
