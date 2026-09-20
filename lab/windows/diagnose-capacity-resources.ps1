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
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $request = "HEAD / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: keep-alive`r`nUser-Agent: mish-capacity-probe/1`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        $Session.Stream.Write($requestBytes, 0, $requestBytes.Length)
        $Session.Stream.Flush()
        $status = Read-MishStatusLine -Stream $Session.Stream
        if ($null -eq $status) {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_EOF'; status_line = $null; elapsed_ms = [int64]$watch.ElapsedMilliseconds }
        }
        if ($status -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d(?:\s|$)') {
            return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_STATUS_INVALID'; status_line = $status; elapsed_ms = [int64]$watch.ElapsedMilliseconds }
        }
        $headers = Read-MishHeaders -Stream $Session.Stream -Context 'Target HTTP'
        if ([bool]$headers.connection_close) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_CONNECTION_CLOSE'; status_line = $status; elapsed_ms = [int64]$watch.ElapsedMilliseconds }
        }
        return [ordered]@{ result = 'PASS'; reason = 'NONE'; status_line = $status; elapsed_ms = [int64]$watch.ElapsedMilliseconds }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = 'APPLICATION_IO_FAILED'; error = $_.Exception.GetType().FullName; elapsed_ms = [int64]$watch.ElapsedMilliseconds }
    }
    finally {
        $watch.Stop()
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
    $setupWatch = [Diagnostics.Stopwatch]::StartNew()
    $meshConnectElapsedMs = $null
    try {
        $meshConnectWatch = [Diagnostics.Stopwatch]::StartNew()
        $connectTask = $client.ConnectAsync($ProxyHost, 3128)
        if (-not $connectTask.Wait($script:ConnectTimeoutMs) -or -not $client.Connected) {
            throw 'Mesh listener connection failed.'
        }
        $meshConnectWatch.Stop()
        $meshConnectElapsedMs = [int64]$meshConnectWatch.ElapsedMilliseconds
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
            MeshConnectElapsedMs = $meshConnectElapsedMs
            SetupElapsedMs = [int64]$setupWatch.ElapsedMilliseconds
        }
        $initial = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$initial.result -cne 'PASS') {
            throw "Initial target application round-trip failed: $([string]$initial.reason)"
        }
        $session | Add-Member -NotePropertyName InitialApplicationStatusLine -NotePropertyValue ([string]$initial.status_line)
        $session | Add-Member -NotePropertyName InitialApplicationElapsedMs -NotePropertyValue ([int64]$initial.elapsed_ms)
        return $session
    }
    catch {
        if ($null -ne $tlsStream) { $tlsStream.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        throw
    }
    finally {
        $setupWatch.Stop()
        $plainPassword = $null
    }
}

