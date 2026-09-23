[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [ValidateRange(120, 600)][int] $SoakSeconds = 300,
    [ValidateRange(10, 60)][int] $SampleIntervalSeconds = 20,
    [ValidateRange(60, 300)][int] $RecoveryTimeoutSeconds = 180,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8-durability-soak-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ProductMethod = 'snapshot_v2'
$script:ControlMethod = 'control_snapshot_v1'
$script:ControlSchema = 'mish.control.diagnostics/v1'
$script:ProxyPort = 3128
$script:TargetHost = 'www.cloudflare.com'
$script:TargetPort = 443
$script:ControlPayloadMonthlyBudgetBytes = 10MB
$script:Crlf = [Environment]::NewLine
$script:CredentialStorePath = $null
$script:LiveTunnel = $null

function Stop-MishU8F {
    param([Parameter(Mandatory)][string] $Classification, [Parameter(Mandatory)][string] $Message)
    throw "MISH_U8F_FAILURE|$Classification|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments, [string] $Operation = 'adb')
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exit = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    if ($exit -ne 0) { Stop-MishU8F 'LAB_ADB_FAILED' "ADB operation '$Operation' failed." }
    return ($rows -join [Environment]::NewLine).Trim()
}

function Read-MishProviderSnapshot {
    param([Parameter(Mandatory)][string] $Method)
    $raw = Invoke-MishAdbText -Operation "provider_$Method" -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $Method
    )
    $match = [regex]::Match($raw, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { Stop-MishU8F 'LAB_DIAGNOSTIC_PAYLOAD_MISSING' "No payload for $Method." }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch { Stop-MishU8F 'LAB_DIAGNOSTIC_PAYLOAD_INVALID' "Malformed payload for $Method." }
    finally { if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Invoke-MishCanonicalDiagnostic {
    param([Parameter(Mandatory)][string] $Path)
    $diagnosticArgs = @{
        AdbPath = $AdbPath
        PackageName = $PackageName
        EvidencePath = $Path
    }
    & (Join-Path $PSScriptRoot 'collect-device-diagnostic.ps1') @diagnosticArgs | Out-Host
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-MishU8F 'LAB_CANONICAL_DIAGNOSTIC_MISSING' 'Canonical diagnostic evidence is missing.'
    }
    $diagnostic = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    if ([string]$diagnostic.classification -cne 'PASS') {
        Stop-MishU8F 'PRODUCT_NOT_READY' "Canonical diagnostic classification is $([string]$diagnostic.classification)."
    }
    return $diagnostic
}

function Assert-MishControlReady {
    param([Parameter(Mandatory)] $Snapshot, [Parameter(Mandatory)][int] $ExpectedPid)
    if (
        [string]$Snapshot.schema -cne $script:ControlSchema -or
        [int]$Snapshot.pid -ne $ExpectedPid -or
        [string]$Snapshot.control.state -cne 'READY' -or
        [int64]$Snapshot.control.application_heartbeat_count -ne 0 -or
        $null -eq $Snapshot.control.session_age_ms
    ) {
        Stop-MishU8F 'CONTROL_NOT_READY' 'Control owner is not one heartbeat-free READY session.'
    }
}

function Get-MishProcessMetrics {
    param([Parameter(Mandatory)] $Android)
    [int]$processId = [int]$Android.pid
    $pidText = Invoke-MishAdbText -Operation 'pidof' -Arguments @('shell', 'pidof', $PackageName)
    if ($pidText -notmatch '^\d+$' -or [int]$pidText -ne $processId) {
        Stop-MishU8F 'PRODUCT_PID_UNSTABLE' 'Exactly one current PRODUCT PID is required.'
    }

    $status = Invoke-MishAdbText -Operation 'proc_status' -Arguments @(
        'shell', 'run-as', $PackageName, 'cat', "/proc/$processId/status"
    )
    $threads = [regex]::Match($status, '(?m)^Threads:\s+(?<v>\d+)\s*$')
    $rss = [regex]::Match($status, '(?m)^VmRSS:\s+(?<v>\d+)\s+kB\s*$')
    if (-not $threads.Success -or -not $rss.Success) {
        Stop-MishU8F 'LAB_PROCESS_METRICS_UNAVAILABLE' 'Threads/VmRSS are unavailable.'
    }

    $fds = Invoke-MishAdbText -Operation 'fd_count' -Arguments @(
        'shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$processId/fd"
    )
    $fdCount = @($fds -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) { Stop-MishU8F 'LAB_PROCESS_METRICS_UNAVAILABLE' 'FD count is unavailable.' }

    $meminfo = Invoke-MishAdbText -Operation 'meminfo' -Arguments @('shell', 'dumpsys', 'meminfo', '-s', [string]$processId)
    $pss = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<v>\d+)\b')
    if (-not $pss.Success) { $pss = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<v>\d+)\s+') }
    if (-not $pss.Success) { Stop-MishU8F 'LAB_PROCESS_METRICS_UNAVAILABLE' 'PSS is unavailable.' }

    return [ordered]@{
        pid = $processId
        threads = [int]$threads.Groups['v'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rss.Groups['v'].Value
        pss_kb = [int64]$pss.Groups['v'].Value
        runtime_generation = [int64]$Android.runtime.generation
        runtime_active_tasks = [int64]$Android.runtime.active_tasks
        proxy_active_sessions = [int64]$Android.proxy.active_sessions
        mesh_active_sessions = if ($null -eq $Android.mesh.active_sessions) { $null } else { [int64]$Android.mesh.active_sessions }
        rotation_active_tasks = [int64]$Android.rotation.active_tasks
        credential_version = if ($null -eq $Android.credential.version) { $null } else { [int64]$Android.credential.version }
    }
}

function Test-MishIpv4InCidr {
    param([Parameter(Mandatory)][string] $Address, [Parameter(Mandatory)][string] $Cidr)
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { return $false }
    try {
        $a = [Net.IPAddress]::Parse($Address).GetAddressBytes()
        $n = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $prefix = [int]$parts[1]
    } catch { return $false }
    if ($a.Length -ne 4 -or $n.Length -ne 4 -or $prefix -lt 0 -or $prefix -gt 32) { return $false }
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $prefix - (8 * $i)))
        if ($bits -eq 0) { continue }
        $mask = (0xff -shl (8 - $bits)) -band 0xff
        if ((([int]$a[$i]) -band $mask) -ne (([int]$n[$i]) -band $mask)) { return $false }
    }
    return $true
}

