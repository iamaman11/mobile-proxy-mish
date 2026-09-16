[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [string] $TargetHost = 'example.com',
    [int] $TargetPort = 443,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-capacity-resources-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SnapshotMethod = 'snapshot_v2'
$script:AndroidSchema = 'mish.diagnostics/v2'
$script:ConnectTimeoutMs = 5000
$script:CounterDeadlineMs = 5000

function Stop-MishCapacityProbe {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_CAPACITY_RESOURCE_FAILURE|$Category|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = @(& $AdbPath @Arguments 2>$null | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        Stop-MishCapacityProbe 'ADB_FAILED' "ADB command failed with exit code $exitCode: $($Arguments -join ' ')"
    }
    return ($output -join "`n").Trim()
}

function Test-MishIpv4InCidr {
    param(
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Cidr
    )
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { return $false }
    try {
        $addressBytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
        $networkBytes = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $prefix = [int]$parts[1]
    }
    catch { return $false }
    if ($addressBytes.Length -ne 4 -or $networkBytes.Length -ne 4 -or $prefix -lt 0 -or $prefix -gt 32) {
        return $false
    }
    for ($index = 0; $index -lt 4; $index++) {
        $remaining = $prefix - ($index * 8)
        $bits = [Math]::Min(8, [Math]::Max(0, $remaining))
        if ($bits -eq 0) { continue }
        $mask = (0xff -shl (8 - $bits)) -band 0xff
        if ((([int]$addressBytes[$index]) -band $mask) -ne (([int]$networkBytes[$index]) -band $mask)) {
            return $false
        }
    }
    return $true
}

function Get-MishAndroidSnapshot {
    $output = Invoke-MishAdbText -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    )
    $match = [regex]::Match($output, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) {
        Stop-MishCapacityProbe 'SNAPSHOT_INVALID' 'Android diagnostics returned no payload.'
    }
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        $snapshot = $json | ConvertFrom-Json
    }
    catch {
        Stop-MishCapacityProbe 'SNAPSHOT_INVALID' 'Android diagnostics payload is malformed.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if ([string]$snapshot.schema -cne $script:AndroidSchema -or [string]$snapshot.application_id -cne $PackageName) {
        Stop-MishCapacityProbe 'SNAPSHOT_IDENTITY_MISMATCH' 'Android diagnostics schema/package mismatch.'
    }
    if ($null -eq $snapshot.mesh.active_sessions -or $null -eq $snapshot.proxy.active_sessions) {
        Stop-MishCapacityProbe 'OWNER_COUNTERS_UNAVAILABLE' 'Owner-backed active session counters are unavailable.'
    }
    return $snapshot
}

function Wait-MishOwnerCounts {
    param(
        [Parameter(Mandatory)][int] $ExpectedMesh,
        [Parameter(Mandatory)][int] $ExpectedProxy
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    do {
        $last = Get-MishAndroidSnapshot
        $mesh = [int64]$last.mesh.active_sessions
        $proxy = [int64]$last.proxy.active_sessions
        if ($mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = [bool]$last.consistent
            }
        }
        Start-Sleep -Milliseconds 100
    } while ($watch.ElapsedMilliseconds -lt $script:CounterDeadlineMs)
    $watch.Stop()
    return [ordered]@{
        result = 'FAIL'
        elapsed_ms = [int64]$watch.ElapsedMilliseconds
        mesh_active_sessions = if ($null -ne $last) { [int64]$last.mesh.active_sessions } else { -1 }
        proxy_active_sessions = if ($null -ne $last) { [int64]$last.proxy.active_sessions } else { -1 }
        android_consistent = if ($null -ne $last) { [bool]$last.consistent } else { $false }
    }
}

function Read-MishStatusLine {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    $bytes = [Collections.Generic.List[byte]]::new()
    while ($bytes.Count -lt 1024) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) { return $null }
        $bytes.Add([byte]$value)
        $count = $bytes.Count
        if ($count -ge 2 -and $bytes[$count - 2] -eq 13 -and $bytes[$count - 1] -eq 10) {
            return [Text.Encoding]::ASCII.GetString($bytes.ToArray(), 0, $count - 2)
        }
    }
    return ''
}