function Test-MishApplicationLiveSet {
    param(
        [Parameter(Mandatory)][object[]] $Sessions,
        [Parameter(Mandatory)][int] $ExpectedSessions
    )
    $results = [Collections.Generic.List[object]]::new()
    $latencies = [Collections.Generic.List[int64]]::new()
    $live = 0
    foreach ($session in $Sessions) {
        $roundTrip = Invoke-MishApplicationRoundTrip -Session $session
        if ([string]$roundTrip.result -ceq 'PASS') {
            $live++
            [void]$latencies.Add([int64]$roundTrip.elapsed_ms)
        }
        [void]$results.Add([ordered]@{
            ordinal = [int]$session.Ordinal
            result = [string]$roundTrip.result
            reason = [string]$roundTrip.reason
            elapsed_ms = [int64]$roundTrip.elapsed_ms
            status_line = if ($roundTrip.Contains('status_line')) { [string]$roundTrip.status_line } else { $null }
        })
    }
    return [ordered]@{
        result = if ($Sessions.Count -eq $ExpectedSessions -and $live -eq $ExpectedSessions) { 'PASS' } else { 'FAIL' }
        expected = $ExpectedSessions
        observed_sessions = $Sessions.Count
        application_live = $live
        application_round_trip_latency = Get-MishU7LatencyDistribution -Values @($latencies)
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

function Get-MishResourceDelta {
    param(
        [Parameter(Mandatory)] $Current,
        [Parameter(Mandatory)] $Baseline
    )
    return [ordered]@{
        threads = [int]$Current.threads - [int]$Baseline.threads
        fd_count = [int]$Current.fd_count - [int]$Baseline.fd_count
        rss_kb = [int64]$Current.rss_kb - [int64]$Baseline.rss_kb
        pss_kb = [int64]$Current.pss_kb - [int64]$Baseline.pss_kb
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishCapacityProbe 'ADB_MISSING' 'Canonical ADB executable is missing.'
}
Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'U7Measurement.psm1') -Force

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
$capacityContractPassed = $false

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) { Stop-MishCapacityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.' }

    $idleCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0
    $idleResources = Get-MishProcessResources -PidText $pidBefore
    $idleSupplemental = Measure-MishU7SupplementalObservation -AdbPath $AdbPath -PackageName $PackageName -PidText $pidBefore
    $idleOwnerDiagnostics = Get-MishSafeOwnerDiagnostics
    [void]$stages.Add([ordered]@{
        name = 'idle'
        expected_sessions = 0
        batch_model = 'independent_bounded'
        application_liveness = [ordered]@{ result = 'PASS'; expected = 0; application_live = 0; failures = @() }
        mesh_connect_latency = [ordered]@{ supported = $false; reason = 'NO_SESSIONS' }
        session_setup_latency = [ordered]@{ supported = $false; reason = 'NO_SESSIONS' }
        owner_counts = $idleCounts
        resources = $idleResources
        supplemental = $idleSupplemental
        owner_diagnostics = $idleOwnerDiagnostics
    })
    if ([string]$idleCounts.result -cne 'PASS') {
        $classification = 'LAB_CAPACITY_PRECONDITION_BUSY'
        $detail = 'Owner counters were not 0/0 before capacity testing.'
    }

    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
        foreach ($target in @(10, 32, 64, 512)) {
            $stageRecord = $null
            $stageCleanupCounts = $null
            $stageCleanupResources = $null
            $stageCleanupSupplemental = $null
            $stageCleanupOwnerDiagnostics = $null
            $stageCleanupElapsedMs = $null
            try {
                Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target

                $resources = Get-MishProcessResources -PidText $pidBefore
                $supplemental = Measure-MishU7SupplementalObservation -AdbPath $AdbPath -PackageName $PackageName -PidText $pidBefore
                $applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target
                $ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target
                $ownerDiagnostics = Get-MishSafeOwnerDiagnostics
                $meshConnectLatency = Get-MishU7LatencyDistribution -Values @($activeSessions | ForEach-Object { $_.MeshConnectElapsedMs })
                $sessionSetupLatency = Get-MishU7LatencyDistribution -Values @($activeSessions | ForEach-Object { $_.SetupElapsedMs })
                $initialApplicationLatency = Get-MishU7LatencyDistribution -Values @($activeSessions | ForEach-Object { $_.InitialApplicationElapsedMs })

                $stageRecord = [ordered]@{
                    name = "sessions_$target"
                    expected_sessions = $target
                    batch_model = 'independent_bounded'
                    application_liveness = $applicationLiveness
                    mesh_connect_latency = $meshConnectLatency
                    session_setup_latency = $sessionSetupLatency
                    initial_application_round_trip_latency = $initialApplicationLatency
                    target_outbound_connect_latency = [ordered]@{ supported = $false; reason = 'CURRENT_CONTROL_PATH_CANNOT_SEPARATE_PRODUCT_OUTBOUND_CONNECT_FROM_PROXY_SETUP' }
                    relay_throughput = [ordered]@{ supported = $false; reason = 'BOUNDED_HEAD_LIVENESS_PROBE_IS_NOT_A_STABLE_THROUGHPUT_LOAD' }
                    owner_counts = $ownerCounts
                    resources = $resources
                    supplemental = $supplemental
                    owner_diagnostics = $ownerDiagnostics
                }

                if ([string]$applicationLiveness.result -cne 'PASS') {
                    $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                    $detail = "The $target-session milestone was not fully application-live."
                }
                elseif ([string]$ownerCounts.result -cne 'PASS') {
                    $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                    $detail = "Client proved $target application-live sessions while owner counters diverged."
                }

                if ($target -eq 512 -and $classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
                    $preOverflowLiveness = $applicationLiveness
                    $preOverflowOwnerCounts = $ownerCounts
                    $attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease
                    [void]$overflowAttempts.Add([ordered]@{
                        ordinal = 513
                        result = [string]$attempt.result
                        reason = [string]$attempt.reason
                        status_line = if ($attempt.Contains('status_line')) { [string]$attempt.status_line } else { $null }
                    })
                    if ([string]$attempt.result -ceq 'FAIL') {
                        $classification = 'U7_CAPACITY_513TH_NOT_REJECTED'
                        $detail = 'Overflow attempt 513 reached Proxy Serving.'
                    }
                    elseif ([string]$attempt.result -ceq 'INCONCLUSIVE') {
                        $classification = 'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'
                        $detail = "Overflow attempt 513 was inconclusive: $([string]$attempt.reason)."
                    }

                    $postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 512
                    $overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 512 -ExpectedProxy 512
                    if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
                        if ([string]$postOverflowLiveness.result -cne 'PASS') {
                            $classification = 'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'
                            $detail = 'The original 512 lost application liveness after the overflow attempt.'
                        }
                        elseif ([string]$overflowOwnerCounts.result -cne 'PASS') {
                            $classification = 'U2_CAPACITY_OWNER_COUNT_MISMATCH'
                            $detail = 'The original 512 remained application-live after overflow while owner counters diverged.'
                        }
                        else {
                            $capacityContractPassed = $true
                        }
                    }
                }
            }
            catch {
                if ($classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
                    $classification = 'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'
                    $detail = $_.Exception.Message
                }
            }
            finally {
                $cleanupWatch = [Diagnostics.Stopwatch]::StartNew()
                Close-MishApplicationSet -Sessions @($activeSessions)
                $activeSessions.Clear()
                try { $stageCleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
                $cleanupWatch.Stop()
                $stageCleanupElapsedMs = [int64]$cleanupWatch.ElapsedMilliseconds
                try { $stageCleanupResources = Get-MishProcessResources -PidText $pidBefore } catch {}
                try { $stageCleanupSupplemental = Measure-MishU7SupplementalObservation -AdbPath $AdbPath -PackageName $PackageName -PidText $pidBefore } catch {}
                try { $stageCleanupOwnerDiagnostics = Get-MishSafeOwnerDiagnostics } catch {}
                $cleanupCounts = $stageCleanupCounts

                if ($null -ne $stageRecord) {
                    $stageRecord['cleanup'] = [ordered]@{
                        elapsed_ms = $stageCleanupElapsedMs
                        owner_counts = $stageCleanupCounts
                        resources = $stageCleanupResources
                        resource_delta_from_idle = if ($null -ne $stageCleanupResources) { Get-MishResourceDelta -Current $stageCleanupResources -Baseline $idleResources } else { $null }
                        supplemental = $stageCleanupSupplemental
                        owner_diagnostics = $stageCleanupOwnerDiagnostics
                    }
                    [void]$stages.Add($stageRecord)
                }

                if (($null -eq $stageCleanupCounts -or [string]$stageCleanupCounts.result -cne 'PASS') -and $classification -ceq 'U2_CAPACITY_RESOURCE_INCOMPLETE') {
                    $classification = 'U2_CAPACITY_CLEANUP_NOT_DRAINED'
                    $detail = "The $target-session phase did not return owner counts to 0/0."
                }
            }

            if ($classification -cne 'U2_CAPACITY_RESOURCE_INCOMPLETE') { break }
            if ($target -eq 512 -and $capacityContractPassed) {
                $acceptanceResult = 'PASS'
                $classification = 'U7_CAPACITY_512_PASS'
            }
        }
    }
}
finally {
    Close-MishApplicationSet -Sessions @($activeSessions)
    $activeSessions.Clear()
    if ($null -eq $cleanupCounts -or [string]$cleanupCounts.result -cne 'PASS') {
        try { $cleanupCounts = Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0 } catch {}
    }

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
elseif ($classification -in @('U2_CAPACITY_OWNER_COUNT_MISMATCH', 'U7_CAPACITY_513TH_NOT_REJECTED', 'U2_CAPACITY_CLEANUP_NOT_DRAINED')) {
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
    measurement_stage = 'U7'
    capacity_target = 512
    overflow_ordinal = 513
    acceptance_profile = 'u7-capacity-512-v1'
    batch_model = 'independent_bounded'
    measurement_limitations = [ordered]@{
        process_wakeups = 'UNSUPPORTED_NO_RELIABLE_PROCESS_COUNTER'
        target_outbound_connect_latency = 'UNSUPPORTED_WITHOUT_PRODUCT_INSTRUMENTATION'
        dns_latency_distribution = 'UNSUPPORTED_OWNER_EXPOSES_BOUNDED_MAX_ONLY'
        relay_throughput = 'UNSUPPORTED_BY_BOUNDED_HEAD_LIVENESS_PROFILE'
    }
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
