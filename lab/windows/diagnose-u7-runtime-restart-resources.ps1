[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [ValidateRange(2, 5)][int] $Cycles = 3,
    [ValidateRange(15, 60)][int] $TransitionDeadlineSeconds = 45,
    [ValidateRange(2, 30)][int] $AdbTransportTimeoutSeconds = 10,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u7-runtime-restart-resources-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.u7-runtime-restart-resources/v1'
$script:SnapshotMethod = 'snapshot_v2'
$script:PollMilliseconds = 150
$script:AdbTransportTimeoutMilliseconds = $AdbTransportTimeoutSeconds * 1000
$script:StopComponent = "$PackageName/com.mobileproxymish.app.DebugRuntimeStopActivity"
$script:StartComponent = "$PackageName/com.mobileproxymish.app.DebugRuntimeStartActivity"

function Stop-MishRestartProbe {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_U7_RESTART_FAILURE|$Classification|$Message"
}

function Invoke-MishAdbText {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Operation
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $AdbPath
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            Stop-MishRestartProbe 'LAB_ADB_FAILED' "ADB operation '$Operation' did not start."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($script:AdbTransportTimeoutMilliseconds)) {
            try { $process.Kill($true) } catch {}
            try { [void]$process.WaitForExit(2000) } catch {}
            Stop-MishRestartProbe 'LAB_ADB_TIMEOUT' "ADB operation '$Operation' exceeded the bounded transport deadline."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            Stop-MishRestartProbe 'LAB_ADB_FAILED' "ADB operation '$Operation' failed with exit code $($process.ExitCode)."
        }
        return $stdout.Trim()
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-MishActivityTrigger {
    param(
        [Parameter(Mandatory)][string] $Component,
        [Parameter(Mandatory)][string] $Operation
    )
    $output = Invoke-MishAdbText -Operation $Operation -Arguments @('shell', 'am', 'start', '-n', $Component)
    if ($output -match '(?im)^\s*(Error|Exception):' -or $output -notmatch '(?im)^\s*Starting: Intent') {
        Stop-MishRestartProbe 'LAB_ACTIVITY_TRIGGER_FAILED' "Android Activity trigger '$Operation' was not accepted."
    }
}

function Get-MishOptionalInt64 {
    param($Value)
    if ($null -eq $Value) { return $null }
    return [int64]$Value
}

function Get-MishAndroidSnapshot {
    $contentOutput = Invoke-MishAdbText -Operation 'snapshot_v2' -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    )
    $payloadMatch = [regex]::Match($contentOutput, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $payloadMatch.Success) {
        Stop-MishRestartProbe 'LAB_SNAPSHOT_INVALID' 'Android diagnostics returned no V2 payload.'
    }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
        $snapshot = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch {
        Stop-MishRestartProbe 'LAB_SNAPSHOT_INVALID' 'Android diagnostics payload is malformed.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if (
        [string]$snapshot.schema -cne 'mish.diagnostics/v2' -or
        [string]$snapshot.application_id -cne $PackageName -or
        -not [bool]$snapshot.consistent
    ) {
        Stop-MishRestartProbe 'PRODUCT_ATOMIC_SNAPSHOT_INVALID' 'Atomic PRODUCT snapshot identity/consistency failed.'
    }
    return $snapshot
}

function Assert-MishReady {
    param(
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)][int64] $ExpectedCredentialVersion
    )
    if (
        -not [bool]$Snapshot.runtime.running -or
        -not [bool]$Snapshot.cellular.admitted -or
        -not [bool]$Snapshot.root.policy_authorized -or
        -not [bool]$Snapshot.proxy.healthy -or
        -not [bool]$Snapshot.credential.active -or
        (Get-MishOptionalInt64 $Snapshot.credential.version) -ne $ExpectedCredentialVersion -or
        [string]$Snapshot.readiness.state -cne 'READY' -or
        -not [bool]$Snapshot.mesh.admitted -or
        -not [bool]$Snapshot.mesh.ingress_running -or
        [int64]$Snapshot.proxy.active_sessions -ne 0 -or
        ($null -ne $Snapshot.mesh.active_sessions -and [int64]$Snapshot.mesh.active_sessions -ne 0) -or
        [int64]$Snapshot.rotation.active_tasks -ne 0
    ) {
        Stop-MishRestartProbe 'PRODUCT_RESTART_NOT_READY' 'Runtime restart did not return to exact READY/quiescent owner state.'
    }
}

