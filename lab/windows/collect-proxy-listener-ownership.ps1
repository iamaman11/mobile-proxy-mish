[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-proxy-listener-ownership-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schema = 'mish.lab.proxy-listener-ownership/v1'
$canonicalPorts = @(1080, 1081, 3128)

function Stop-MishListenerDiagnostic {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_LISTENER_DIAGNOSTIC_FAILURE|$Category|$Message"
}

function Invoke-MishAdbCapture {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = @(& $AdbPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
    return [ordered]@{
        exit_code = if ($null -eq $exitCode) { -1 } else { [int]$exitCode }
        text = ($output -join "`n").Trim()
    }
}

function Convert-MishTcpTable {
    param([Parameter(Mandatory)][string] $Text)

    $rows = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
        $fields = [regex]::Split($trimmed, '\s+')
        if ($fields.Count -lt 10 -or $fields[0] -notmatch '^\d+:$') { continue }
        if ($fields[3] -cne '0A') { continue }

        $local = $fields[1].Split(':')
        if ($local.Count -ne 2 -or $local[1] -notmatch '^[0-9A-Fa-f]{4}$') { continue }
        $port = [Convert]::ToInt32($local[1], 16)
        if ($canonicalPorts -notcontains $port) { continue }

        $uid = $null
        if ($fields[7] -match '^\d+$') { $uid = [int64]$fields[7] }
        $address = switch ($local[0].ToUpperInvariant()) {
            '0100007F' { '127.0.0.1' }
            '00000000' { '0.0.0.0' }
            default { "hex:$($local[0].ToUpperInvariant())" }
        }
        $inode = if ($fields[9] -match '^\d+$') { [string]$fields[9] } else { $null }

        $rows += [ordered]@{
            port = $port
            address = $address
            uid = $uid
            inode = $inode
        }
    }
    return @($rows)
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishListenerDiagnostic 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

$devices = Invoke-MishAdbCapture -Arguments @('devices')
$deviceRows = @($devices.text -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($devices.exit_code -ne 0 -or $deviceRows.Count -ne 1) {
    Stop-MishListenerDiagnostic 'DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.'
}

$package = Invoke-MishAdbCapture -Arguments @('shell', 'dumpsys', 'package', $PackageName)
if ($package.exit_code -ne 0) {
    Stop-MishListenerDiagnostic 'PACKAGE_LOOKUP_FAILED' 'Package metadata could not be read.'
}
$uidMatch = [regex]::Match($package.text, '(?m)^\s*userId=(?<uid>\d+)\s*$')
if (-not $uidMatch.Success) {
    Stop-MishListenerDiagnostic 'PACKAGE_UID_UNAVAILABLE' 'Package UID could not be resolved.'
}
$packageUid = [int64]$uidMatch.Groups['uid'].Value

$pidResult = Invoke-MishAdbCapture -Arguments @('shell', 'pidof', $PackageName)
$productPid = if ($pidResult.exit_code -eq 0 -and $pidResult.text -match '^\d+$') {
    [int64]$pidResult.text
} else {
    $null
}

$tcpSource = 'shell:/proc/net/tcp'
$tcp = Invoke-MishAdbCapture -Arguments @('shell', 'cat', '/proc/net/tcp')
if ($tcp.exit_code -ne 0 -or $tcp.text -notmatch '(?m)^\s*sl\s+') {
    $tcpSource = 'run-as:/proc/net/tcp'
    $tcp = Invoke-MishAdbCapture -Arguments @('shell', 'run-as', $PackageName, 'cat', '/proc/net/tcp')
}
$tcpRows = if ($tcp.exit_code -eq 0 -and $tcp.text -match '(?m)^\s*sl\s+') {
    @(Convert-MishTcpTable -Text $tcp.text)
} else {
    @()
}
$tcpAvailable = $tcp.exit_code -eq 0 -and $tcp.text -match '(?m)^\s*sl\s+'

$ss = Invoke-MishAdbCapture -Arguments @('shell', 'ss', '-ltnp')
$ssAvailable = $ss.exit_code -eq 0
$ssRows = @()
if ($ssAvailable) {
    foreach ($line in ($ss.text -split "`r?`n")) {
        if ($line -notmatch 'LISTEN') { continue }
        $portMatch = [regex]::Match($line, '(?:^|\s)(?:\[?[^\s\]]+\]?|\*):(?<port>1080|1081|3128)(?:\s|$)')
        if (-not $portMatch.Success) { continue }
        $port = [int]$portMatch.Groups['port'].Value
        $processMatch = [regex]::Match($line, 'users:\(\(\"(?<name>[^\"]+)\",pid=(?<pid>\d+)')
        $ssRows += [ordered]@{
            port = $port
            process_name = if ($processMatch.Success) { [string]$processMatch.Groups['name'].Value } else { $null }
            pid = if ($processMatch.Success) { [int64]$processMatch.Groups['pid'].Value } else { $null }
        }
    }
}

$listeners = @()
foreach ($port in $canonicalPorts) {
    $portTcpRows = @($tcpRows | Where-Object { [int]$_.port -eq $port })
    $portSsRows = @($ssRows | Where-Object { [int]$_.port -eq $port })
    $uids = @($portTcpRows | ForEach-Object { $_.uid } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
    $processes = @(
        $portSsRows |
            Where-Object { $null -ne $_.pid } |
            ForEach-Object {
                [ordered]@{ pid = [int64]$_.pid; name = [string]$_.process_name }
            }
    )
    $addresses = @($portTcpRows | ForEach-Object { [string]$_.address } | Sort-Object -Unique)
    $uidMatches = @($uids | Where-Object { [int64]$_ -eq $packageUid }).Count
    $foreignUids = @($uids | Where-Object { [int64]$_ -ne $packageUid })

    $listeners += [ordered]@{
        port = $port
        listening = ($portTcpRows.Count -gt 0 -or $portSsRows.Count -gt 0)
        addresses = $addresses
        socket_uids = $uids
        package_uid_match = ($uids.Count -gt 0 -and $uidMatches -eq $uids.Count)
        foreign_uids = $foreignUids
        process_observation = $processes
    }
}

$allForeignUids = @(
    $listeners |
        ForEach-Object { @($_.foreign_uids) } |
        ForEach-Object { $_ } |
        Sort-Object -Unique
)
$anyListener = @($listeners | Where-Object { [bool]$_.listening }).Count -gt 0
$anyUnattributed = @(
    $listeners | Where-Object {
        [bool]$_.listening -and @($_.socket_uids).Count -eq 0 -and @($_.process_observation).Count -eq 0
    }
).Count -gt 0
$allObservedOwnedByPackage = $anyListener -and -not $anyUnattributed -and $allForeignUids.Count -eq 0 -and @(
    $listeners | Where-Object { [bool]$_.listening -and -not [bool]$_.package_uid_match }
).Count -eq 0

$classification = if (-not $tcpAvailable -and -not $ssAvailable) {
    'LISTENER_OBSERVATION_UNAVAILABLE'
} elseif (-not $anyListener) {
    'NO_CANONICAL_LISTENER'
} elseif ($allForeignUids.Count -gt 0) {
    'FOREIGN_UID_OWNS_CANONICAL_LISTENER'
} elseif ($allObservedOwnedByPackage) {
    'PACKAGE_UID_OWNS_CANONICAL_LISTENERS'
} else {
    'CANONICAL_LISTENER_OWNER_UNRESOLVED'
}

$evidence = [ordered]@{
    schema = $schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    package = $PackageName
    package_uid = $packageUid
    product_pid = $productPid
    tcp_observation_available = $tcpAvailable
    tcp_observation_source = $tcpSource
    ss_observation_available = $ssAvailable
    canonical_listeners = $listeners
    classification = $classification
    mutation_performed = $false
    root_used = $false
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_LISTENER_DIAGNOSTIC_COLLECTION=PASS'
Write-Host "MISH_LISTENER_DIAGNOSTIC_CLASSIFICATION=$classification"
Write-Host "MISH_LISTENER_DIAGNOSTIC_PACKAGE_UID=$packageUid"
foreach ($listener in $listeners) {
    $uids = (@($listener.socket_uids) -join ',')
    $processSummary = (@($listener.process_observation | ForEach-Object { "$($_.pid):$($_.name)" }) -join ',')
    Write-Host "MISH_LISTENER_$($listener.port)=listening=$($listener.listening);uids=$uids;processes=$processSummary"
}
Write-Host 'MISH_LISTENER_DIAGNOSTIC_MUTATION=NO'
Write-Host 'MISH_LISTENER_DIAGNOSTIC_ROOT_USED=NO'
Write-Host "MISH_LISTENER_DIAGNOSTIC_EVIDENCE=$fullEvidencePath"
