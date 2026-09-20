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
$script:OverflowTimeoutMs = 1500
$script:CpuSampleMs = 1000

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
        Stop-MishCapacityProbe 'ADB_FAILED' "ADB command failed with exit code ${exitCode}: $($Arguments -join ' ')"
    }
    return ($output -join "`n").Trim()
}


function Invoke-MishAdbOptionalText {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = @(& $AdbPath @Arguments 2>$null | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) { return $null }
    return ($output -join "`n").Trim()
}

function Get-MishLatencyDistribution {
    param([object[]] $Values)
    $samples = @(
        $Values |
            Where-Object { $null -ne $_ } |
            ForEach-Object { [int64]$_ } |
            Sort-Object
    )
    if ($samples.Count -eq 0) {
        return [ordered]@{ supported = $false; reason = 'NO_SAMPLES' }
    }
    $p50 = [Math]::Max(0, [Math]::Ceiling($samples.Count * 0.50) - 1)
    $p95 = [Math]::Max(0, [Math]::Ceiling($samples.Count * 0.95) - 1)
    $p99 = [Math]::Max(0, [Math]::Ceiling($samples.Count * 0.99) - 1)
    return [ordered]@{
        supported = $true
        count = $samples.Count
        min_ms = [int64]$samples[0]
        p50_ms = [int64]$samples[$p50]
        p95_ms = [int64]$samples[$p95]
        p99_ms = [int64]$samples[$p99]
        max_ms = [int64]$samples[$samples.Count - 1]
    }
}