function Get-MishProcessMetrics {
    param([Parameter(Mandatory)] $Snapshot)

    [int]$processId = [int]$Snapshot.pid
    if ($processId -le 0) {
        Stop-MishRestartProbe 'PRODUCT_PROCESS_IDENTITY_INVALID' 'Diagnostics returned no PRODUCT PID.'
    }

    $pidText = Invoke-MishAdbText -Operation 'observe_pid' -Arguments @('shell', 'pidof', $PackageName)
    if ([string]::IsNullOrWhiteSpace($pidText) -or $pidText -match '\s' -or [int]$pidText -ne $processId) {
        Stop-MishRestartProbe 'PRODUCT_PROCESS_IDENTITY_INVALID' 'Exactly one stable PRODUCT process is required.'
    }

    $status = Invoke-MishAdbText -Operation 'observe_process_status' -Arguments @(
        'shell', 'run-as', $PackageName, 'cat', "/proc/$processId/status"
    )
    $threadsMatch = [regex]::Match($status, '(?m)^Threads:\s+(?<value>\d+)\s*$')
    $rssMatch = [regex]::Match($status, '(?m)^VmRSS:\s+(?<value>\d+)\s+kB\s*$')
    if (-not $threadsMatch.Success -or -not $rssMatch.Success) {
        Stop-MishRestartProbe 'LAB_PROCESS_METRICS_UNAVAILABLE' 'PRODUCT threads/VmRSS are unavailable.'
    }

    $fdListing = Invoke-MishAdbText -Operation 'observe_fd_count' -Arguments @(
        'shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$processId/fd"
    )
    $fdCount = @($fdListing -split '[\r\n]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
    if ($fdCount -le 0) {
        Stop-MishRestartProbe 'LAB_PROCESS_METRICS_UNAVAILABLE' 'PRODUCT FD count is unavailable.'
    }

    $meminfo = Invoke-MishAdbText -Operation 'observe_process_pss' -Arguments @(
        'shell', 'dumpsys', 'meminfo', '-s', [string]$processId
    )
    $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL PSS:\s*(?<value>\d+)\b')
    if (-not $pssMatch.Success) {
        $pssMatch = [regex]::Match($meminfo, '(?m)^\s*TOTAL\s+(?<value>\d+)\s+')
    }
    if (-not $pssMatch.Success) {
        Stop-MishRestartProbe 'LAB_PROCESS_METRICS_UNAVAILABLE' 'PRODUCT PSS is unavailable.'
    }

    return [ordered]@{
        pid = $processId
        threads = [int]$threadsMatch.Groups['value'].Value
        fd_count = [int]$fdCount
        rss_kb = [int64]$rssMatch.Groups['value'].Value
        pss_kb = [int64]$pssMatch.Groups['value'].Value
        runtime_generation = [int64]$Snapshot.runtime.generation
        root_session_generation = Get-MishOptionalInt64 $Snapshot.root.session_generation
        credential_version = Get-MishOptionalInt64 $Snapshot.credential.version
        proxy_active_sessions = [int64]$Snapshot.proxy.active_sessions
        mesh_active_sessions = Get-MishOptionalInt64 $Snapshot.mesh.active_sessions
        rotation_active_tasks = [int64]$Snapshot.rotation.active_tasks
    }
}

function Wait-MishStopped {
    param([Parameter(Mandatory)][int] $ExpectedPid)

    $deadline = [Environment]::TickCount64 + ([int64]$TransitionDeadlineSeconds * 1000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ([Environment]::TickCount64 -lt $deadline) {
        $snapshot = Get-MishAndroidSnapshot
        if (
            [int]$snapshot.pid -eq $ExpectedPid -and
            -not [bool]$snapshot.runtime.running -and
            -not [bool]$snapshot.credential.active -and
            $null -eq (Get-MishOptionalInt64 $snapshot.credential.version) -and
            [int64]$snapshot.proxy.active_sessions -eq 0 -and
            ($null -eq $snapshot.mesh.active_sessions -or [int64]$snapshot.mesh.active_sessions -eq 0) -and
            [int64]$snapshot.rotation.active_tasks -eq 0
        ) {
            $watch.Stop()
            return [ordered]@{
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                snapshot = $snapshot
                resources = Get-MishProcessMetrics -Snapshot $snapshot
            }
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }
    $watch.Stop()
    Stop-MishRestartProbe 'PRODUCT_STOP_NOT_QUIESCENT' 'Runtime stop did not reach stopped/quiescent state in the same process.'
}

function Wait-MishReady {
    param(
        [Parameter(Mandatory)][int] $ExpectedPid,
        [Parameter(Mandatory)][int64] $ExpectedCredentialVersion,
        [Parameter(Mandatory)][int64] $PreviousRuntimeGeneration
    )

    $deadline = [Environment]::TickCount64 + ([int64]$TransitionDeadlineSeconds * 1000)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ([Environment]::TickCount64 -lt $deadline) {
        $snapshot = Get-MishAndroidSnapshot
        if (
            [int]$snapshot.pid -eq $ExpectedPid -and
            [bool]$snapshot.runtime.running -and
            [int64]$snapshot.runtime.generation -gt $PreviousRuntimeGeneration -and
            [bool]$snapshot.cellular.admitted -and
            [bool]$snapshot.root.policy_authorized -and
            [bool]$snapshot.proxy.healthy -and
            [bool]$snapshot.credential.active -and
            (Get-MishOptionalInt64 $snapshot.credential.version) -eq $ExpectedCredentialVersion -and
            [string]$snapshot.readiness.state -ceq 'READY' -and
            [bool]$snapshot.mesh.admitted -and
            [bool]$snapshot.mesh.ingress_running -and
            [int64]$snapshot.proxy.active_sessions -eq 0 -and
            ($null -eq $snapshot.mesh.active_sessions -or [int64]$snapshot.mesh.active_sessions -eq 0) -and
            [int64]$snapshot.rotation.active_tasks -eq 0
        ) {
            $watch.Stop()
            return [ordered]@{
                elapsed_ms = [int64]$watch.ElapsedMilliseconds
                snapshot = $snapshot
            }
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }
    $watch.Stop()
    Stop-MishRestartProbe 'PRODUCT_RESTART_NOT_READY' 'Runtime start did not recover exact READY/quiescent state.'
}

function Wait-MishResourceQuiescence {
    param(
        [Parameter(Mandatory)][int] $ExpectedPid,
        [Parameter(Mandatory)][int64] $ExpectedCredentialVersion,
        [Parameter(Mandatory)] $BaselineMetrics,
        [ValidateRange(2, 4)][int] $RequiredConsecutiveSamples = 2,
        [ValidateRange(5, 30)][int] $DeadlineSeconds = 15
    )

    $started = [Environment]::TickCount64
    $deadline = $started + ([int64]$DeadlineSeconds * 1000)
    $samples = [Collections.Generic.List[object]]::new()
    $consecutive = 0
    $last = $null

    while ([Environment]::TickCount64 -lt $deadline) {
        $snapshot = Get-MishAndroidSnapshot
        Assert-MishReady -Snapshot $snapshot -ExpectedCredentialVersion $ExpectedCredentialVersion
        $metrics = Get-MishProcessMetrics -Snapshot $snapshot
        $last = $metrics

        $accepted = (
            [int]$metrics.pid -eq $ExpectedPid -and
            [int]$metrics.threads -le [int]$BaselineMetrics.threads -and
            [int]$metrics.fd_count -le [int]$BaselineMetrics.fd_count -and
            [int64]$metrics.proxy_active_sessions -eq 0 -and
            ($null -eq $metrics.mesh_active_sessions -or [int64]$metrics.mesh_active_sessions -eq 0) -and
            [int64]$metrics.rotation_active_tasks -eq 0
        )

        [void]$samples.Add([ordered]@{
            elapsed_ms = [Environment]::TickCount64 - $started
            threads = [int]$metrics.threads
            fd_count = [int]$metrics.fd_count
            rss_kb = [int64]$metrics.rss_kb
            pss_kb = [int64]$metrics.pss_kb
            runtime_generation = [int64]$metrics.runtime_generation
            root_session_generation = Get-MishOptionalInt64 $metrics.root_session_generation
            accepted = $accepted
        })

        if ($accepted) {
            $consecutive += 1
            if ($consecutive -ge $RequiredConsecutiveSamples) {
                return [ordered]@{
                    accepted = $true
                    required_consecutive_samples = $RequiredConsecutiveSamples
                    observed_consecutive_samples = $consecutive
                    deadline_seconds = $DeadlineSeconds
                    samples = @($samples)
                    metrics = $last
                }
            }
        }
        else {
            $consecutive = 0
        }
        Start-Sleep -Milliseconds 600
    }

    return [ordered]@{
        accepted = $false
        required_consecutive_samples = $RequiredConsecutiveSamples
        observed_consecutive_samples = $consecutive
        deadline_seconds = $DeadlineSeconds
        samples = @($samples)
        metrics = $last
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishRestartProbe 'LAB_ADB_MISSING' 'Canonical ADB executable is missing.'
}

$acceptanceResult = 'FAIL'
$classification = 'U7_RUNTIME_RESTART_RESOURCES_INCOMPLETE'
$detail = $null
$cyclesEvidence = [Collections.Generic.List[object]]::new()
$restoreRequired = $false
$initialSnapshot = $null
$baselineMetrics = $null
$finalMetrics = $null
$expectedPid = $null
$expectedCredentialVersion = $null
$initialRootSessionGeneration = $null

try {
    $initialSnapshot = Get-MishAndroidSnapshot
    $expectedCredentialVersion = Get-MishOptionalInt64 $initialSnapshot.credential.version
    if ($null -eq $expectedCredentialVersion) {
        Stop-MishRestartProbe 'PRODUCT_BASELINE_NOT_READY' 'Runtime restart probe requires an active credential version.'
    }
    Assert-MishReady -Snapshot $initialSnapshot -ExpectedCredentialVersion $expectedCredentialVersion
    $baselineMetrics = Get-MishProcessMetrics -Snapshot $initialSnapshot
    $expectedPid = [int]$baselineMetrics.pid
    $initialRootSessionGeneration = Get-MishOptionalInt64 $baselineMetrics.root_session_generation

    for ($ordinal = 1; $ordinal -le $Cycles; $ordinal++) {
        $generationBefore = [int64]$initialSnapshot.runtime.generation
        if ($cyclesEvidence.Count -gt 0) {
            $generationBefore = [int64]$cyclesEvidence[$cyclesEvidence.Count - 1].ready.resources.runtime_generation
        }

        Invoke-MishActivityTrigger -Component $script:StopComponent -Operation "restart_cycle_$ordinal-stop"
        $restoreRequired = $true
        $stopped = Wait-MishStopped -ExpectedPid $expectedPid

        Invoke-MishActivityTrigger -Component $script:StartComponent -Operation "restart_cycle_$ordinal-start"
        $ready = Wait-MishReady -ExpectedPid $expectedPid -ExpectedCredentialVersion $expectedCredentialVersion -PreviousRuntimeGeneration $generationBefore
        $quiescence = Wait-MishResourceQuiescence -ExpectedPid $expectedPid -ExpectedCredentialVersion $expectedCredentialVersion -BaselineMetrics $baselineMetrics
        if (-not [bool]$quiescence.accepted) {
            Stop-MishRestartProbe 'PRODUCT_RESTART_RESOURCE_NOT_QUIESCENT' "Runtime restart cycle $ordinal did not return threads/FD/session/task resources to the baseline bound."
        }

        $restoreRequired = $false
        [void]$cyclesEvidence.Add([ordered]@{
            ordinal = $ordinal
            stop = [ordered]@{
                elapsed_ms = [int64]$stopped.elapsed_ms
                resources = $stopped.resources
            }
            ready = [ordered]@{
                elapsed_ms = [int64]$ready.elapsed_ms
                resources = $quiescence.metrics
                quiescence = $quiescence
            }
            delta_from_initial = [ordered]@{
                threads = [int]$quiescence.metrics.threads - [int]$baselineMetrics.threads
                fd_count = [int]$quiescence.metrics.fd_count - [int]$baselineMetrics.fd_count
                rss_kb = [int64]$quiescence.metrics.rss_kb - [int64]$baselineMetrics.rss_kb
                pss_kb = [int64]$quiescence.metrics.pss_kb - [int64]$baselineMetrics.pss_kb
            }
        })
    }

    $finalMetrics = $cyclesEvidence[$cyclesEvidence.Count - 1].ready.resources
    $acceptanceResult = 'PASS'
    $classification = 'U7_RUNTIME_RESTART_RESOURCES_PASS'
}
catch {
    $message = $_.Exception.Message
    if ($message -match '^MISH_U7_RESTART_FAILURE\|(?<classification>[A-Z0-9_]+)\|(?<detail>.*)$') {
        $classification = $Matches['classification']
        $detail = $Matches['detail']
    }
    else {
        $classification = 'LAB_U7_RUNTIME_RESTART_UNEXPECTED_FAILURE'
        $detail = $message
    }
}
finally {
    if ($restoreRequired) {
        try {
            Invoke-MishActivityTrigger -Component $script:StartComponent -Operation 'failure_restore_start'
            if ($null -ne $expectedPid -and $null -ne $expectedCredentialVersion -and $null -ne $initialSnapshot) {
                [void](Wait-MishReady -ExpectedPid $expectedPid -ExpectedCredentialVersion $expectedCredentialVersion -PreviousRuntimeGeneration ([int64]$initialSnapshot.runtime.generation))
            }
        }
        catch {
            if ([string]::IsNullOrWhiteSpace($detail)) {
                $detail = 'Probe failure restore could not return runtime to READY.'
            }
        }
    }
}

$rootSessionStable = $true
if ($null -ne $initialRootSessionGeneration) {
    foreach ($cycle in @($cyclesEvidence)) {
        $value = Get-MishOptionalInt64 $cycle.ready.resources.root_session_generation
        if ($null -eq $value -or $value -ne $initialRootSessionGeneration) {
            $rootSessionStable = $false
            break
        }
    }
}

$memoryTrend = [ordered]@{
    acceptance_threshold = 'NONE_OBSERVATIONAL_ONLY'
    rss_deltas_kb = @($cyclesEvidence | ForEach-Object { [int64]$_.delta_from_initial.rss_kb })
    pss_deltas_kb = @($cyclesEvidence | ForEach-Object { [int64]$_.delta_from_initial.pss_kb })
}

$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = $acceptanceResult
    classification = $classification
    detail = $detail
    package = $PackageName
    cycles_requested = $Cycles
    cycles_completed = $cyclesEvidence.Count
    product_pid_stable = if ($null -ne $expectedPid) { $true } else { $false }
    credential_version_stable = (
        $null -ne $expectedCredentialVersion -and
        @($cyclesEvidence | Where-Object { [int64]$_.ready.resources.credential_version -ne [int64]$expectedCredentialVersion }).Count -eq 0
    )
    root_session_generation_stable = $rootSessionStable
    baseline = $baselineMetrics
    cycles = @($cyclesEvidence)
    final = $finalMetrics
    memory_trend = $memoryTrend
    acceptance_policy = [ordered]@{
        same_pid_required = $true
        ready_after_each_cycle = $true
        runtime_generation_must_advance = $true
        credential_version_must_survive = $true
        threads_must_return_to_initial_bound = $true
        fd_must_return_to_initial_bound = $true
        owner_sessions_must_return_to_zero = $true
        rotation_tasks_must_return_to_zero = $true
        rss_pss_are_observational = $true
    }
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_U7_RUNTIME_RESTART_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_U7_RUNTIME_RESTART_CLASSIFICATION=$classification"
Write-Host "MISH_U7_RUNTIME_RESTART_CYCLES=$($cyclesEvidence.Count)"
Write-Host "MISH_U7_RUNTIME_RESTART_EVIDENCE=$fullEvidencePath"

if ($acceptanceResult -cne 'PASS') {
    throw "MISH_U7_RUNTIME_RESTART_RESULT|$acceptanceResult|$classification"
}