function Get-MishMeshAddress {
    $raw = Invoke-MishAdbText -Operation 'mesh_address' -Arguments @('shell', 'ip', '-o', '-4', 'addr', 'show')
    $addresses = @(
        [regex]::Matches($raw, '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/\d+') |
            ForEach-Object { $_.Groups['ip'].Value } |
            Where-Object { Test-MishIpv4InCidr -Address $_ -Cidr $MeshCidr } |
            Sort-Object -Unique
    )
    if ($addresses.Count -ne 1) { Stop-MishU8F 'LAB_MESH_ENDPOINT_AMBIGUOUS' 'Exactly one Mesh endpoint is required.' }
    return [string]$addresses[0]
}

function Read-MishHeaders {
    param([Parameter(Mandatory)][IO.Stream] $Stream)
    $buffer = [Collections.Generic.List[byte]]::new()
    $one = [byte[]]::new(1)
    for ($i = 0; $i -lt 16384; $i++) {
        if ($Stream.Read($one, 0, 1) -ne 1) { Stop-MishU8F 'PRODUCT_LONG_LIVED_SESSION_CLOSED' 'Long-lived stream closed.' }
        [void]$buffer.Add($one[0])
        $c = $buffer.Count
        if ($c -ge 4 -and $buffer[$c-4] -eq 13 -and $buffer[$c-3] -eq 10 -and $buffer[$c-2] -eq 13 -and $buffer[$c-1] -eq 10) {
            return [Text.Encoding]::ASCII.GetString($buffer.ToArray())
        }
    }
    Stop-MishU8F 'LAB_LONG_LIVED_RESPONSE_INVALID' 'HTTP headers exceeded the bounded limit.'
}

