$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Invoke-MishU7AdbOptionalText {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $output = @(& $AdbPath @Arguments 2>$null | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) { return $null }
    return ($output -join [Environment]::NewLine).Trim()
}

function Get-MishU7LatencyDistribution {
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

function Get-MishU7CpuTickSnapshot {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $PidText
    )
    $processStat = Invoke-MishU7AdbOptionalText -AdbPath $AdbPath -Arguments @('shell', 'run-as', $PackageName, 'cat', "/proc/$PidText/stat")
    $systemStat = Invoke-MishU7AdbOptionalText -AdbPath $AdbPath -Arguments @('shell', 'cat', '/proc/stat')
    $processStatus = Invoke-MishU7AdbOptionalText -AdbPath $AdbPath -Arguments @('shell', 'run-as', $PackageName, 'cat', "/proc/$PidText/status")
    if ([string]::IsNullOrWhiteSpace($processStat) -or [string]::IsNullOrWhiteSpace($systemStat)) { return $null }

    $close = $processStat.LastIndexOf(') ')
    if ($close -lt 0) { return $null }
    $fields = @($processStat.Substring($close + 2) -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($fields.Count -lt 13) { return $null }
    try { $processTicks = [int64]$fields[11] + [int64]$fields[12] } catch { return $null }

    $cpuMatch = [regex]::Match($systemStat, '(?m)^cpu\s+(?<values>[0-9\s]+)$')
    if (-not $cpuMatch.Success) { return $null }
    $cpuValues = @($cpuMatch.Groups['values'].Value -split '\s+' | Where-Object { $_ -match '^\d+$' })
    if ($cpuValues.Count -lt 4) { return $null }
    [int64]$totalTicks = 0
    foreach ($value in $cpuValues) { $totalTicks += [int64]$value }
    $cpuCount = [regex]::Matches($systemStat, '(?m)^cpu\d+\s').Count
    if ($cpuCount -le 0) { return $null }

    $voluntary = $null
    $nonvoluntary = $null
    if (-not [string]::IsNullOrWhiteSpace($processStatus)) {
        $voluntaryMatch = [regex]::Match($processStatus, '(?m)^voluntary_ctxt_switches:\s*(?<value>\d+)\s*$')
        $nonvoluntaryMatch = [regex]::Match($processStatus, '(?m)^nonvoluntary_ctxt_switches:\s*(?<value>\d+)\s*$')
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

function Get-MishU7CpuObservation {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $PidText,
        [int] $SampleMilliseconds = 1000
    )
    $before = Get-MishU7CpuTickSnapshot -AdbPath $AdbPath -PackageName $PackageName -PidText $PidText
    if ($null -eq $before) { return [ordered]@{ supported = $false; reason = 'PROC_CPU_UNAVAILABLE' } }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds $SampleMilliseconds
    $after = Get-MishU7CpuTickSnapshot -AdbPath $AdbPath -PackageName $PackageName -PidText $PidText
    $watch.Stop()
    if ($null -eq $after) { return [ordered]@{ supported = $false; reason = 'PROC_CPU_UNAVAILABLE' } }
    $processDelta = [int64]$after.process_ticks - [int64]$before.process_ticks
    $systemDelta = [int64]$after.system_ticks - [int64]$before.system_ticks
    if ($processDelta -lt 0 -or $systemDelta -le 0) { return [ordered]@{ supported = $false; reason = 'PROC_CPU_DELTA_INVALID' } }
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

function Get-MishU7PlatformObservation {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $PidText
    )
    $threadText = Invoke-MishU7AdbOptionalText -AdbPath $AdbPath -Arguments @('shell', 'run-as', $PackageName, 'sh', '-c', "cat /proc/$PidText/task/*/comm")
    $threadObservation = [ordered]@{ supported = $false; reason = 'THREAD_NAMES_UNAVAILABLE' }
    if (-not [string]::IsNullOrWhiteSpace($threadText)) {
        $names = @($threadText -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $threadObservation = [ordered]@{
            supported = $true
            observed_threads = $names.Count
            product_tokio_named_threads = @($names | Where-Object { $_ -ceq 'mish-runtime-io' }).Count
        }
    }

    $batteryText = Invoke-MishU7AdbOptionalText -AdbPath $AdbPath -Arguments @('shell', 'dumpsys', 'battery')
    $battery = [ordered]@{ supported = $false; reason = 'BATTERY_UNAVAILABLE' }
    if (-not [string]::IsNullOrWhiteSpace($batteryText)) {
        $level = [regex]::Match($batteryText, '(?m)^\s*level:\s*(?<value>\d+)\s*$')
        $scale = [regex]::Match($batteryText, '(?m)^\s*scale:\s*(?<value>\d+)\s*$')
        $temperature = [regex]::Match($batteryText, '(?m)^\s*temperature:\s*(?<value>-?\d+)\s*$')
        $plugged = [regex]::Match($batteryText, '(?m)^\s*plugged:\s*(?<value>\d+)\s*$')
        $status = [regex]::Match($batteryText, '(?m)^\s*status:\s*(?<value>\d+)\s*$')
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

    $thermalText = Invoke-MishU7AdbOptionalText -AdbPath $AdbPath -Arguments @('shell', 'dumpsys', 'thermalservice')
    $thermal = [ordered]@{ supported = $false; reason = 'THERMAL_STATUS_UNAVAILABLE' }
    if (-not [string]::IsNullOrWhiteSpace($thermalText)) {
        $thermalMatch = [regex]::Match($thermalText, '(?im)^\s*(?:current\s+)?thermal\s+status:\s*(?<value>\d+)\s*$')
        if ($thermalMatch.Success) { $thermal = [ordered]@{ supported = $true; status = [int]$thermalMatch.Groups['value'].Value } }
    }

    $psText = Invoke-MishU7AdbOptionalText -AdbPath $AdbPath -Arguments @('shell', 'ps', '-A', '-o', 'PID,PPID,NAME')
    $rootProcesses = [ordered]@{ supported = $false; reason = 'PROCESS_TREE_UNAVAILABLE' }
    if (-not [string]::IsNullOrWhiteSpace($psText)) {
        $rows = [Collections.Generic.List[object]]::new()
        foreach ($line in ($psText -split '\r?\n')) {
            $match = [regex]::Match($line, '^\s*(?<pid>\d+)\s+(?<ppid>\d+)\s+(?<name>\S+)\s*$')
            if ($match.Success) {
                [void]$rows.Add([pscustomobject]@{ pid = [int]$match.Groups['pid'].Value; ppid = [int]$match.Groups['ppid'].Value; name = [string]$match.Groups['name'].Value })
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
        threads = $threadObservation
        battery = $battery
        thermal = $thermal
        root_processes = $rootProcesses
    }
}

function Measure-MishU7SupplementalObservation {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $PidText
    )
    return [ordered]@{
        cpu = Get-MishU7CpuObservation -AdbPath $AdbPath -PackageName $PackageName -PidText $PidText
        platform = Get-MishU7PlatformObservation -AdbPath $AdbPath -PackageName $PackageName -PidText $PidText
    }
}

Export-ModuleMember -Function Get-MishU7LatencyDistribution, Measure-MishU7SupplementalObservation
