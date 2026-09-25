Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TelephonyDetachNativeSchema = 'mish.debug.telephony-detach/v1'
$script:TelephonyDetachEvidenceSchema = 'mish.lab.telephony-detach-observation/v1'
function Stop-MishTelephonyDetachFailure {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_TELEPHONY_DETACH_FAILURE|$Category|$Message"
}

function Invoke-MishTelephonyAdb {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Text = ($rows -join [Environment]::NewLine).Trim()
    }
}

function Invoke-MishTelephonyProviderCall {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][ValidateSet('start_v1','snapshot_v1','stop_v1')][string] $Method
    )

    $capture = Invoke-MishTelephonyAdb -AdbPath $AdbPath -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.telephony-detach-diagnostics",
        '--method', $Method
    )
    if ($capture.ExitCode -ne 0) {
        Stop-MishTelephonyDetachFailure 'PROVIDER_CALL_FAILED' "Typed telephony provider call $Method failed."
    }

    $payloadMatch = [regex]::Match($capture.Text, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $payloadMatch.Success) {
        Stop-MishTelephonyDetachFailure 'PROVIDER_PAYLOAD_MISSING' "Typed telephony provider call $Method returned no payload."
    }

    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
        $snapshot = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch {
        Stop-MishTelephonyDetachFailure 'PROVIDER_PAYLOAD_INVALID' 'Typed telephony provider payload is malformed.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }

    if ([string]$snapshot.schema -cne $script:TelephonyDetachNativeSchema -or
        [string]$snapshot.application_id -cne $PackageName) {
        Stop-MishTelephonyDetachFailure 'PROVIDER_IDENTITY_MISMATCH' 'Typed telephony provider schema/package mismatch.'
    }
    if ([bool]$snapshot.product_mutation_performed -or
        [bool]$snapshot.radio_mutation_performed -or
        [bool]$snapshot.rotation_triggered -or
        [bool]$snapshot.raw_public_ip_persisted -or
        [bool]$snapshot.subscription_id_persisted) {
        Stop-MishTelephonyDetachFailure 'PROVIDER_CONTRACT_VIOLATION' 'Typed telephony observer reported a forbidden mutation or persisted sensitive field.'
    }

    return $snapshot
}

function Start-MishTelephonyDetachObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PackageName
    )

    $snapshot = Invoke-MishTelephonyProviderCall -AdbPath $AdbPath -PackageName $PackageName -Method 'start_v1'
    if (-not [bool]$snapshot.active -or -not [bool]$snapshot.active_data_subscription_valid) {
        Stop-MishTelephonyDetachFailure 'OBSERVER_NOT_ACTIVE' 'Typed telephony observer did not become active on the active data subscription.'
    }
    Write-Host 'MISH_TELEPHONY_DETACH_OBSERVER=STARTED'
    return $snapshot
}

