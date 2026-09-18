[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-dns-lifetime-live-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.dns-lifetime-live/v1'
$script:SnapshotMethod = 'snapshot_v2'
$script:PollMilliseconds = 100
$script:RequestTimeoutSeconds = 3
$script:MaxRequests = 96
$script:MaxConcurrency = 8
$script:PreLossMinimumDnsStarts = 4
$script:PreLossTimeoutSeconds = 10
$script:LossTimeoutSeconds = 30
$script:RecoveryTimeoutSeconds = 45
$script:QuiescenceTimeoutSeconds = 15

function Stop-MishDnsLifetime {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_DNS_LIFETIME_FAILURE|$Classification|$Message"
}

function Invoke-MishProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 120)][int] $TimeoutSeconds = 30
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_PROCESS_START_FAILED' 'Required subprocess could not be started.'
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_PROCESS_TIMEOUT' 'Required subprocess exceeded its bounded timeout.'
        }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-MishAdb {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 120)][int] $TimeoutSeconds = 30
    )
    Invoke-MishProcess -FilePath $AdbPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function Read-MishSnapshot {
    $result = Invoke-MishAdb -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    ) -TimeoutSeconds 15
    if ($result.ExitCode -ne 0) { return $null }

    $match = [regex]::Match($result.StdOut, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { return $null }

    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Get-MishDnsObservation {
    param([AllowNull()][Parameter(Mandatory)] $Snapshot)

    if (
        $null -eq $Snapshot -or
        -not [bool]$Snapshot.consistent -or
        $null -eq $Snapshot.cellular -or
        $null -eq $Snapshot.cellular.dns -or
        -not [bool]$Snapshot.cellular.dns.available
    ) {
        return $null
    }

    $dns = $Snapshot.cellular.dns
    return [ordered]@{
        pid = [int]$Snapshot.pid
        captured_elapsed_ms = [int64]$Snapshot.captured_elapsed_ms
        cellular_state = [string]$Snapshot.cellular.state
        cellular_admitted = [bool]$Snapshot.cellular.admitted
        root_policy_authorized = [bool]$Snapshot.root.policy_authorized
        proxy_state = [string]$Snapshot.proxy.state
        proxy_healthy = [bool]$Snapshot.proxy.healthy
        credential_active = [bool]$Snapshot.credential.active
        readiness_state = [string]$Snapshot.readiness.state
        slow_threshold_ms = [int64]$dns.slow_threshold_ms
        started = [int64]$dns.started
        completed = [int64]$dns.completed
        active = [int64]$dns.active
        peak_active = [int64]$dns.peak_active
        slow_completions = [int64]$dns.slow_completions
        resolver_failed = [int64]$dns.resolver_failed
        discarded_after_deadline = [int64]$dns.discarded_after_deadline
        completed_after_owner_change = [int64]$dns.completed_after_owner_change
        discarded_stale = [int64]$dns.discarded_stale
        authority_validation_failed = [int64]$dns.authority_validation_failed
        unusable_result = [int64]$dns.unusable_result
        accepted_current = [int64]$dns.accepted_current
        max_native_elapsed_ms = [int64]$dns.max_native_elapsed_ms
        last_started_owner_sequence = $dns.last_started_owner_sequence
        last_completed_start_owner_sequence = $dns.last_completed_start_owner_sequence
        last_completed_current_owner_sequence = $dns.last_completed_current_owner_sequence
    }
}

function Read-MishPinnedObservation {
    param([Parameter(Mandatory)][int] $ExpectedPid)

    $snapshot = Read-MishSnapshot
    $observation = Get-MishDnsObservation -Snapshot $snapshot
    if ($null -eq $observation) { return $null }
    if ([int]$observation.pid -ne $ExpectedPid) {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_PROCESS_CHANGED' 'PRODUCT PID changed during the same-process DNS lifetime observation.'
    }
    return $observation
}

function Invoke-MishMobileDataTransition {
    param([Parameter(Mandatory)][ValidateSet('enable','disable')][string] $State)

    $result = Invoke-MishAdb -Arguments @('shell', 'cmd', 'phone', 'data', $State) -TimeoutSeconds 20
    if ($result.ExitCode -ne 0 -or -not [string]::IsNullOrWhiteSpace($result.StdOut)) {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_DEVICE_CONTROL_FAILED' "Bounded mobile-data $State control request failed."
    }
}

function New-MishAdbForward {
    $result = Invoke-MishAdb -Arguments @('forward', 'tcp:0', 'tcp:3128') -TimeoutSeconds 15
    $value = $result.StdOut.Trim()
    if ($result.ExitCode -ne 0 -or $value -notmatch '^\d+$') {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_FORWARD_FAILED' 'Bounded ADB forward to the accepted HTTP CONNECT listener could not be created.'
    }
    return [int]$value
}

function Start-MishDnsRequest {
    param(
        [Parameter(Mandatory)][int] $Ordinal,
        [Parameter(Mandatory)][int] $ProxyPort,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][string] $RunTag
    )

    $proxy = [Net.WebProxy]::new("http://127.0.0.1:$ProxyPort")
    $proxy.Credentials = [Net.NetworkCredential]::new(
        [string]$Lease.ProxyUserName,
        [Security.SecureString]$Lease.ProxyPassword
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.UseProxy = $true
    $handler.Proxy = $proxy
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($script:RequestTimeoutSeconds)

    # Unique names force the accepted proxy-domain resolver seam instead of reusing a target result.
    # The target hostname is deliberately not persisted in durable evidence.
    $url = "http://mish-dns-$RunTag-$Ordinal.example.com/"
    return [pscustomobject]@{
        Ordinal = $Ordinal
        Client = $client
        Handler = $handler
        Task = $client.GetAsync($url, [Net.Http.HttpCompletionOption]::ResponseHeadersRead)
    }
}

function Complete-MishDnsRequests {
    param(
        [Parameter(Mandatory)] $ActiveRequests,
        [Parameter(Mandatory)] $RequestResults
    )

    for ($index = $ActiveRequests.Count - 1; $index -ge 0; $index--) {
        $entry = $ActiveRequests[$index]
        if (-not [bool]$entry.Task.IsCompleted) { continue }

        $reason = 'TRANSPORT_FAILED'
        $response = $null
        try {
            $response = $entry.Task.GetAwaiter().GetResult()
            $reason = "HTTP_$([int]$response.StatusCode)"
        }
        catch [System.Threading.Tasks.TaskCanceledException] {
            $reason = 'TIMEOUT'
        }
        catch {
            $reason = 'TRANSPORT_FAILED'
        }
        finally {
            if ($null -ne $response) { $response.Dispose() }
            $entry.Client.Dispose()
            $entry.Handler.Dispose()
        }

        [void]$RequestResults.Add([ordered]@{
            ordinal = [int]$entry.Ordinal
            reason = $reason
        })
        $ActiveRequests.RemoveAt($index)
    }
}

function Start-OneMishDnsRequestIfPossible {
    param(
        [Parameter(Mandatory)] $Observation,
        [Parameter(Mandatory)] $ActiveRequests,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][int] $ProxyPort,
        [Parameter(Mandatory)][string] $RunTag,
        [Parameter(Mandatory)][ref] $StartedCount
    )

    if (
        $StartedCount.Value -ge $script:MaxRequests -or
        $ActiveRequests.Count -ge $script:MaxConcurrency -or
        [string]$Observation.proxy_state -cne 'RUNNING' -or
        -not [bool]$Observation.credential_active
    ) {
        return
    }

    $StartedCount.Value++
    $entry = Start-MishDnsRequest -Ordinal $StartedCount.Value -ProxyPort $ProxyPort -Lease $Lease -RunTag $RunTag
    [void]$ActiveRequests.Add($entry)
}