function Get-MishCpuTickSnapshot {
    param([Parameter(Mandatory)][string] $PidText)
    $processStat = Invoke-MishAdbOptionalText -Arguments @('shell', 'run-as', $PackageName, 'cat', "/proc/$PidText/stat")
    $systemStat = Invoke-MishAdbOptionalText -Arguments @('shell', 'cat', '/proc/stat')
    $processStatus = Invoke-MishAdbOptionalText -Arguments @('shell', 'run-as', $PackageName, 'cat', "/proc/$PidText/status")
    if ([string]::IsNullOrWhiteSpace($processStat) -or [string]::IsNullOrWhiteSpace($systemStat)) { return $null }

    $close = $processStat.LastIndexOf(') ')
    if ($close -lt 0) { return $null }
    $tail = $processStat.Substring($close + 2)
    $fields = @($tail -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($fields.Count -lt 13) { return $null }
    try {
        $processTicks = [int64]$fields[11] + [int64]$fields[12]
    }
    catch { return $null }

    $cpuMatch = [regex]::Match($systemStat, '(?m)^cpu\s+(?<values>[0-9\s]+)
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
    if (-not $cpuMatch.Success) { return $null }
    $cpuValues = @($cpuMatch.Groups['values'].Value -split '\s+' | Where-Object { $_ -match '^\d+
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
 })
    if ($cpuValues.Count -lt 4) { return $null }
    [int64]$totalTicks = 0
    foreach ($value in $cpuValues) { $totalTicks += [int64]$value }
    $cpuCount = [regex]::Matches($systemStat, '(?m)^cpu\d+\s').Count
    if ($cpuCount -le 0) { return $null }

    $voluntary = $null
    $nonvoluntary = $null
    if (-not [string]::IsNullOrWhiteSpace($processStatus)) {
        $voluntaryMatch = [regex]::Match($processStatus, '(?m)^voluntary_ctxt_switches:\s*(?<value>\d+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
        $nonvoluntaryMatch = [regex]::Match($processStatus, '(?m)^nonvoluntary_ctxt_switches:\s*(?<value>\d+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
        if ($voluntaryMatch.Success) { $voluntary = [int64]$voluntaryMatch.Groups['value'].Value }
        if ($nonvoluntaryMatch.Success) { $nonvoluntary = [int64]$nonvoluntaryMatch.Groups['value'].Value }
    }

    return [ordered]@{
        process_ticks = $processTicks
        system_ticks = $totalTicks
        cpu_count = $cpuCount
        voluntary_context_switches = $voluntary
        nonvoluntary_context_switches = $nonvoluntary
    }
}

function Get-MishCpuObservation {
    param([Parameter(Mandatory)][string] $PidText)
    $before = Get-MishCpuTickSnapshot -PidText $PidText
    if ($null -eq $before) {
        return [ordered]@{ supported = $false; reason = 'PROC_CPU_UNAVAILABLE' }
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds $script:CpuSampleMs
    $after = Get-MishCpuTickSnapshot -PidText $PidText
    $watch.Stop()
    if ($null -eq $after) {
        return [ordered]@{ supported = $false; reason = 'PROC_CPU_UNAVAILABLE' }
    }
    $processDelta = [int64]$after.process_ticks - [int64]$before.process_ticks
    $systemDelta = [int64]$after.system_ticks - [int64]$before.system_ticks
    if ($processDelta -lt 0 -or $systemDelta -le 0) {
        return [ordered]@{ supported = $false; reason = 'PROC_CPU_DELTA_INVALID' }
    }
    $capacityPercent = 100.0 * [double]$processDelta / [double]$systemDelta
    $oneCorePercent = $capacityPercent * [int]$after.cpu_count
    return [ordered]@{
        supported = $true
        sample_elapsed_ms = [int64]$watch.ElapsedMilliseconds
        cpu_count = [int]$after.cpu_count
        process_cpu_percent_total_capacity = [Math]::Round($capacityPercent, 3)
        process_cpu_percent_one_core_equivalent = [Math]::Round($oneCorePercent, 3)
        voluntary_context_switches_delta = if ($null -ne $before.voluntary_context_switches -and $null -ne $after.voluntary_context_switches) { [int64]$after.voluntary_context_switches - [int64]$before.voluntary_context_switches } else { $null }
        nonvoluntary_context_switches_delta = if ($null -ne $before.nonvoluntary_context_switches -and $null -ne $after.nonvoluntary_context_switches) { [int64]$after.nonvoluntary_context_switches - [int64]$before.nonvoluntary_context_switches } else { $null }
        wakeups_supported = $false
        wakeups_reason = 'NO_RELIABLE_PROCESS_WAKEUP_COUNTER_IN_CURRENT_CONTROL_PATH'
    }
}

function Get-MishThreadObservation {
    param([Parameter(Mandatory)][string] $PidText)
    $namesText = Invoke-MishAdbOptionalText -Arguments @('shell', 'run-as', $PackageName, 'sh', '-c', "cat /proc/$PidText/task/*/comm")
    if ([string]::IsNullOrWhiteSpace($namesText)) {
        return [ordered]@{ supported = $false; reason = 'THREAD_NAMES_UNAVAILABLE' }
    }
    $names = @($namesText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    return [ordered]@{
        supported = $true
        observed_threads = $names.Count
        product_tokio_named_threads = @($names | Where-Object { $_ -ceq 'mish-runtime-io' }).Count
    }
}

function Get-MishPlatformObservation {
    param([Parameter(Mandatory)][string] $PidText)
    $batteryText = Invoke-MishAdbOptionalText -Arguments @('shell', 'dumpsys', 'battery')
    $thermalText = Invoke-MishAdbOptionalText -Arguments @('shell', 'dumpsys', 'thermalservice')
    $psText = Invoke-MishAdbOptionalText -Arguments @('shell', 'ps', '-A', '-o', 'PID,PPID,NAME')

    $battery = [ordered]@{ supported = $false; reason = 'BATTERY_UNAVAILABLE' }
    if (-not [string]::IsNullOrWhiteSpace($batteryText)) {
        $level = [regex]::Match($batteryText, '(?m)^\s*level:\s*(?<value>\d+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
        $scale = [regex]::Match($batteryText, '(?m)^\s*scale:\s*(?<value>\d+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
        $temperature = [regex]::Match($batteryText, '(?m)^\s*temperature:\s*(?<value>-?\d+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
        $plugged = [regex]::Match($batteryText, '(?m)^\s*plugged:\s*(?<value>\d+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
        $status = [regex]::Match($batteryText, '(?m)^\s*status:\s*(?<value>\d+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
        if ($level.Success -and $scale.Success) {
            $battery = [ordered]@{
                supported = $true
                level = [int]$level.Groups['value'].Value
                scale = [int]$scale.Groups['value'].Value
                temperature_deci_c = if ($temperature.Success) { [int]$temperature.Groups['value'].Value } else { $null }
                plugged = if ($plugged.Success) { [int]$plugged.Groups['value'].Value } else { $null }
                status = if ($status.Success) { [int]$status.Groups['value'].Value } else { $null }
            }
        }
    }

    $thermal = [ordered]@{ supported = $false; reason = 'THERMAL_STATUS_UNAVAILABLE' }
    if (-not [string]::IsNullOrWhiteSpace($thermalText)) {
        $thermalMatch = [regex]::Match($thermalText, '(?im)^\s*(?:current\s+)?thermal\s+status:\s*(?<value>\d+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
        if ($thermalMatch.Success) {
            $thermal = [ordered]@{ supported = $true; status = [int]$thermalMatch.Groups['value'].Value }
        }
    }

    $rootProcesses = [ordered]@{ supported = $false; reason = 'PROCESS_TREE_UNAVAILABLE' }
    if (-not [string]::IsNullOrWhiteSpace($psText)) {
        $rows = [Collections.Generic.List[object]]::new()
        foreach ($line in ($psText -split "`r?`n")) {
            $match = [regex]::Match($line, '^\s*(?<pid>\d+)\s+(?<ppid>\d+)\s+(?<name>\S+)\s*
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
)
            if ($match.Success) {
                [void]$rows.Add([pscustomobject]@{
                    pid = [int]$match.Groups['pid'].Value
                    ppid = [int]$match.Groups['ppid'].Value
                    name = [string]$match.Groups['name'].Value
                })
            }
        }
        if ($rows.Count -gt 0) {
            $descendantIds = [Collections.Generic.HashSet[int]]::new()
            [void]$descendantIds.Add([int]$PidText)
            $changed = $true
            while ($changed) {
                $changed = $false
                foreach ($row in $rows) {
                    if ($descendantIds.Contains([int]$row.ppid) -and -not $descendantIds.Contains([int]$row.pid)) {
                        [void]$descendantIds.Add([int]$row.pid)
                        $changed = $true
                    }
                }
            }
            $descendants = @($rows | Where-Object { [int]$_.pid -ne [int]$PidText -and $descendantIds.Contains([int]$_.pid) })
            $rootProcesses = [ordered]@{
                supported = $true
                product_descendant_processes = $descendants.Count
                product_su_like_descendants = @($descendants | Where-Object { [string]$_.name -in @('su', 'magisk') }).Count
            }
        }
    }

    return [ordered]@{
        battery = $battery
        thermal = $thermal
        root_processes = $rootProcesses
    }
}

function Get-MishSafeOwnerDiagnostics {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $snapshot = Get-MishAndroidSnapshot
    $watch.Stop()
    return [ordered]@{
        capture_elapsed_ms = [int64]$watch.ElapsedMilliseconds
        consistent = [bool]$snapshot.consistent
        runtime_generation = [int64]$snapshot.runtime.generation
        dns = [ordered]@{
            started = [int64]$snapshot.cellular.dns.started
            completed = [int64]$snapshot.cellular.dns.completed
            active = [int64]$snapshot.cellular.dns.active
            peak_active = [int64]$snapshot.cellular.dns.peak_active
            slow_completions = [int64]$snapshot.cellular.dns.slow_completions
            resolver_failed = [int64]$snapshot.cellular.dns.resolver_failed
            discarded_after_deadline = [int64]$snapshot.cellular.dns.discarded_after_deadline
            completed_after_owner_change = [int64]$snapshot.cellular.dns.completed_after_owner_change
            discarded_stale = [int64]$snapshot.cellular.dns.discarded_stale
            authority_validation_failed = [int64]$snapshot.cellular.dns.authority_validation_failed
            unusable_result = [int64]$snapshot.cellular.dns.unusable_result
            accepted_current = [int64]$snapshot.cellular.dns.accepted_current
            max_native_elapsed_ms = [int64]$snapshot.cellular.dns.max_native_elapsed_ms
            latency_distribution_supported = $false
            latency_distribution_reason = 'OWNER_EXPOSES_BOUNDED_MAX_NOT_HISTOGRAM'
        }
        root = [ordered]@{
            session_generation = if ($null -ne $snapshot.root.session_generation) { [int64]$snapshot.root.session_generation } else { $null }
            policy_authorized = [bool]$snapshot.root.policy_authorized
            reconcile_attempts = [int64]$snapshot.root.reconcile.attempts
            total_executor_commands = [int64]$snapshot.root.reconcile.total_executor_commands
            total_observation_commands = [int64]$snapshot.root.reconcile.total_observation_commands
            total_mutation_commands = [int64]$snapshot.root.reconcile.total_mutation_commands
            last_reconcile_elapsed_ms = [int64]$snapshot.root.reconcile.last_reconcile_elapsed_ms
            max_reconcile_elapsed_ms = [int64]$snapshot.root.reconcile.max_reconcile_elapsed_ms
            last_policy_effect_elapsed_ms = [int64]$snapshot.root.reconcile.last_policy_effect_elapsed_ms
            max_policy_effect_elapsed_ms = [int64]$snapshot.root.reconcile.max_policy_effect_elapsed_ms
        }
        proxy_active_sessions = [int64]$snapshot.proxy.active_sessions
        mesh_active_sessions = [int64]$snapshot.mesh.active_sessions
        rotation_active_tasks = [int64]$snapshot.rotation.active_tasks
        readiness_state = [string]$snapshot.readiness.state
    }
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
    $bytes = $null
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
        if ([bool]$last.consistent -and $mesh -eq $ExpectedMesh -and $proxy -eq $ExpectedProxy) {
            $watch.Stop()
            return [ordered]@{
                result = 'PASS'
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                mesh_active_sessions = $mesh
                proxy_active_sessions = $proxy
                android_consistent = $true
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

function Read-MishHeaders {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Context
    )
    $connectionClose = $false
    for ($index = 0; $index -lt 64; $index++) {
        $line = Read-MishStatusLine -Stream $Stream
        if ($null -eq $line) {
            throw "$Context closed before response headers completed."
        }
        if ($line.Length -eq 0) {
            return [ordered]@{ connection_close = $connectionClose }
        }
        if ($line -imatch '^Connection\s*:\s*close\s*$') {
            $connectionClose = $true
        }
    }
    throw "$Context response headers exceeded the bounded parser limit."
}

function Read-MishConnectHeaders {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)
    [void](Read-MishHeaders -Stream $Stream -Context 'Proxy CONNECT')
}

function Invoke-MishApplicationRoundTrip {
    param([Parameter(Mandatory)] $Session)
    $requestBytes = $null
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName }
    }
    finally {
        if ($null -ne $requestBytes) { [Array]::Clear($requestBytes, 0, $requestBytes.Length) }
    }
}

function Open-MishApplicationSession {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $Ordinal
    )
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $tlsStream = $null
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
        Read-MishConnectHeaders -Stream $stream
        $tlsStream = [Net.Security.SslStream]::new($stream, $false)
        $tlsStream.ReadTimeout = $script:ConnectTimeoutMs
        $tlsStream.WriteTimeout = $script:ConnectTimeoutMs
        $tlsStream.AuthenticateAsClient($TargetHost)

        $session = [pscustomobject]@{
            Ordinal = $Ordinal
            Client = $client
            Stream = $tlsStream
            ConnectStatusLine = $status
            HeldProtocol = 'TLS+HTTP'
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') { $live++ }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        failures = @($results | Where-Object { [string]$_.result -cne 'PASS' })
    }
}

function Add-MishApplicationSessionsUntil {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    if ($Sessions.Count -gt $ExpectedSessions) {
        throw "Session set already exceeds requested target $ExpectedSessions."
    }
    for ($ordinal = $Sessions.Count + 1; $ordinal -le $ExpectedSessions; $ordinal++) {
        [void]$Sessions.Add((Open-MishApplicationSession -ProxyHost $ProxyHost -Lease $Lease -Ordinal $ordinal))
    }
}

function Close-MishApplicationSet {
    param([object[]] $Sessions)
    foreach ($session in @($Sessions)) {
        try { if ($null -ne $session.Stream) { $session.Stream.Dispose() } } catch {}
        try { if ($null -ne $session.Client) { $session.Client.Dispose() } } catch {}
    }
}

function Test-MishTimeoutException {
    param([Parameter(Mandatory)][Exception] $Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [Net.Sockets.SocketException] -and $current.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            return $true
        }
        $current = $current.InnerException
    }
    return $false
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
        try {
            $connectTask = $client.ConnectAsync($ProxyHost, 3128)
            if (-not $connectTask.Wait($script:ConnectTimeoutMs)) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_TIMEOUT' }
            }
        }
        catch {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_FAILED'; error = $_.Exception.GetType().FullName }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_CONNECT_NOT_ESTABLISHED' }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $script:OverflowTimeoutMs
        $stream.WriteTimeout = $script:OverflowTimeoutMs
        $plainPassword = [Net.NetworkCredential]::new('', [Security.SecureString]$Lease.ProxyPassword).Password
        $authBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($authBytes) }
        finally { [Array]::Clear($authBytes, 0, $authBytes.Length) }
        $authority = "${TargetHost}:$TargetPort"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes("CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`n`r`n")
        try {
            try {
                $stream.Write($requestBytes, 0, $requestBytes.Length)
                $stream.Flush()
            }
            catch {
                if (Test-MishTimeoutException -Exception $_.Exception) {
                    return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_WRITE_TIMEOUT' }
                }
                return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_ON_WRITE' }
            }
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $authorization = $null
            $plainPassword = $null
        }
        try {
            $status = Read-MishStatusLine -Stream $stream
        }
        catch {
            if (Test-MishTimeoutException -Exception $_.Exception) {
                return [ordered]@{ result = 'INCONCLUSIVE'; reason = 'EDGE_READ_TIMEOUT' }
            }
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_RESET_BEFORE_PROXY_STATUS' }
        }
        if ($null -eq $status) {
            return [ordered]@{ result = 'PASS'; reason = 'EDGE_CLOSED_BEFORE_PROXY_STATUS' }
        }
        return [ordered]@{ result = 'FAIL'; reason = 'OVERFLOW_REACHED_PROXY'; status_line = $status }
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
    $fdListing = Invoke-MishAdbText -Arguments @('shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$PidText/fd")
    $fdCount = @($fdListing -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishCapacityProbe 'FD_COUNT_PARSE_FAILED' 'FD count is unavailable from app-owned /proc.'
    }
    $meminfo = Invoke-MishAdbText -Arguments @('shell', 'dumpsys', 'meminfo', '-s', $PidText)
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishCapacityProbe 'PSS_PARSE_FAILED' 'PSS is unavailable from dumpsys meminfo.'
    }
    return [ordered]@{
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
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
$activeSessions = [Collections.Generic.List[object]]::new()
$stages = [Collections.Generic.List[object]]::new()
$preOverflowLiveness = $null
$preOverflowOwnerCounts = $null
$overflowAttempts = [Collections.Generic.List[object]]::new()
$overflowOwnerCounts = $null
$postOverflowLiveness = $null
$cleanupCounts = $null
$postCleanupMeshE2e = [ordered]@{ result = 'NOT_RUN'; reason = 'NOT_RUN' }
$postCleanupResources = $null
$acceptanceResult = 'FAIL'
$classification = 'U2_CAPACITY_RESOURCE_INCOMPLETE'
$detail = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'single_monotonic'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        owner_counts = $idleCounts
        resources = $idleResources
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64)) {
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target
            }
            catch {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = $_.Exception.Message
                break
            }

            $resources = Get-MishProcessResources -PidText $pidBefore
            $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
            $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
            [void]$stages.Add([ordered]@{
                name = "sessions_$target"
                expected_sessions = $target
                batch_model = 'single_monotonic'
                application_liveness = $applicationLiveness
                owner_counts = $ownerCounts
                resources = $resources
            })

            if ([string]$applicationLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                $detail = "The $target-session milestone was not fully application-live."
                break
            }
            if ([string]$ownerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = "Client proved $target application-live sessions while owner counters diverged."
                break
            }

            if ($target -eq 64) {
                $preOverflowLiveness = $applicationLiveness
                $preOverflowOwnerCounts = $ownerCounts
            }
        }
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE' -and $activeSessions.Count -eq 64) {
        $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
        [void]$overflowAttempts.Add([ordered]@{
            ordinal = 65
            result = [string]$attempt.result
            reason = [string]$attempt.reason
            status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
        })
        if ([string]$attempt.result -ceq 'FAIL') {
            $classification = 'U2_CAPACITY_65TH_NOT_REJECTED'
            $detail = 'Overflow attempt 65 reached Proxy Serving.'
        }
        elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
            $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
            $detail = "Overflow attempt 65 was inconclusive: $([string]$attempt.reason)."
        }

        $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64
        $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64
        if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
            if ([string]$postOverflowLiveness.result -cne 'PASS') {
                $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                $detail = 'The original 64 lost application liveness after the overflow attempt.'
            }
            elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                $detail = 'The original 64 remained application-live after overflow while owner counters diverged.'
            }
            else {
                $acceptanceResult = 'PASS'
                $classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}

    if ($null -ne $lease -and $null -ne $cleanupCounts -and [string]$cleanupCounts.result -ceq 'PASS') {
        $postCleanupSession = $null
        try {
            $postCleanupSession = Open-MishApplicationSession -ProxyHost $meshAddress -Lease $lease -Ordinal 1
            $postCleanupMeshE2e = [ordered]@{ result = 'PASS'; reason = 'NONE' }
        }
        catch {
            $postCleanupMeshE2e = [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_ROUND_TRIP_FAILED'; error = $_.Exception.GetType().FullName }
        }
        finally {
            if ($null -ne $postCleanupSession) {
                Close-MishApplicationSet -Sessions @($postCleanupSession)
                try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
            }
        }
    }

    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    try { $postCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    $acceptanceResult = 'FAIL'
    $classification = 'INVALID_PROCESS_CHANGED_DURING_CAPACITY_PROBE'
}
elseif ($classification -like 'LAB_*') {
    $acceptanceResult = 'FAIL'
}
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U2_CAPACITY_65TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
    $acceptanceResult = 'FAIL'
}
elseif ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
}
elseif ($null -eq $postCleanupResources) {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE'
}
elseif ([string]$postCleanupMeshE2e.result -cne 'PASS') {
    $acceptanceResult = 'FAIL'
    $classification = 'LAB_POST_CLEANUP_MESH_E2E_FAILED'
}

$resourceSummary = $null
if ($stages.Count -ge 1 -and $null -ne $postCleanupResources) {
    $idle = $stages[0].resources
    $peakThreads = ($stages | ForEach-Object { [int]$_.resources.threads } | Measure-Object -Maximum).Maximum
    $peakFd = ($stages | ForEach-Object { [int]$_.resources.fd_count } | Measure-Object -Maximum).Maximum
    $peakRss = ($stages | ForEach-Object { [int64]$_.resources.rss_kb } | Measure-Object -Maximum).Maximum
    $peakPss = ($stages | ForEach-Object { [int64]$_.resources.pss_kb } | Measure-Object -Maximum).Maximum
    $resourceSummary = [ordered]@{
        idle = $idle
        peak = [ordered]@{
            threads = [int]$peakThreads
            fd_count = [int]$peakFd
            rss_kb = [int64]$peakRss
            pss_kb = [int64]$peakPss
        }
        post_cleanup = $postCleanupResources
        post_cleanup_delta_from_idle = [ordered]@{
            threads = [int]$postCleanupResources.threads - [int]$idle.threads
            fd_count = [int]$postCleanupResources.fd_count - [int]$idle.fd_count
            rss_kb = [int64]$postCleanupResources.rss_kb - [int64]$idle.rss_kb
            pss_kb = [int64]$postCleanupResources.pss_kb - [int64]$idle.pss_kb
        }
    }
}

$evidence = [ordered]@{
    schema = 'mish.lab.capacity-resources/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    product_pid = [string]$pidBefore
    pid_stable = $pidStable
    mesh_address = $meshAddress
    target = "${TargetHost}:$TargetPort"
    held_session_protocol = 'TLS+HTTP'
    application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'
    acceptance_profile = 'fast-linear-v1'
    batch_model = 'single_monotonic'
    stages = @($stages)
    pre_overflow_application_liveness = $preOverflowLiveness
    pre_overflow_owner_counts = $preOverflowOwnerCounts
    overflow_attempts = @($overflowAttempts)
    post_overflow_application_liveness = $postOverflowLiveness
    overflow_owner_counts = $overflowOwnerCounts
    cleanup_owner_counts = $cleanupCounts
    post_cleanup_mesh_e2e = $postCleanupMeshE2e
    resource_summary = $resourceSummary
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_CAPACITY_RESOURCE_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_CAPACITY_RESOURCE_CLASSIFICATION=$classification"
Write-Host "MISH_CAPACITY_RESOURCE_EVIDENCE=$fullEvidencePath"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_CAPACITY_RESOURCE_RESULT|$acceptanceResult|$classification"
}