function Open-MishHeldConnectSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $plainPassword = $null
    try {
        $connectTask = $client.ConnectAsync($ProxyHost, 3128)
        if (-not $connectTask.Wait($script:ConnectTimeoutMs) -or -not $client.Connected) {
            throw 'Mesh listener connection failed.'
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:ConnectTimeoutMs
        $stream.WriteTimeout = $script:ConnectTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $credentialBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($credentialBytes) }
        finally { [Array]::Clear($credentialBytes, 0, $credentialBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $request = "CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`nProxy-Connection: keep-alive`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        try {
            $stream.Write($requestBytes, 0, $requestBytes.Length)
            $stream.Flush()
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $request = $null
            $authorization = $null
            $plainPassword = $null
        }
        $status = Read-MishStatusLine -Stream $stream
        if ($null -eq $status -or $status -notmatch '^HTTP/1\.[01]\s+2\d\d(?:\s|$)') {
            throw "Authenticated CONNECT was not established: '$status'"
        }
        return [pscustomobject]@{ Client = $client; Stream = $stream; StatusLine = $status }
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishOverflowRejected {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $plainPassword = $null
    try {
        $connectTask = $client.ConnectAsync($ProxyHost, 3128)
        if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
            return [ordered]@{ result = 'PASS'; reason = 'CONNECT_TIMEOUT_BEFORE_ADMISSION' }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'PASS'; reason = 'CONNECT_REJECTED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = 1500
        $stream.WriteTimeout = 1500
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            $stream.Write($requestBytes, 0, $requestBytes.Length)
            $stream.Flush()
        }
        catch {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try { $status = Read-MishStatusLine -Stream $stream }
        catch { return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET' } }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'PASS'; reason = 'EDGE_REJECTED' }
    }
    finally {
        $plainPassword = $null
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
    }
}

function Get-MishProcessResources {
    param([Parameter(Mandatory)][string] $PidText)
    $status = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'cat', "/proc/$PidText/status")
    $threadsMatch = [regex]::Match($status, '(?m)^Threads:\s+(?<value>\d+)\s*$')
    $rssMatch = [regex]::Match($status, '(?m)^VmRSS:\s+(?<value>\d+)\s+kB\s*$')
    if (-not $threadsMatch.Success -or -not $rssMatch.Success) {
        Stop-MishCapacityProbe 'PROCESS_RESOURCE_PARSE_FAILED' 'Threads/VmRSS are unavailable from app-owned /proc status.'
    }
    $fdText = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'sh', '-c', "ls -1 /proc/$PidText/fd | wc -l")
    if ($fdText -notmatch '^\d+$') {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\s*$')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdText
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
    }
}

function New-MishStageObservation {
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][int] $ExpectedSessions,
        [Parameter(Mandatory)][string] $PidText
    )
    return [ordered]@{
        name = $Name
        expected_sessions = $ExpectedSessions
        owner_counts = Wait-MishOwnerCounts -ExpectedMesh $ExpectedSessions -ExpectedProxy $ExpectedSessions
        resources = Get-MishProcessResources -PidText $PidText
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishCapacityProbe 'ADB_MISSING' 'Canonical ADB executable is missing.'
}
Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force

$pidBefore = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
if ([string]::IsNullOrWhiteSpace($pidBefore) -or $pidBefore -match '\s') {
    Stop-MishCapacityProbe 'PRODUCT_PROCESS_NOT_RUNNING' 'Exactly one PRODUCT process is required.'
}

$addressOutput = Invoke-MishAdbText -Arguments @('shell', 'ip', '-o', '-4', 'addr', 'show')
$meshAddresses = @(
    [regex]::Matches($addressOutput, '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/\d+') |
        ForEach-Object { $_.Groups['ip'].Value } |
        Where-Object { Test-MishIpv4InCidr -Address $_ -Cidr $MeshCidr } |
        Sort-Object -Unique
)
if ($meshAddresses.Count -ne 1) {
    Stop-MishCapacityProbe 'MESH_ENDPOINT_NOT_UNIQUE' "Expected one Mesh address; observed $($meshAddresses.Count)."
}
$meshAddress = [string]$meshAddresses[0]
try { $route = Find-NetRoute -RemoteIPAddress $meshAddress -ErrorAction Stop }
catch { Stop-MishCapacityProbe 'WINDOWS_MESH_ROUTE_UNAVAILABLE' 'Windows has no route to the admitted Mesh endpoint.' }
if ($null -eq $route) {
    Stop-MishCapacityProbe 'WINDOWS_MESH_ROUTE_UNAVAILABLE' 'Windows has no route to the admitted Mesh endpoint.'
}

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    Stop-MishCapacityProbe 'TEMP_UNAVAILABLE' 'Temporary storage is unavailable.'
}
$credentialStorePath = Join-Path ([IO.Path]::GetFullPath($tempRoot)) ('mish-capacity-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
$lease = $null
$held = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$overflow = $null
$overflowCounts = $null
$cleanupCounts = $null
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $stages.Add((New-MishStageObservation -Name 'idle' -ExpectedSessions 0 -PidText $pidBefore))
    foreach ($target in @(10, 32, 64)) {
        while ($held.Count -lt $target) {
            $held.Add((Open-MishHeldConnectSession -ProxyHost $meshAddress -Lease $lease))
        }
        $stages.Add((New-MishStageObservation -Name "sessions_$target" -ExpectedSessions $target -PidText $pidBefore))
    }

    $overflow = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
    $overflowCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64

    $stageFailures = @($stages | Where-Object { [string]$_.owner_counts.result -cne 'PASS' }).Count
    if ($stageFailures -ne 0) {
        $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
    }
    elseif ([string]$overflow.result -cne 'PASS') {
        $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
    }
    elseif ([string]$overflowCounts.result -cne 'PASS') {
        $classification = 'U2_CAPACITY_OVERFLOW_REACHED_BACKEND'
    }
    else {
        $acceptanceResult = 'PASS'
        $classification = 'U2_CAPACITY_RESOURCE_PASS'
    }
}
finally {
    foreach ($session in @($held)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
    $held.Clear()
    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    stages = @($stages)
    overflow_65th = $overflow
    overflow_owner_counts = $overflowCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_resources = $postCleanupResources
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
