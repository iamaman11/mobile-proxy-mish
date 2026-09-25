[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [ValidateRange(5, 30)][int] $SafetyEnvelopeSeconds = 15,
    [ValidateRange(50, 500)][int] $ObservationSampleMilliseconds = 100,
    [ValidateRange(10, 90)][int] $RecoveryDeadlineSeconds = 45,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-radio-poweroff-characterization-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.radio-poweroff-characterization/v1'
$script:DiagnosticSchema = 'mish.diagnostics/v2'

Import-Module (Join-Path $PSScriptRoot 'TelephonyDetachObservation.psm1') -Force

function Stop-MishRadioPoweroffCharacterization {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_RADIO_POWEROFF_CHARACTERIZATION_FAILURE|$Category|$Message"
}

function Invoke-MishAdbText {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Operation
    )
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        Stop-MishRadioPoweroffCharacterization 'ADB_FAILED' "ADB operation '$Operation' failed with exit code $exitCode."
    }
    return ($rows -join [Environment]::NewLine).Trim()
}

function Get-MishAirplaneState {
    $value = Invoke-MishAdbText -Operation 'read airplane state' -Arguments @(
        'shell', 'settings', 'get', 'global', 'airplane_mode_on'
    )
    if ($value -notin @('0', '1')) {
        Stop-MishRadioPoweroffCharacterization 'AIRPLANE_STATE_INVALID' "Unexpected airplane_mode_on value '$value'."
    }
    return [int]$value
}

function Set-MishAirplaneState {
    param([Parameter(Mandatory)][ValidateSet('enable','disable')][string] $State)
    [void](Invoke-MishAdbText -Operation "airplane $State" -Arguments @(
        'shell', 'su', '-c', "cmd connectivity airplane-mode $State"
    ))
}

function Get-MishPid {
    $pidText = Invoke-MishAdbText -Operation 'pidof PRODUCT' -Arguments @(
        'shell', 'pidof', $PackageName
    )
    if ($pidText -notmatch '^\d+$') {
        Stop-MishRadioPoweroffCharacterization 'PRODUCT_PROCESS_NOT_RUNNING' 'Exactly one PRODUCT PID is required.'
    }
    return [int64]$pidText
}

function Get-MishDiagnosticSnapshot {
    $capture = Invoke-MishAdbText -Operation 'snapshot_v2' -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', 'snapshot_v2'
    )
    $match = [regex]::Match($capture, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) {
        Stop-MishRadioPoweroffCharacterization 'DIAGNOSTIC_INVALID' 'PRODUCT diagnostics returned no payload.'
    }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        $snapshot = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch {
        Stop-MishRadioPoweroffCharacterization 'DIAGNOSTIC_INVALID' 'PRODUCT diagnostics payload is malformed.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if ([string]$snapshot.schema -cne $script:DiagnosticSchema -or
        [string]$snapshot.application_id -cne $PackageName -or
        -not [bool]$snapshot.consistent) {
        Stop-MishRadioPoweroffCharacterization 'DIAGNOSTIC_INVALID' 'PRODUCT diagnostics identity/consistency mismatch.'
    }
    return $snapshot
}

function Test-MishHealthySnapshot {
    param([Parameter(Mandatory)] $Snapshot)
    return (
        [bool]$Snapshot.runtime.running -and
        [bool]$Snapshot.cellular.admitted -and
        [bool]$Snapshot.root.policy_authorized -and
        [string]$Snapshot.proxy.state -ceq 'RUNNING' -and
        [bool]$Snapshot.mesh.admitted -and
        [bool]$Snapshot.mesh.ingress_running -and
        [string]$Snapshot.readiness.state -ceq 'READY' -and
        [int64]$Snapshot.rotation.active_tasks -eq 0 -and
        -not [bool]$Snapshot.rotation.restore_required
    )
}