function Update-MishSampleSummary {
    param(
        [Parameter(Mandatory)] $Observation,
        [Parameter(Mandatory)][ref] $SampleCount,
        [Parameter(Mandatory)][ref] $MaxObservedActive,
        [Parameter(Mandatory)] $OwnerSequences
    )

    $SampleCount.Value++
    if ([int64]$Observation.active -gt $MaxObservedActive.Value) {
        $MaxObservedActive.Value = [int64]$Observation.active
    }
    if ($null -ne $Observation.last_started_owner_sequence) {
        $sequence = [int64]$Observation.last_started_owner_sequence
        if (-not $OwnerSequences.Contains($sequence)) {
            [void]$OwnerSequences.Add($sequence)
        }
    }
}

function New-MishDnsDelta {
    param(
        [Parameter(Mandatory)] $From,
        [Parameter(Mandatory)] $To
    )

    return [ordered]@{
        started = [int64]$To.started - [int64]$From.started
        completed = [int64]$To.completed - [int64]$From.completed
        slow_completions = [int64]$To.slow_completions - [int64]$From.slow_completions
        resolver_failed = [int64]$To.resolver_failed - [int64]$From.resolver_failed
        discarded_after_deadline = [int64]$To.discarded_after_deadline - [int64]$From.discarded_after_deadline
        completed_after_owner_change = [int64]$To.completed_after_owner_change - [int64]$From.completed_after_owner_change
        discarded_stale = [int64]$To.discarded_stale - [int64]$From.discarded_stale
        authority_validation_failed = [int64]$To.authority_validation_failed - [int64]$From.authority_validation_failed
        unusable_result = [int64]$To.unusable_result - [int64]$From.unusable_result
        accepted_current = [int64]$To.accepted_current - [int64]$From.accepted_current
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force

$baselineSnapshot = Read-MishSnapshot
$baseline = Get-MishDnsObservation -Snapshot $baselineSnapshot
if (
    $null -eq $baseline -or
    -not [bool]$baseline.cellular_admitted -or
    -not [bool]$baseline.root_policy_authorized -or
    [string]$baseline.proxy_state -cne 'RUNNING' -or
    -not [bool]$baseline.proxy_healthy -or
    -not [bool]$baseline.credential_active -or
    [string]$baseline.readiness_state -cne 'READY'
) {
    Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_BASELINE_INVALID' 'Canonical baseline is not ready for the live same-process DNS observation.'
}

$productPid = [int]$baseline.pid
$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_TEMP_UNAVAILABLE' 'A temporary directory is unavailable.'
}
$credentialStorePath = Join-Path ([IO.Path]::GetFullPath($tempRoot)) ('mish-dns-lifetime-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
$runTag = [Guid]::NewGuid().ToString('N').Substring(0, 12)

$lease = $null
$forwardPort = $null
$mobileDataMayBeDisabled = $false
$activeRequests = [Collections.Generic.List[object]]::new()
$requestResults = [Collections.Generic.List[object]]::new()
$ownerSequences = [Collections.Generic.List[long]]::new()
$requestStarted = 0
$sampleCount = 0
$maxObservedActive = [int64]$baseline.active
$beforeLoss = $null
$loss = $null
$recovery = $null
$finalObservation = $null
$quiescent = $false
$quiescenceElapsedMs = [int64]0
$classification = 'LAB_DNS_LIFETIME_NOT_COMPLETED'

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_CREDENTIAL_UNAVAILABLE' 'Bounded external proxy credential lease is unavailable.'
    }
    $forwardPort = New-MishAdbForward

    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Complete-MishDnsRequests -ActiveRequests $activeRequests -RequestResults $requestResults
        $observation = Read-MishPinnedObservation -ExpectedPid $productPid
        if ($null -ne $observation) {
            Update-MishSampleSummary -Observation $observation -SampleCount ([ref]$sampleCount) -MaxObservedActive ([ref]$maxObservedActive) -OwnerSequences $ownerSequences
            Start-OneMishDnsRequestIfPossible -Observation $observation -ActiveRequests $activeRequests -Lease $lease -ProxyPort $forwardPort -RunTag $runTag -StartedCount ([ref]$requestStarted)

            if (
                [int64]$observation.started -ge ([int64]$baseline.started + $script:PreLossMinimumDnsStarts) -and
                $null -ne $observation.last_started_owner_sequence
            ) {
                $beforeLoss = $observation
                break
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge $script:PreLossTimeoutSeconds) { break }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    } while ($true)
    $watch.Stop()

    if ($null -eq $beforeLoss) {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_TARGET_NOT_EXERCISED' 'Authenticated proxy-domain stimulus did not increment native DNS starts before cellular loss.'
    }
    $beforeOwnerSequence = [int64]$beforeLoss.last_started_owner_sequence

    $mobileDataMayBeDisabled = $true
    Invoke-MishMobileDataTransition -State 'disable'

    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Complete-MishDnsRequests -ActiveRequests $activeRequests -RequestResults $requestResults
        $observation = Read-MishPinnedObservation -ExpectedPid $productPid
        if ($null -ne $observation) {
            Update-MishSampleSummary -Observation $observation -SampleCount ([ref]$sampleCount) -MaxObservedActive ([ref]$maxObservedActive) -OwnerSequences $ownerSequences
            Start-OneMishDnsRequestIfPossible -Observation $observation -ActiveRequests $activeRequests -Lease $lease -ProxyPort $forwardPort -RunTag $runTag -StartedCount ([ref]$requestStarted)
            if (-not [bool]$observation.cellular_admitted) {
                $loss = $observation
                break
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge $script:LossTimeoutSeconds) { break }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    } while ($true)
    $watch.Stop()

    if ($null -eq $loss) {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_LOSS_NOT_OBSERVED' 'Canonical owner facts did not observe cellular loss within the bounded window.'
    }

    Invoke-MishMobileDataTransition -State 'enable'
    $mobileDataMayBeDisabled = $false

    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Complete-MishDnsRequests -ActiveRequests $activeRequests -RequestResults $requestResults
        $observation = Read-MishPinnedObservation -ExpectedPid $productPid
        if ($null -ne $observation) {
            Update-MishSampleSummary -Observation $observation -SampleCount ([ref]$sampleCount) -MaxObservedActive ([ref]$maxObservedActive) -OwnerSequences $ownerSequences
            Start-OneMishDnsRequestIfPossible -Observation $observation -ActiveRequests $activeRequests -Lease $lease -ProxyPort $forwardPort -RunTag $runTag -StartedCount ([ref]$requestStarted)

            if (
                [bool]$observation.cellular_admitted -and
                [bool]$observation.root_policy_authorized -and
                [string]$observation.proxy_state -ceq 'RUNNING' -and
                [bool]$observation.proxy_healthy -and
                $null -ne $observation.last_started_owner_sequence -and
                [int64]$observation.last_started_owner_sequence -gt $beforeOwnerSequence -and
                [int64]$observation.started -gt [int64]$beforeLoss.started
            ) {
                $recovery = $observation
                break
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge $script:RecoveryTimeoutSeconds) { break }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    } while ($true)
    $watch.Stop()

    if ($null -eq $recovery) {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_RECOVERY_SEQUENCE_UNOBSERVED' 'Recovered PRODUCT did not expose a fresh DNS owner sequence in the same PID within the bounded window.'
    }

    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        Complete-MishDnsRequests -ActiveRequests $activeRequests -RequestResults $requestResults
        $observation = Read-MishPinnedObservation -ExpectedPid $productPid
        if ($null -ne $observation) {
            $finalObservation = $observation
            Update-MishSampleSummary -Observation $observation -SampleCount ([ref]$sampleCount) -MaxObservedActive ([ref]$maxObservedActive) -OwnerSequences $ownerSequences
            if (
                [int64]$observation.active -eq 0 -and
                [int64]$observation.completed -eq [int64]$observation.started
            ) {
                $quiescent = $true
                break
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge $script:QuiescenceTimeoutSeconds) { break }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    } while ($true)
    $quiescenceElapsedMs = [int64]$watch.ElapsedMilliseconds
    $watch.Stop()

    if ($null -eq $finalObservation) {
        Stop-MishDnsLifetime 'LAB_DNS_LIFETIME_FINAL_OBSERVATION_UNAVAILABLE' 'No coherent same-PID DNS observation was available after recovery.'
    }

    $classification = 'U3_DNS_LIFETIME_LIVE_OBSERVATION_COMPLETE'
    $evidence = [ordered]@{
        schema = $script:Schema
        collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        collection_result = 'PASS'
        acceptance_result = 'PASS'
        observation_only = $true
        classification = $classification
        application_id = $PackageName
        same_process = $true
        product_pid = $productPid
        sample_count = $sampleCount
        control_effect = [ordered]@{
            mobile_data_disable_requested = $true
            loss_observed = $true
            mobile_data_enable_requested = $true
            recovery_observed = $true
        }
        stimulus = [ordered]@{
            requested_max = $script:MaxRequests
            max_concurrency = $script:MaxConcurrency
            started = $requestStarted
            completed = $requestResults.Count
            timed_out = @($requestResults | Where-Object { [string]$_.reason -ceq 'TIMEOUT' }).Count
        }
        dns = [ordered]@{
            baseline = $baseline
            before_loss = $beforeLoss
            loss = $loss
            recovery = $recovery
            final = $finalObservation
            total_delta = New-MishDnsDelta -From $baseline -To $finalObservation
            max_observed_active = $maxObservedActive
            distinct_started_owner_sequences = @($ownerSequences)
            owner_sequence_advanced = [int64]$recovery.last_started_owner_sequence -gt $beforeOwnerSequence
            quiescent_after_recovery = $quiescent
            quiescence_wait_elapsed_ms = $quiescenceElapsedMs
            final_completion_gap = [int64]$finalObservation.started - [int64]$finalObservation.completed
        }
        lab_effects = [ordered]@{
            cellular_loss = 'adb shell cmd phone data disable/enable'
            adb_forward_created = $true
            cloudflare_app_mutated = $false
            product_routes_or_iptables_mutated_by_lab = $false
        }
    }

    $fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $fullEvidencePath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullEvidencePath,
        (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host "MISH_DNS_LIFETIME_LIVE_RESULT=PASS"
    Write-Host "MISH_DNS_LIFETIME_LIVE_CLASSIFICATION=$classification"
    Write-Host "MISH_DNS_LIFETIME_LIVE_EVIDENCE=$fullEvidencePath"
    $evidence | ConvertTo-Json -Depth 16 -Compress
}
finally {
    foreach ($entry in @($activeRequests)) {
        try { $entry.Client.Dispose() } catch { }
        try { $entry.Handler.Dispose() } catch { }
    }
    if ($mobileDataMayBeDisabled) {
        try { [void](Invoke-MishAdb -Arguments @('shell', 'cmd', 'phone', 'data', 'enable') -TimeoutSeconds 20) } catch { }
    }
    if ($null -ne $forwardPort) {
        try { [void](Invoke-MishAdb -Arguments @('forward', '--remove', "tcp:$forwardPort") -TimeoutSeconds 15) } catch { }
    }
    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
}