function Open-MishLongLivedTunnel {
    param([Parameter(Mandatory)][string] $ProxyHost, [Parameter(Mandatory)] $Lease)
    $client = [Net.Sockets.TcpClient]::new()
    $network = $null
    $ssl = $null
    $plainPassword = $null
    try {
        $task = $client.ConnectAsync($ProxyHost, $script:ProxyPort)
        if (-not $task.Wait(10000) -or -not $client.Connected) {
            Stop-MishU8F 'PRODUCT_LONG_LIVED_CONNECT_FAILED' 'Mesh proxy listener connect failed.'
        }
        $network = $client.GetStream()
        $network.ReadTimeout = 10000
        $network.WriteTimeout = 10000

        $plainPassword = [Net.NetworkCredential]::new('', $Lease.ProxyPassword).Password
        $credentialBytes = [Text.Encoding]::UTF8.GetBytes("$([string]$Lease.ProxyUserName):$plainPassword")
        try { $authorization = [Convert]::ToBase64String($credentialBytes) }
        finally { [Array]::Clear($credentialBytes, 0, $credentialBytes.Length); $plainPassword = $null }

        $authority = "$($script:TargetHost):$($script:TargetPort)"
        $request = "CONNECT $authority HTTP/1.1$($script:Crlf)Host: $authority$($script:Crlf)Proxy-Authorization: Basic $authorization$($script:Crlf)Proxy-Connection: keep-alive$($script:Crlf)$($script:Crlf)"
        $bytes = [Text.Encoding]::ASCII.GetBytes($request)
        try { $network.Write($bytes, 0, $bytes.Length); $network.Flush() }
        finally { [Array]::Clear($bytes, 0, $bytes.Length); $request = $null; $authorization = $null }

        $headers = Read-MishHeaders -Stream $network
        if ($headers -notmatch '^HTTP/1\.[01]\s+200\b') {
            Stop-MishU8F 'PRODUCT_LONG_LIVED_CONNECT_REJECTED' 'Authenticated HTTP CONNECT did not return 200.'
        }

        $ssl = [Net.Security.SslStream]::new($network, $false)
        $ssl.ReadTimeout = 10000
        $ssl.WriteTimeout = 10000
        $ssl.AuthenticateAsClient($script:TargetHost)
        return [pscustomobject]@{ Client = $client; Ssl = $ssl; Pulses = 0; Opened = [DateTimeOffset]::UtcNow }
    }
    catch {
        if ($null -ne $ssl) { $ssl.Dispose() }
        elseif ($null -ne $network) { $network.Dispose() }
        $client.Dispose()
        throw
    }
    finally { $plainPassword = $null }
}

function Invoke-MishTunnelPulse {
    param([Parameter(Mandatory)] $Tunnel)
    $request = "HEAD / HTTP/1.1$($script:Crlf)Host: $($script:TargetHost)$($script:Crlf)Connection: keep-alive$($script:Crlf)User-Agent: mobile-proxy-mish-u8f/1$($script:Crlf)$($script:Crlf)"
    $bytes = [Text.Encoding]::ASCII.GetBytes($request)
    try { $Tunnel.Ssl.Write($bytes, 0, $bytes.Length); $Tunnel.Ssl.Flush() }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    $headers = Read-MishHeaders -Stream $Tunnel.Ssl
    if ($headers -notmatch '^HTTP/1\.[01]\s+[1-5]\d\d\b') {
        Stop-MishU8F 'PRODUCT_LONG_LIVED_RELAY_FAILED' 'Long-lived TLS tunnel returned no HTTP response.'
    }
    if ($headers -match '(?im)^Connection:\s*close\s*$') {
        Stop-MishU8F 'LAB_LONG_LIVED_FIXTURE_CLOSED' 'External fixture requested connection close.'
    }
    $Tunnel.Pulses = [int]$Tunnel.Pulses + 1
}