function Wait-MishAirplaneOff {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt 5000) {
        if ((Get-MishAirplaneState) -eq 0) {
            return
        }
        [Threading.Thread]::Sleep(100)
    }
    Stop-MishRadioPoweroffCharacterization 'AIRPLANE_RESTORE_NOT_OBSERVED' 'Airplane OFF was not observed within the restore safety bound.'
}

function Wait-MishProductRecovery {
    param([Parameter(Mandatory)][int64] $ExpectedRotationOperationId)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $last = $null
    while ($watch.Elapsed.TotalSeconds -lt $RecoveryDeadlineSeconds) {
        $last = Get-MishDiagnosticSnapshot
        if ([int64]$last.rotation.operation_id -ne $ExpectedRotationOperationId) {
            Stop-MishRadioPoweroffCharacterization 'PRODUCT_ROTATION_MUTATED' 'LAB radio characterization unexpectedly advanced the PRODUCT Rotation operation id.'
        }
        if (Test-MishHealthySnapshot -Snapshot $last) {
            return $last
        }
        [Threading.Thread]::Sleep(250)
    }
    Stop-MishRadioPoweroffCharacterization 'PRODUCT_RECOVERY_DEADLINE' 'PRODUCT did not recover to the accepted healthy state within the bounded restore deadline.'
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishRadioPoweroffCharacterization 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

$devices = @(& $AdbPath devices | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {
    Stop-MishRadioPoweroffCharacterization 'DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.'
}
$model = (Invoke-MishAdbText -Operation 'read model' -Arguments @('shell','getprop','ro.product.model')).Trim()
$api = (Invoke-MishAdbText -Operation 'read API' -Arguments @('shell','getprop','ro.build.version.sdk')).Trim()
$abi = (Invoke-MishAdbText -Operation 'read ABI' -Arguments @('shell','getprop','ro.product.cpu.abi')).Trim()
if ($model -cne 'SM-A022G' -or $api -cne '30' -or $abi -cne 'armeabi-v7a') {
    Stop-MishRadioPoweroffCharacterization 'DEVICE_IDENTITY_MISMATCH' "Expected SM-A022G/API30/armeabi-v7a; observed $model/API$api/$abi."
}

$initialAirplane = Get-MishAirplaneState
if ($initialAirplane -ne 0) {
    Stop-MishRadioPoweroffCharacterization 'INITIAL_AIRPLANE_ON' 'Characterization requires airplane mode initially OFF.'
}

$pidBefore = Get-MishPid
$baseline = Get-MishDiagnosticSnapshot
if (-not (Test-MishHealthySnapshot -Snapshot $baseline)) {
    Stop-MishRadioPoweroffCharacterization 'BASELINE_NOT_HEALTHY' 'PRODUCT baseline is not runtime/Cellular/root/Proxy/Mesh/readiness healthy.'
}
$rotationOperationBefore = [int64]$baseline.rotation.operation_id

$observerStarted = $false
$observerStopped = $false
$airplaneEnableAttempted = $false
$restoreAttempted = $false
$restoreVerified = $false
$telephonyFinal = $null
$powerOffEvent = $null
$outOfServiceEvent = $null
$enableWindowLower = $null
$enableWindowUpper = $null
$classification = 'UNKNOWN'

try {
    [void](Start-MishTelephonyDetachObservation -AdbPath $AdbPath -PackageName $PackageName)
    $observerStarted = $true

    $preEnable = Get-MishTelephonyDetachObservationSnapshot -AdbPath $AdbPath -PackageName $PackageName
    $enableWindowLower = [int64]$preEnable.correlation.elapsed_after_control_snapshot_ms

    $airplaneEnableAttempted = $true
    Set-MishAirplaneState -State 'enable'

    $postEnable = Get-MishTelephonyDetachObservationSnapshot -AdbPath $AdbPath -PackageName $PackageName
    $enableWindowUpper = [int64]$postEnable.correlation.elapsed_before_control_snapshot_ms
    if ($enableWindowUpper -lt $enableWindowLower) {
        Stop-MishRadioPoweroffCharacterization 'MONOTONIC_WINDOW_INVALID' 'Airplane-enable monotonic correlation window is inverted.'
    }
    if ((Get-MishAirplaneState) -ne 1) {
        Stop-MishRadioPoweroffCharacterization 'AIRPLANE_ON_NOT_OBSERVED' 'Root airplane enable returned but airplane_mode_on did not become 1.'
    }

    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt $SafetyEnvelopeSeconds) {
        $sample = Get-MishTelephonyDetachObservationSnapshot -AdbPath $AdbPath -PackageName $PackageName
        $events = @($sample.events | Where-Object { [int64]$_.elapsed_realtime_ms -ge $enableWindowLower })
        if ($null -eq $outOfServiceEvent) {
            $candidate = @($events | Where-Object { [string]$_.state_name -ceq 'OUT_OF_SERVICE' } | Select-Object -First 1)
            if ($candidate.Count -gt 0) { $outOfServiceEvent = $candidate[0] }
        }
        $candidatePowerOff = @($events | Where-Object { [string]$_.state_name -ceq 'POWER_OFF' } | Select-Object -First 1)
        if ($candidatePowerOff.Count -gt 0) {
            $powerOffEvent = $candidatePowerOff[0]
            $classification = 'POWER_OFF_OBSERVED'
            break
        }

        # This wait only rate-limits read-only LAB snapshots. It is not a PRODUCT transition,
        # dwell requirement, retry policy or timing input.
        [Threading.Thread]::Sleep($ObservationSampleMilliseconds)
    }
    if ($null -eq $powerOffEvent) {
        $classification = 'POWER_OFF_NOT_OBSERVED_WITHIN_SAFETY_ENVELOPE'
    }

    $restoreAttempted = $true
    Set-MishAirplaneState -State 'disable'
    Wait-MishAirplaneOff
    $restoreVerified = $true

    $finalSnapshot = Wait-MishProductRecovery -ExpectedRotationOperationId $rotationOperationBefore
    $pidAfter = Get-MishPid
    if ($pidAfter -ne $pidBefore) {
        Stop-MishRadioPoweroffCharacterization 'PRODUCT_PID_CHANGED' 'PRODUCT PID changed during the bounded radio characterization.'
    }

    $telephonyFinal = Stop-MishTelephonyDetachObservation -AdbPath $AdbPath -PackageName $PackageName -EvidencePath (Join-Path $env:TEMP 'mish-radio-poweroff-telephony-v1.json')
    $observerStopped = $true

    if ($null -eq $outOfServiceEvent) {
        $candidate = @($telephonyFinal.events | Where-Object {
            [int64]$_.elapsed_realtime_ms -ge $enableWindowLower -and
            [string]$_.state_name -ceq 'OUT_OF_SERVICE'
        } | Select-Object -First 1)
        if ($candidate.Count -gt 0) { $outOfServiceEvent = $candidate[0] }
    }
    if ($null -eq $powerOffEvent) {
        $candidate = @($telephonyFinal.events | Where-Object {
            [int64]$_.elapsed_realtime_ms -ge $enableWindowLower -and
            [string]$_.state_name -ceq 'POWER_OFF'
        } | Select-Object -First 1)
        if ($candidate.Count -gt 0) {
            $powerOffEvent = $candidate[0]
            $classification = 'POWER_OFF_OBSERVED_BEFORE_RESTORE_COMPLETION'
        }
    }

    function New-EventProjection {
        param($Event)
        if ($null -eq $Event) { return $null }
        $elapsed = [int64]$Event.elapsed_realtime_ms
        return [ordered]@{
            state = [string]$Event.state_name
            elapsed_realtime_ms = $elapsed
            from_airplane_enable_lower_ms = $elapsed - [int64]$enableWindowUpper
            from_airplane_enable_upper_ms = $elapsed - [int64]$enableWindowLower
        }
    }

    $evidence = [ordered]@{
        schema = $script:Schema
        collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        result = 'PASS'
        classification = $classification
        device = [ordered]@{
            model = $model
            api = [int]$api
            abi = $abi
            pid_stable = $true
        }
        baseline = [ordered]@{
            airplane_off = $true
            product_healthy = $true
            rotation_operation_id = $rotationOperationBefore
        }
        observation = [ordered]@{
            observer = 'PhoneStateListener.LISTEN_SERVICE_STATE'
            active_data_subscription = 'TYPED_API30_NO_ID_PERSISTED'
            sample_interval_ms = $ObservationSampleMilliseconds
            safety_envelope_ms = $SafetyEnvelopeSeconds * 1000
            safety_envelope_role = 'LAB_RESTORE_ONLY_NOT_PRODUCT_TRANSITION'
            airplane_enable_elapsed_lower_ms = $enableWindowLower
            airplane_enable_elapsed_upper_ms = $enableWindowUpper
            first_out_of_service = New-EventProjection -Event $outOfServiceEvent
            first_power_off = New-EventProjection -Event $powerOffEvent
            power_off_observed = $null -ne $powerOffEvent
            event_count = [int]$telephonyFinal.event_count
        }
        mutation = [ordered]@{
            adb_lab_radio_mutation_performed = $true
            product_mutation_performed = $false
            product_rotation_triggered = $false
            manager_command_issued = $false
            public_ip_polled = $false
            retry_until_changed = $false
        }
        restore = [ordered]@{
            attempted = $restoreAttempted
            airplane_off_verified = $restoreVerified
            product_pid_stable = $true
            product_recovered = Test-MishHealthySnapshot -Snapshot $finalSnapshot
            rotation_operation_id_unchanged = ([int64]$finalSnapshot.rotation.operation_id -eq $rotationOperationBefore)
            cellular_admitted = [bool]$finalSnapshot.cellular.admitted
            root_authorized = [bool]$finalSnapshot.root.policy_authorized
            proxy_running = ([string]$finalSnapshot.proxy.state -ceq 'RUNNING')
            mesh_admitted = [bool]$finalSnapshot.mesh.admitted
            readiness = [string]$finalSnapshot.readiness.state
        }
        raw_public_ip_persisted = $false
        subscription_id_persisted = $false
        operator_identity_persisted = $false
        secrets_persisted_in_evidence = $false
        architecture_decision = 'NOT_MADE'
    }

    $fullPath = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $fullPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullPath,
        (($evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host 'MISH_RADIO_POWEROFF_CHARACTERIZATION=PASS'
    Write-Host "MISH_RADIO_POWEROFF_CLASSIFICATION=$classification"
    Write-Host "MISH_RADIO_POWEROFF_OBSERVED=$($null -ne $powerOffEvent)"
    if ($null -ne $powerOffEvent) {
        Write-Host "MISH_RADIO_POWEROFF_ELAPSED_MS=$([int64]$powerOffEvent.elapsed_realtime_ms)"
    }
    Write-Host 'MISH_RADIO_POWEROFF_PRODUCT_ROTATION_TRIGGERED=false'
    Write-Host 'MISH_RADIO_POWEROFF_MANAGER_COMMAND_ISSUED=false'
    Write-Host 'MISH_RADIO_POWEROFF_RESTORE=PASS'
    Write-Host "MISH_RADIO_POWEROFF_EVIDENCE=$fullPath"
}
finally {
    if ($airplaneEnableAttempted -and -not $restoreVerified) {
        try {
            $restoreAttempted = $true
            Set-MishAirplaneState -State 'disable'
            Wait-MishAirplaneOff
            $restoreVerified = $true
        }
        catch {
            Write-Warning 'MISH_RADIO_POWEROFF_EMERGENCY_RESTORE=FAILED'
        }
    }
    if ($observerStarted -and -not $observerStopped) {
        try {
            [void](Stop-MishTelephonyDetachObservation -AdbPath $AdbPath -PackageName $PackageName -EvidencePath (Join-Path $env:TEMP 'mish-radio-poweroff-telephony-v1.json'))
        }
        catch {
            Write-Warning 'MISH_RADIO_POWEROFF_OBSERVER_CLEANUP=FAILED'
        }
    }
}