function Stop-MishTelephonyDetachObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PackageName,
        [Parameter(Mandatory)][string] $EvidencePath
    )

    $snapshot = $null
    try {
        $snapshot = Invoke-MishTelephonyProviderCall -AdbPath $AdbPath -PackageName $PackageName -Method 'stop_v1'

        if ([bool]$snapshot.active) {
            Stop-MishTelephonyDetachFailure 'OBSERVER_STILL_ACTIVE' 'Typed telephony observer remained active after stop.'
        }
        if ($null -eq $snapshot.correlation) {
            Stop-MishTelephonyDetachFailure 'CORRELATION_MISSING' 'Typed telephony stop snapshot has no CONTROL clock correlation.'
        }

        $serialized = $snapshot | ConvertTo-Json -Depth 8 -Compress
        foreach ($forbidden in @(
            'operator',
            'plmn',
            'cell_identity',
            'phone_number',
            'imei',
            'imsi',
            'request_id',
            'manager_token'
        )) {
            if ($serialized -match ('(?i)"' + [regex]::Escape($forbidden) + '"\s*:')) {
                Stop-MishTelephonyDetachFailure 'SENSITIVE_FIELD_PRESENT' "Typed telephony evidence contains forbidden field: $forbidden."
            }
        }

        $evidence = [ordered]@{
            schema = $script:TelephonyDetachEvidenceSchema
            collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
            application_id = $PackageName
            native = $snapshot
            runtime_permission_mutation_performed = $false
            product_mutation_performed = $false
            radio_mutation_performed = $false
            rotation_triggered = $false
            raw_public_ip_persisted = $false
            subscription_id_persisted = $false
            secrets_persisted_in_evidence = $false
        }

        $fullPath = [IO.Path]::GetFullPath($EvidencePath)
        $parent = Split-Path -Parent $fullPath
        if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
        [IO.File]::WriteAllText(
            $fullPath,
            (($evidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )

        Write-Host "MISH_TELEPHONY_DETACH_OBSERVER=STOPPED/events=$([int]$snapshot.event_count)"
        Write-Host "MISH_TELEPHONY_DETACH_EVIDENCE=$fullPath"
        return $snapshot
    }
    finally {
        # No runtime permission is granted or revoked by this diagnostic.
    }
}

function New-MishTelephonyDetachResearchProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Observation,
        [Parameter(Mandatory)][long] $OperationId,
        [Parameter(Mandatory)] $RotationTiming
    )

    $correlation = $Observation.correlation
    if ($null -eq $correlation.operation_id -or
        [int64]$correlation.operation_id -ne $OperationId -or
        $null -eq $correlation.operation_age_ms) {
        Stop-MishTelephonyDetachFailure 'OPERATION_CORRELATION_FAILED' 'Typed telephony observation does not correlate to the exact remote Rotation operation.'
    }

    $before = [int64]$correlation.elapsed_before_control_snapshot_ms
    $after = [int64]$correlation.elapsed_after_control_snapshot_ms
    $age = [int64]$correlation.operation_age_ms
    if ($after -lt $before -or $age -lt 0) {
        Stop-MishTelephonyDetachFailure 'CLOCK_CORRELATION_INVALID' 'Typed telephony/CONTROL clock correlation is invalid.'
    }

    $originLower = $before - $age
    $originUpper = $after - $age
    $disableStarted = [int64]$RotationTiming.airplane_disable_started_ms
    $cellularLoss = [int64]$RotationTiming.cellular_loss_observed_ms

    $events = @($Observation.events)
    $powerOffEvent = @($events | Where-Object {
        [string]$_.state_name -ceq 'POWER_OFF' -and
        [int64]$_.elapsed_realtime_ms -ge $originLower
    } | Select-Object -First 1)
    $outOfServiceEvent = @($events | Where-Object {
        [string]$_.state_name -ceq 'OUT_OF_SERVICE' -and
        [int64]$_.elapsed_realtime_ms -ge $originLower
    } | Select-Object -First 1)

    function Convert-Event {
        param($Event)
        if ($null -eq $Event) { return $null }
        $elapsed = [int64]$Event.elapsed_realtime_ms
        [ordered]@{
            state = [string]$Event.state_name
            elapsed_realtime_ms = $elapsed
            from_remote_command_lower_ms = $elapsed - $originUpper
            from_remote_command_upper_ms = $elapsed - $originLower
        }
    }

    $powerOff = if ($powerOffEvent.Count -eq 0) { $null } else { Convert-Event $powerOffEvent[0] }
    $outOfService = if ($outOfServiceEvent.Count -eq 0) { $null } else { Convert-Event $outOfServiceEvent[0] }

    $powerOffVsDisable = if ($null -eq $powerOff) {
        'NOT_OBSERVED'
    } elseif ([int64]$powerOff.from_remote_command_upper_ms -le $disableStarted) {
        'AT_OR_BEFORE_DISABLE_START'
    } elseif ([int64]$powerOff.from_remote_command_lower_ms -gt $disableStarted) {
        'AFTER_DISABLE_START'
    } else {
        'INDETERMINATE_WITHIN_CORRELATION_WINDOW'
    }

    $powerOffVsLoss = if ($null -eq $powerOff) {
        'NOT_OBSERVED'
    } elseif ([int64]$powerOff.from_remote_command_upper_ms -le $cellularLoss) {
        'AT_OR_BEFORE_CELLULAR_LOSS'
    } elseif ([int64]$powerOff.from_remote_command_lower_ms -gt $cellularLoss) {
        'AFTER_CELLULAR_LOSS'
    } else {
        'INDETERMINATE_WITHIN_CORRELATION_WINDOW'
    }

    [ordered]@{
        schema = 'mish.lab.telephony-detach-research/v1'
        operation_id = $OperationId
        observer = 'PhoneStateListener.LISTEN_SERVICE_STATE'
        active_data_subscription = 'TYPED_API30_NO_ID_PERSISTED'
        control_origin_correlation_window_ms = $after - $before
        operation_origin_elapsed_lower_ms = $originLower
        operation_origin_elapsed_upper_ms = $originUpper
        first_out_of_service = $outOfService
        first_power_off = $powerOff
        power_off_observed = $null -ne $powerOff
        power_off_vs_cellular_loss = $powerOffVsLoss
        power_off_vs_airplane_disable_started = $powerOffVsDisable
        cellular_loss_observed_ms = $cellularLoss
        airplane_disable_started_ms = $disableStarted
        cellular_loss_to_disable_started_ms = $disableStarted - $cellularLoss
        product_mutation_performed = $false
        radio_mutation_performed = $false
        second_rotation_triggered = $false
        architecture_decision = 'NOT_MADE'
    }
}

Export-ModuleMember -Function @(
    'Start-MishTelephonyDetachObservation',
    'Stop-MishTelephonyDetachObservation',
    'New-MishTelephonyDetachResearchProjection'
)