function Close-MishTunnel {
    param($Tunnel)
    if ($null -eq $Tunnel) { return }
    try { $Tunnel.Ssl.Dispose() } catch {}
    try { $Tunnel.Client.Dispose() } catch {}
}

function Wait-MishQuiescence {
    param([Parameter(Mandatory)][int] $ExpectedPid, [Parameter(Mandatory)] $Baseline)
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(30)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $snapshot = Read-MishProviderSnapshot -Method $script:ProductMethod
        if ([int]$snapshot.pid -eq $ExpectedPid -and [bool]$snapshot.consistent) {
            $last = Get-MishProcessMetrics -Android $snapshot
            if (
                [int64]$last.proxy_active_sessions -eq 0 -and
                ($null -eq $last.mesh_active_sessions -or [int64]$last.mesh_active_sessions -eq 0) -and
                [int64]$last.rotation_active_tasks -eq 0 -and
                [int64]$last.runtime_active_tasks -le [int64]$Baseline.runtime_active_tasks -and
                [int]$last.threads -le [int]$Baseline.threads -and
                [int]$last.fd_count -le [int]$Baseline.fd_count
            ) { return $last }
        }
        Start-Sleep -Milliseconds 750
    }
    Stop-MishU8F 'PRODUCT_RESOURCE_NOT_QUIESCENT' 'Threads/FD/Tokio tasks/session owners did not return to baseline.'
}

function Wait-MishFreshReadyProcess {
    param([Parameter(Mandatory)][int] $OldPid)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($RecoveryTimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $pidText = Invoke-MishAdbText -Operation 'recovery_pid' -Arguments @('shell', 'pidof', $PackageName)
            if ($pidText -match '^\d+$' -and [int]$pidText -ne $OldPid) {
                $product = Read-MishProviderSnapshot -Method $script:ProductMethod
                $control = Read-MishProviderSnapshot -Method $script:ControlMethod
                if (
                    [int]$product.pid -eq [int]$pidText -and
                    [bool]$product.consistent -and
                    [bool]$product.runtime.running -and
                    [string]$product.readiness.state -ceq 'READY' -and
                    [bool]$product.root.policy_authorized -and
                    [string]$product.proxy.state -ceq 'RUNNING' -and
                    [bool]$product.mesh.admitted -and
                    [bool]$product.mesh.ingress_running -and
                    [string]$control.control.state -ceq 'READY' -and
                    [int64]$control.control.application_heartbeat_count -eq 0
                ) {
                    $watch.Stop()
                    return [ordered]@{ pid = [int]$pidText; elapsed_ms = [int64]$watch.ElapsedMilliseconds; product = $product; control = $control }
                }
            }
        } catch {}
        Start-Sleep -Seconds 1
    }
    Stop-MishU8F 'PRODUCT_PROCESS_DEATH_RECOVERY_TIMEOUT' 'Fresh READY process did not return automatically.'
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) { Stop-MishU8F 'LAB_ADB_MISSING' 'Canonical ADB is unavailable.' }
if ($SampleIntervalSeconds -ge $SoakSeconds) { Stop-MishU8F 'LAB_INVALID_SOAK_CONFIGURATION' 'Sample interval must be smaller than soak duration.' }

$acceptance = 'FAIL'
$classification = 'U8_DURABILITY_SOAK_INCOMPLETE'
$detail = $null
$samples = [Collections.Generic.List[object]]::new()
$baselineControl = $null
$baselineMetrics = $null
$postCleanup = $null
$recovery = $null
$postRecovery = $null
$projectedMonthlyPayload = $null
$reconnectDelta = $null
$credentialVersion = $null
$lease = $null

try {
    $baselinePath = Join-Path $env:TEMP 'mish-u8f-baseline-v2.json'
    $baselineDiagnostic = Invoke-MishCanonicalDiagnostic -Path $baselinePath
    $android = $baselineDiagnostic.android
    [int]$baselinePid = [int]$android.pid
    $credentialVersion = [int64]$android.credential.version
    $baselineControl = Read-MishProviderSnapshot -Method $script:ControlMethod
    Assert-MishControlReady -Snapshot $baselineControl -ExpectedPid $baselinePid
    $baselineMetrics = Get-MishProcessMetrics -Android $android

    Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
    $tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
    $script:CredentialStorePath = Join-Path $tempRoot ('mish-u8f-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $script:CredentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $script:CredentialStorePath

    $meshAddress = Get-MishMeshAddress
    $script:LiveTunnel = Open-MishLongLivedTunnel -ProxyHost $meshAddress -Lease $lease
    Invoke-MishTunnelPulse -Tunnel $script:LiveTunnel

    [int64]$startPayload = [int64]$baselineControl.control.payload_tx_bytes + [int64]$baselineControl.control.payload_rx_bytes
    [int64]$startReconnects = [int64]$baselineControl.control.reconnect_count
    [int64]$previousReconnects = $startReconnects
    [int64]$previousSessionAge = [int64]$baselineControl.control.session_age_ms
    $watch = [Diagnostics.Stopwatch]::StartNew()

    while ($watch.Elapsed.TotalSeconds -lt $SoakSeconds) {
        Start-Sleep -Seconds $SampleIntervalSeconds
        $product = Read-MishProviderSnapshot -Method $script:ProductMethod
        if (
            [int]$product.pid -ne $baselinePid -or
            -not [bool]$product.consistent -or
            -not [bool]$product.runtime.running -or
            [string]$product.readiness.state -cne 'READY'
        ) { Stop-MishU8F 'PRODUCT_SOAK_READINESS_LOST' 'PRODUCT left READY during bounded soak.' }

        $control = Read-MishProviderSnapshot -Method $script:ControlMethod
        Assert-MishControlReady -Snapshot $control -ExpectedPid $baselinePid
        $metrics = Get-MishProcessMetrics -Android $product

        if ([int64]$metrics.proxy_active_sessions -lt 1 -or $null -eq $metrics.mesh_active_sessions -or [int64]$metrics.mesh_active_sessions -lt 1) {
            Stop-MishU8F 'PRODUCT_LONG_LIVED_SESSION_LOST' 'Long-lived Mesh proxy session disappeared.'
        }

        [int64]$reconnects = [int64]$control.control.reconnect_count
        [int64]$sessionAge = [int64]$control.control.session_age_ms
        if ($reconnects -eq $previousReconnects -and $sessionAge -lt $previousSessionAge) {
            Stop-MishU8F 'CONTROL_SESSION_AGE_REGRESSED' 'Control session age regressed without a reconnect.'
        }
        if (($reconnects - $startReconnects) -gt 2) {
            Stop-MishU8F 'CONTROL_RECONNECT_STORM' 'More than two reconnects occurred during the bounded soak.'
        }

        Invoke-MishTunnelPulse -Tunnel $script:LiveTunnel
        [void]$samples.Add([ordered]@{
            elapsed_ms = [int64]$watch.ElapsedMilliseconds
            control = [ordered]@{
                reconnect_attempts = [int]$control.control.reconnect_attempts
                reconnect_count = $reconnects
                session_age_ms = $sessionAge
                application_heartbeat_count = [int64]$control.control.application_heartbeat_count
                payload_tx_bytes = [int64]$control.control.payload_tx_bytes
                payload_rx_bytes = [int64]$control.control.payload_rx_bytes
            }
            resources = $metrics
            long_lived_proxy_pulses = [int]$script:LiveTunnel.Pulses
        })
        $previousReconnects = $reconnects
        $previousSessionAge = $sessionAge
    }
    $watch.Stop()

    $finalControl = Read-MishProviderSnapshot -Method $script:ControlMethod
    Assert-MishControlReady -Snapshot $finalControl -ExpectedPid $baselinePid
    $reconnectDelta = [int64]$finalControl.control.reconnect_count - $startReconnects
    [int64]$endPayload = [int64]$finalControl.control.payload_tx_bytes + [int64]$finalControl.control.payload_rx_bytes
    [int64]$payloadDelta = [Math]::Max(0, $endPayload - $startPayload)
    [double]$monthMs = [TimeSpan]::FromDays(30).TotalMilliseconds
    $projectedMonthlyPayload = [int64][Math]::Ceiling(([double]$payloadDelta * $monthMs) / [Math]::Max(1.0, [double]$watch.ElapsedMilliseconds))
    if ($projectedMonthlyPayload -gt $script:ControlPayloadMonthlyBudgetBytes) {
        Stop-MishU8F 'CONTROL_PAYLOAD_BUDGET_EXCEEDED' 'Observed control TEXT payload extrapolates above 10 MiB/month.'
    }

    Close-MishTunnel -Tunnel $script:LiveTunnel
    $script:LiveTunnel = $null
    $postCleanup = Wait-MishQuiescence -ExpectedPid $baselinePid -Baseline $baselineMetrics

    @(& $AdbPath shell am crash $PackageName 2>&1 | ForEach-Object { [string]$_ }) | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-MishU8F 'LAB_PROCESS_DEATH_INJECTION_FAILED' 'Android am crash failed.' }

    $recovery = Wait-MishFreshReadyProcess -OldPid $baselinePid
    if ([int64]$recovery.product.credential.version -ne $credentialVersion) {
        Stop-MishU8F 'PRODUCT_CREDENTIAL_CHANGED' 'Credential version changed across process death.'
    }

    $postPath = Join-Path $env:TEMP 'mish-u8f-post-recovery-v2.json'
    $postRecovery = Invoke-MishCanonicalDiagnostic -Path $postPath
    if (
        [int]$postRecovery.android.pid -ne [int]$recovery.pid -or
        [string]$postRecovery.external.adb_loopback_proxy_e2e.result -cne 'PASS' -or
        [string]$postRecovery.external.mesh_proxy_e2e.result -cne 'PASS'
    ) {
        Stop-MishU8F 'PRODUCT_POST_RECOVERY_E2E_FAILED' 'Fresh process did not restore canonical proxy E2E.'
    }

    $acceptance = 'PASS'
    $classification = 'U8_DURABILITY_SOAK_PASS'
}
catch {
    $message = $_.Exception.Message
    if ($message -match '^MISH_U8F_FAILURE\|(?<classification>[A-Z0-9_]+)\|(?<detail>.*)$') {
        $classification = $Matches['classification']
        $detail = $Matches['detail']
    } else {
        $classification = 'LAB_U8_DURABILITY_UNEXPECTED_FAILURE'
        $detail = $message
    }
}
finally {
    Close-MishTunnel -Tunnel $script:LiveTunnel
    $script:LiveTunnel = $null
    $lease = $null
    if ($script:CredentialStorePath -and (Test-Path -LiteralPath $script:CredentialStorePath -PathType Leaf)) {
        Remove-Item -LiteralPath $script:CredentialStorePath -Force -ErrorAction SilentlyContinue
    }
}

$heartbeatObserved = if ($null -eq $baselineControl) {
    $null
} else {
    [int64]$baselineControl.control.application_heartbeat_count -ne 0 -or
    @($samples | Where-Object { [int64]$_.control.application_heartbeat_count -ne 0 }).Count -gt 0
}

$evidence = [ordered]@{
    schema = 'mish.lab.u8-durability-soak/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = $acceptance
    classification = $classification
    detail = $detail
    soak_seconds = $SoakSeconds
    sample_interval_seconds = $SampleIntervalSeconds
    samples = @($samples)
    control = [ordered]@{
        payload_scope = 'WEBSOCKET_TEXT_APPLICATION_PAYLOAD_ONLY'
        wire_bytes_claimed = $false
        application_heartbeat_observed = $heartbeatObserved
        reconnect_delta = $reconnectDelta
        reconnect_storm_limit = 2
        projected_monthly_payload_bytes = $projectedMonthlyPayload
        monthly_payload_budget_bytes = [int64]$script:ControlPayloadMonthlyBudgetBytes
    }
    long_lived_proxy = [ordered]@{
        protocol = 'HTTP_CONNECT_TLS'
        target_hostname = $script:TargetHost
        pulses_completed = @($samples).Count + 1
        raw_mesh_ip_persisted = $false
        raw_target_ip_persisted = $false
    }
    resources = [ordered]@{
        baseline = $baselineMetrics
        post_cleanup = $postCleanup
        rss_pss_are_observational = $true
        threads_fd_tokio_tasks_must_return_to_baseline = $true
    }
    process_death = [ordered]@{
        fault = 'ANDROID_AM_CRASH'
        explicit_activity_launch_used = $false
        user_action_used = $false
        old_pid = if ($null -eq $baselineMetrics) { $null } else { [int]$baselineMetrics.pid }
        fresh_pid = if ($null -eq $recovery) { $null } else { [int]$recovery.pid }
        recovery_elapsed_ms = if ($null -eq $recovery) { $null } else { [int64]$recovery.elapsed_ms }
        credential_version_stable = if ($null -eq $recovery -or $null -eq $credentialVersion) { $null } else { [int64]$recovery.product.credential.version -eq $credentialVersion }
        control_ready = if ($null -eq $recovery) { $false } else { [string]$recovery.control.control.state -ceq 'READY' }
        post_recovery_loopback_e2e = if ($null -eq $postRecovery) { 'NOT_RUN' } else { [string]$postRecovery.external.adb_loopback_proxy_e2e.result }
        post_recovery_mesh_e2e = if ($null -eq $postRecovery) { 'NOT_RUN' } else { [string]$postRecovery.external.mesh_proxy_e2e.result }
    }
    acceptance_policy = [ordered]@{
        no_512_stress = $true
        no_application_heartbeat = $true
        bounded_reconnects = $true
        control_application_payload_below_10_mib_month = $true
        long_lived_proxy_application_liveness = $true
        threads_fd_tokio_tasks_return_to_baseline = $true
        fresh_pid_after_process_death = $true
        automatic_service_recovery_without_activity_launch = $true
        post_recovery_proxy_e2e = $true
    }
    secrets_persisted_in_evidence = $false
    raw_public_ip_persisted = $false
}

$fullPath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($fullPath, (($evidence | ConvertTo-Json -Depth 24) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

Write-Host "MISH_U8_DURABILITY_SOAK=$acceptance"
Write-Host "MISH_U8_DURABILITY_SOAK_CLASSIFICATION=$classification"
Write-Host "MISH_U8_DURABILITY_SOAK_SAMPLES=$($samples.Count)"
Write-Host "MISH_U8_DURABILITY_SOAK_RECONNECT_DELTA=$reconnectDelta"
Write-Host "MISH_U8_DURABILITY_SOAK_PROJECTED_MONTHLY_PAYLOAD_BYTES=$projectedMonthlyPayload"
Write-Host "MISH_U8_DURABILITY_SOAK_EVIDENCE=$fullPath"

if ($acceptance -cne 'PASS') {
    throw "MISH_U8_DURABILITY_RESULT|$acceptance|$classification"
}
