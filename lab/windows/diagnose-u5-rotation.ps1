[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [ValidateRange(1, 8)][int] $SuccessfulOperations = 3,
    [ValidateRange(30, 180)][int] $OperationDeadlineSeconds = 120,
    [ValidateRange(2, 30)][int] $AdbTransportTimeoutSeconds = 10,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u5-rotation-acceptance-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.u5-rotation-acceptance/v1'
$script:SnapshotMethod = 'snapshot_v2'
$script:PollMilliseconds = 75
$script:AdbTransportTimeoutMilliseconds = $AdbTransportTimeoutSeconds * 1000
$script:RecoveryDeadlineSeconds = 45
$script:RestoreDeadlineSeconds = 20
$script:RotationComponent = "$PackageName/com.mobileproxymish.app.DebugRotationActivity"
$script:StopComponent = "$PackageName/com.mobileproxymish.app.DebugRuntimeStopActivity"
$script:MainComponent = "$PackageName/com.mobileproxymish.app.MainActivity"

function Stop-MishRotationAcceptance {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_U5_ROTATION_FAILURE|$Classification|$Message"
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
            Stop-MishRotationAcceptance 'LAB_ADB_FAILED' "ADB operation '$Operation' did not start."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($script:AdbTransportTimeoutMilliseconds)) {
            try { $process.Kill($true) } catch {}
            try { [void]$process.WaitForExit(2000) } catch {}
            Stop-MishRotationAcceptance 'LAB_ADB_TIMEOUT' "ADB operation '$Operation' exceeded the bounded transport deadline."
        }
        $output = $stdoutTask.GetAwaiter().GetResult()
        [void]$stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
        if ($exitCode -ne 0) {
            Stop-MishRotationAcceptance 'LAB_ADB_FAILED' "ADB operation '$Operation' failed with exit code $exitCode."
        }
        return $output.Trim()
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

    $output = Invoke-MishAdbText -Operation $Operation -Arguments @(
        'shell', 'am', 'start', '-n', $Component
    )
    if (
        $output -match '(?im)^\s*(Error|Exception):' -or
        $output -notmatch '(?im)^\s*(Starting: Intent|Warning: Activity not started)'
    ) {
        Stop-MishRotationAcceptance 'LAB_ACTIVITY_TRIGGER_FAILED' "Android Activity trigger '$Operation' was not accepted."
    }
}

function Get-MishAndroidSnapshot {
    $contentOutput = Invoke-MishAdbText -Operation 'snapshot_v2' -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    )
    $payloadMatch = [regex]::Match($contentOutput, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $payloadMatch.Success) {
        Stop-MishRotationAcceptance 'LAB_SNAPSHOT_INVALID' 'Android diagnostics returned no V2 payload.'
    }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
        $json = [Text.Encoding]::UTF8.GetString($bytes)
        $snapshot = $json | ConvertFrom-Json
    }
    catch {
        Stop-MishRotationAcceptance 'LAB_SNAPSHOT_INVALID' 'Android diagnostics payload is malformed.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if (
        [string]$snapshot.schema -cne 'mish.diagnostics/v2' -or
        [string]$snapshot.application_id -cne $PackageName -or
        -not [bool]$snapshot.consistent
    ) {
        Stop-MishRotationAcceptance 'PRODUCT_ATOMIC_SNAPSHOT_INVALID' 'Atomic PRODUCT snapshot identity/consistency failed.'
    }
    return $snapshot
}

function Get-MishAirplaneState {
    $raw = (Invoke-MishAdbText -Operation 'observe_airplane' -Arguments @('shell', 'cmd', 'connectivity', 'airplane-mode')).Trim().ToLowerInvariant()
    if ($raw -in @('enabled', 'true', '1', 'airplane mode is enabled')) { return 'ENABLED' }
    if ($raw -in @('disabled', 'false', '0', 'airplane mode is disabled')) { return 'DISABLED' }
    return 'UNKNOWN'
}

function Get-MishOptionalInt64 {
    param($Value)
    if ($null -eq $Value) { return $null }
    return [int64]$Value
}

function Assert-MishReadyBaseline {
    param([Parameter(Mandatory)] $Snapshot)
    $owner = Get-MishOptionalInt64 $Snapshot.cellular.owner_sequence
    $rootGeneration = Get-MishOptionalInt64 $Snapshot.root.policy_authorized_generation
    $credentialVersion = Get-MishOptionalInt64 $Snapshot.credential.version
    if (
        -not [bool]$Snapshot.runtime.running -or
        -not [bool]$Snapshot.cellular.admitted -or
        $null -eq $owner -or
        -not [bool]$Snapshot.root.policy_authorized -or
        $rootGeneration -ne $owner -or
        -not [bool]$Snapshot.credential.active -or
        $null -eq $credentialVersion -or
        [string]$Snapshot.readiness.state -cne 'READY' -or
        -not [bool]$Snapshot.mesh.admitted -or
        -not [bool]$Snapshot.mesh.ingress_running
    ) {
        Stop-MishRotationAcceptance 'PRODUCT_BASELINE_NOT_READY' 'Rotation acceptance requires exact READY/root-authorized Cellular owner state.'
    }
    if ([bool]$Snapshot.rotation.raw_ip_persisted) {
        Stop-MishRotationAcceptance 'PRODUCT_RAW_IP_PERSISTED' 'Rotation diagnostics reported raw IP persistence.'
    }
}

function Get-MishProcessMetrics {
    param([Parameter(Mandatory)] $Snapshot)

    $processText = Invoke-MishAdbText -Operation 'observe_pid' -Arguments @('shell', 'pidof', $PackageName)
    if ([string]::IsNullOrWhiteSpace($processText) -or $processText -match '\s') {
        Stop-MishRotationAcceptance 'PRODUCT_PROCESS_IDENTITY_INVALID' 'Exactly one PRODUCT process is required.'
    }
    [int]$processId = $processText

    $status = Invoke-MishAdbText -Operation 'observe_process_status' -Arguments @(
        'shell', 'run-as', $PackageName, 'cat', "/proc/$processId/status"
    )
    $threadsMatch = [regex]::Match($status, '(?m)^Threads:\s+(?<count>\d+)\s*$')
    if (-not $threadsMatch.Success) {
        Stop-MishRotationAcceptance 'LAB_PROCESS_METRICS_UNAVAILABLE' 'PRODUCT thread count is unavailable.'
    }

    $fdText = Invoke-MishAdbText -Operation 'observe_fd_count' -Arguments @(
        'shell', 'run-as', $PackageName, 'sh', '-c', "ls /proc/$processId/fd 2>/dev/null | wc -l"
    )
    if ($fdText -notmatch '^\d+$') {
        Stop-MishRotationAcceptance 'LAB_PROCESS_METRICS_UNAVAILABLE' 'PRODUCT FD count is unavailable.'
    }

    # Toybox CMD is the per-thread command name. Enumerate all visible threads and filter
    # PRODUCT PID locally: DEVICE-1 does not reliably expose all worker rows through ps -T -p.
    $threadText = Invoke-MishAdbText -Operation 'observe_thread_topology' -Arguments @(
        'shell', 'ps', '-A', '-T', '-w', '-o', 'PID,TID,CMD'
    )
    $threadNames = @(
        $threadText -split '\r?\n' |
            ForEach-Object {
                $row = [regex]::Match($_, '^\s*(?<pid>\d+)\s+(?<tid>\d+)\s+(?<name>.+?)\s*$')
                if ($row.Success -and [int]$row.Groups['pid'].Value -eq $processId) {
                    $row.Groups['name'].Value.Trim()
                }
            } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    if ($threadNames.Count -eq 0) {
        Stop-MishRotationAcceptance 'LAB_PROCESS_METRICS_UNAVAILABLE' 'Android ps -A -T returned no PRODUCT thread rows.'
    }
    $runtimeIo = @($threadNames | Where-Object { $_ -ceq 'mish-runtime-io' }).Count
    $forbiddenKotlinOwners = @(
        $threadNames | Where-Object {
            $_ -like 'mish-runtime-lif*' -or
            $_ -like 'mish-runtime-rec*' -or
            $_ -like 'mish-cellular-po*' -or
            $_ -like 'mish-root-author*' -or
            $_ -like 'mish-readiness-*' -or
            $_ -like 'mish-root-shell-*'
        }
    ).Count

    Write-Host "MISH_U5_TOPOLOGY_THREAD_NAMES_OBSERVED=$($threadNames.Count)"
    Write-Host "MISH_U5_TOPOLOGY_RUNTIME_IO_THREADS=$runtimeIo"
    Write-Host "MISH_U5_TOPOLOGY_FORBIDDEN_KOTLIN_OWNER_THREADS=$forbiddenKotlinOwners"

    return [ordered]@{
        pid = $processId
        threads = [int]$threadsMatch.Groups['count'].Value
        fd_count = [int]$fdText
        runtime_io_threads = $runtimeIo
        forbidden_kotlin_owner_threads = $forbiddenKotlinOwners
        root_session_generation = Get-MishOptionalInt64 $Snapshot.root.session_generation
        runtime_generation = [int64]$Snapshot.runtime.generation
        proxy_serving_generation = Get-MishOptionalInt64 $Snapshot.proxy.serving_generation
        proxy_active_sessions = [int64]$Snapshot.proxy.active_sessions
        mesh_serving_generation = Get-MishOptionalInt64 $Snapshot.mesh.serving_generation
        mesh_active_sessions = Get-MishOptionalInt64 $Snapshot.mesh.active_sessions
        rotation_active_tasks = [int64]$Snapshot.rotation.active_tasks
    }
}

function New-MishCredentialLease {
    $tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
    $store = Join-Path $tempRoot ('mish-u5-rotation-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
    Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
    try {
        [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $store)
        return Open-MishExternalProxyCredentialLease -StorePath $store
    }
    finally {
        if (Test-Path -LiteralPath $store -PathType Leaf) {
            Remove-Item -LiteralPath $store -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-MishSecureStringEqual {
    param(
        [Parameter(Mandatory)][Security.SecureString] $Left,
        [Parameter(Mandatory)][Security.SecureString] $Right
    )
    $leftPtr = [IntPtr]::Zero
    $rightPtr = [IntPtr]::Zero
    try {
        $leftPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Left)
        $rightPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Right)
        $leftText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($leftPtr)
        $rightText = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($rightPtr)
        return $leftText -ceq $rightText
    }
    finally {
        if ($leftPtr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($leftPtr)
        }
        if ($rightPtr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($rightPtr)
        }
        $leftText = $null
        $rightText = $null
    }
}

function Add-MishTimelineSample {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]] $Timeline,
        [Parameter(Mandatory)][int64] $ElapsedMs,
        [Parameter(Mandatory)][string] $Airplane,
        [Parameter(Mandatory)] $Snapshot,
        [Parameter(Mandatory)][ref] $LastKey
    )

    $owner = Get-MishOptionalInt64 $Snapshot.cellular.owner_sequence
    $rootGeneration = Get-MishOptionalInt64 $Snapshot.root.policy_authorized_generation
    $operationId = Get-MishOptionalInt64 $Snapshot.rotation.operation_id
    $afterGeneration = Get-MishOptionalInt64 $Snapshot.rotation.after_generation
    $key = @(
        $Airplane,
        [string]$Snapshot.rotation.state,
        $operationId,
        $owner,
        [bool]$Snapshot.cellular.admitted,
        [bool]$Snapshot.root.policy_authorized,
        $rootGeneration,
        [string]$Snapshot.readiness.state,
        [bool]$Snapshot.mesh.ingress_running,
        $afterGeneration
    ) -join '|'
    if ($key -ceq [string]$LastKey.Value) { return }
    $LastKey.Value = $key
    Write-Host ("MISH_U5_ROTATION_TIMELINE=elapsed_ms={0};airplane={1};state={2};operation_id={3};owner={4};cellular={5};root={6};readiness={7};mesh={8};after_generation={9}" -f @(
        $ElapsedMs,
        $Airplane,
        [string]$Snapshot.rotation.state,
        $operationId,
        $owner,
        [bool]$Snapshot.cellular.admitted,
        [bool]$Snapshot.root.policy_authorized,
        [string]$Snapshot.readiness.state,
        [bool]$Snapshot.mesh.ingress_running,
        $afterGeneration
    ))
    $Timeline.Add([pscustomobject][ordered]@{
        elapsed_ms = $ElapsedMs
        airplane = $Airplane
        operation_id = $operationId
        rotation_state = [string]$Snapshot.rotation.state
        cellular_owner_generation = $owner
        cellular_admitted = [bool]$Snapshot.cellular.admitted
        root_policy_authorized = [bool]$Snapshot.root.policy_authorized
        root_policy_authorized_generation = $rootGeneration
        readiness = [string]$Snapshot.readiness.state
        mesh_ingress_running = [bool]$Snapshot.mesh.ingress_running
        after_generation = $afterGeneration
    })
}

function Invoke-MishOneRotation {
    param(
        [Parameter(Mandatory)][int] $Ordinal,
        [Parameter(Mandatory)][int64] $ExpectedCredentialVersion
    )

    Write-Host "MISH_U5_ROTATION_OPERATION_START=$Ordinal"
    $before = Get-MishAndroidSnapshot
    Assert-MishReadyBaseline -Snapshot $before
    $generationA = Get-MishOptionalInt64 $before.cellular.owner_sequence
    if ($null -eq $generationA) {
        Stop-MishRotationAcceptance 'PRODUCT_CELLULAR_GENERATION_MISSING' 'Rotation baseline has no Cellular generation A.'
    }
    if ([int64]$before.credential.version -ne $ExpectedCredentialVersion) {
        Stop-MishRotationAcceptance 'PRODUCT_CREDENTIAL_CHANGED' 'Credential version changed before rotation.'
    }

    $startTicks = [Environment]::TickCount64
    Write-Host "MISH_U5_ROTATION_OPERATION_PHASE=$($Ordinal):TRIGGER_START"
    Invoke-MishActivityTrigger -Component $script:RotationComponent -Operation "rotation_$($Ordinal)_trigger"
    Write-Host "MISH_U5_ROTATION_OPERATION_PHASE=$($Ordinal):TRIGGERED"

    $deadlineTicks = $startTicks + ([int64]$OperationDeadlineSeconds * 1000)
    $timeline = [System.Collections.Generic.List[object]]::new()
    $lastKey = ''
    $operationId = $null
    $airplaneOnMs = $null
    $cellularLossMs = $null
    $offRequestMs = $null
    $airplaneOffMs = $null
    $freshOwnerMs = $null
    $rootAuthorizedMs = $null
    $readinessReadyMs = $null
    $functionalPublicIpMs = $null
    $generationB = $null
    $failClosedViolation = $false
    $sawAirplaneOn = $false
    $terminalSnapshot = $null

    while ([Environment]::TickCount64 -lt $deadlineTicks) {
        $snapshot = Get-MishAndroidSnapshot
        $airplane = Get-MishAirplaneState
        $elapsed = [Environment]::TickCount64 - $startTicks
        Add-MishTimelineSample -Timeline $timeline -ElapsedMs $elapsed -Airplane $airplane -Snapshot $snapshot -LastKey ([ref]$lastKey)

        if ([bool]$snapshot.rotation.raw_ip_persisted) {
            Stop-MishRotationAcceptance 'PRODUCT_RAW_IP_PERSISTED' 'Raw IP persistence became true during rotation.'
        }
        if ([int64]$snapshot.credential.version -ne $ExpectedCredentialVersion) {
            Stop-MishRotationAcceptance 'PRODUCT_CREDENTIAL_CHANGED' 'Credential version changed during rotation.'
        }

        $currentOperation = Get-MishOptionalInt64 $snapshot.rotation.operation_id
        if ($null -ne $currentOperation) {
            if ($null -eq $operationId) { $operationId = $currentOperation }
            elseif ($currentOperation -ne $operationId) {
                Stop-MishRotationAcceptance 'PRODUCT_OPERATION_ID_CHANGED' 'Rotation operation id changed during one bounded request.'
            }
        }

        if ($airplane -ceq 'ENABLED') {
            $sawAirplaneOn = $true
            if ($null -eq $airplaneOnMs) { $airplaneOnMs = $elapsed }
        }
        if ($sawAirplaneOn -and -not [bool]$snapshot.cellular.admitted) {
            if ($null -eq $cellularLossMs) { $cellularLossMs = $elapsed }
            if ([string]$snapshot.readiness.state -ceq 'READY' -or [bool]$snapshot.mesh.ingress_running) {
                $failClosedViolation = $true
            }
        }

        $rotationState = [string]$snapshot.rotation.state
        if (
            $null -ne $cellularLossMs -and
            $null -eq $offRequestMs -and
            $rotationState -in @(
                'AIRPLANE_DISABLING',
                'WAITING_CELLULAR_RECOVERY',
                'WAITING_ROOT_POLICY',
                'PROBING_PUBLIC_IP',
                'CHANGED',
                'UNCHANGED'
            )
        ) {
            $offRequestMs = $elapsed
        }
        if ($sawAirplaneOn -and $airplane -ceq 'DISABLED' -and $null -eq $airplaneOffMs) {
            $airplaneOffMs = $elapsed
        }

        $owner = Get-MishOptionalInt64 $snapshot.cellular.owner_sequence
        if (
            $null -ne $owner -and
            $owner -gt $generationA -and
            [bool]$snapshot.cellular.admitted
        ) {
            if ($null -eq $generationB) { $generationB = $owner }
            if ($owner -eq $generationB -and $null -eq $freshOwnerMs) { $freshOwnerMs = $elapsed }
        }

        $rootGeneration = Get-MishOptionalInt64 $snapshot.root.policy_authorized_generation
        if (
            $null -ne $generationB -and
            [bool]$snapshot.root.policy_authorized -and
            $rootGeneration -eq $generationB -and
            $null -eq $rootAuthorizedMs
        ) {
            $rootAuthorizedMs = $elapsed
        }

        if ($rotationState -in @('CHANGED', 'UNCHANGED', 'FAILED')) {
            $terminalSnapshot = $snapshot
            $functionalPublicIpMs = $elapsed
            break
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }

    if ($null -eq $terminalSnapshot) {
        Stop-MishRotationAcceptance 'PRODUCT_ROTATION_DEADLINE' 'Rotation did not reach a terminal state within the bounded acceptance deadline.'
    }
    if ([string]$terminalSnapshot.rotation.state -eq 'FAILED') {
        Stop-MishRotationAcceptance 'PRODUCT_ROTATION_FAILED' ("Rotation failed: " + [string]$terminalSnapshot.rotation.failure)
    }
    if ([string]$terminalSnapshot.rotation.terminal_result -notin @('CHANGED', 'UNCHANGED')) {
        Stop-MishRotationAcceptance 'PRODUCT_ROTATION_TERMINAL_INVALID' 'Rotation terminal result is not CHANGED/UNCHANGED.'
    }

    $afterGeneration = Get-MishOptionalInt64 $terminalSnapshot.rotation.after_generation
    if ($null -eq $afterGeneration -or $afterGeneration -le $generationA) {
        Stop-MishRotationAcceptance 'PRODUCT_FRESH_GENERATION_MISSING' 'Terminal rotation has no fresh generation B > A.'
    }
    if ($null -eq $generationB) { $generationB = $afterGeneration }
    if ($afterGeneration -ne $generationB) {
        Stop-MishRotationAcceptance 'PRODUCT_GENERATION_BINDING_MISMATCH' 'After-IP terminal generation does not equal observed fresh owner B.'
    }
    if ($failClosedViolation) {
        Stop-MishRotationAcceptance 'PRODUCT_FAIL_CLOSED_VIOLATION' 'Readiness or Mesh ingress remained serving after accepted Cellular loss.'
    }
    foreach ($required in @($airplaneOnMs, $cellularLossMs, $offRequestMs, $airplaneOffMs, $freshOwnerMs, $rootAuthorizedMs)) {
        if ($null -eq $required) {
            Stop-MishRotationAcceptance 'PRODUCT_ROTATION_FACT_MISSING' 'One or more required physical rotation facts were not observed.'
        }
    }

    $recoveryDeadline = [Environment]::TickCount64 + ([int64]$script:RecoveryDeadlineSeconds * 1000)
    $final = $terminalSnapshot
    while ([Environment]::TickCount64 -lt $recoveryDeadline) {
        $final = Get-MishAndroidSnapshot
        $elapsed = [Environment]::TickCount64 - $startTicks
        if (
            [string]$final.readiness.state -ceq 'READY' -and
            [bool]$final.mesh.ingress_running -and
            [bool]$final.root.policy_authorized -and
            (Get-MishOptionalInt64 $final.root.policy_authorized_generation) -eq $generationB -and
            [int64]$final.rotation.active_tasks -eq 0
        ) {
            if ($null -eq $readinessReadyMs) { $readinessReadyMs = $elapsed }
            break
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }
    if ($null -eq $readinessReadyMs) {
        Stop-MishRotationAcceptance 'PRODUCT_RECOVERY_NOT_READY' 'Readiness/Mesh did not naturally recover after generation B.'
    }
    Write-Host "MISH_U5_ROTATION_OPERATION_PHASE=$($Ordinal):RECOVERED"
    if ((Get-MishAirplaneState) -cne 'DISABLED') {
        Stop-MishRotationAcceptance 'PRODUCT_AIRPLANE_FINAL_ON' 'Normal rotation did not finish with airplane OFF.'
    }

    return [pscustomobject][ordered]@{
        ordinal = $Ordinal
        operation_id = $operationId
        generation_a = $generationA
        generation_b = $generationB
        terminal_result = [string]$terminalSnapshot.rotation.terminal_result
        raw_ip_persisted = [bool]$terminalSnapshot.rotation.raw_ip_persisted
        fail_closed_during_loss = -not $failClosedViolation
        timings = [ordered]@{
            request_to_airplane_on_ms = $airplaneOnMs
            request_to_cellular_loss_ms = $cellularLossMs
            loss_to_airplane_off_request_ms = $offRequestMs - $cellularLossMs
            off_to_fresh_owner_ms = $freshOwnerMs - $airplaneOffMs
            off_to_root_policy_authorized_ms = $rootAuthorizedMs - $airplaneOffMs
            off_to_readiness_ready_ms = $readinessReadyMs - $airplaneOffMs
            off_to_functional_public_ip_ms = $functionalPublicIpMs - $airplaneOffMs
            total_rotation_ms = $functionalPublicIpMs
        }
        timeline = @($timeline)
    }
}

function Invoke-MishShutdownRestoreAfterOn {
    param([Parameter(Mandatory)][int64] $ExpectedCredentialVersion)

    $before = Get-MishAndroidSnapshot
    Assert-MishReadyBaseline -Snapshot $before
    if ([int64]$before.credential.version -ne $ExpectedCredentialVersion) {
        Stop-MishRotationAcceptance 'PRODUCT_CREDENTIAL_CHANGED' 'Credential version changed before restore case.'
    }

    $startTicks = [Environment]::TickCount64
    Write-Host 'MISH_U5_RESTORE_PHASE=TRIGGER_START'
    Invoke-MishActivityTrigger -Component $script:RotationComponent -Operation 'restore_rotation_trigger'
    $deadline = $startTicks + ([int64]$OperationDeadlineSeconds * 1000)
    $observedOnMs = $null
    while ([Environment]::TickCount64 -lt $deadline) {
        $airplane = Get-MishAirplaneState
        $snapshot = Get-MishAndroidSnapshot
        if ([int64]$snapshot.credential.version -ne $ExpectedCredentialVersion) {
            Stop-MishRotationAcceptance 'PRODUCT_CREDENTIAL_CHANGED' 'Credential version changed during restore case.'
        }
        if ($airplane -ceq 'ENABLED') {
            $observedOnMs = [Environment]::TickCount64 - $startTicks
            break
        }
        if ([string]$snapshot.rotation.state -eq 'FAILED') {
            Stop-MishRotationAcceptance 'PRODUCT_RESTORE_CASE_EARLY_FAILURE' 'Restore case failed before airplane ON was physically observed.'
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }
    if ($null -eq $observedOnMs) {
        Stop-MishRotationAcceptance 'PRODUCT_AIRPLANE_ON_UNOBSERVED' 'Restore case never physically observed airplane ON.'
    }
    Write-Host 'MISH_U5_RESTORE_PHASE=AIRPLANE_ON_OBSERVED'

    Write-Host 'MISH_U5_RESTORE_PHASE=STOP_START'
    Invoke-MishActivityTrigger -Component $script:StopComponent -Operation 'restore_stop_trigger'
    $restoreDeadline = [Environment]::TickCount64 + ([int64]$script:RestoreDeadlineSeconds * 1000)
    $offMs = $null
    while ([Environment]::TickCount64 -lt $restoreDeadline) {
        if ((Get-MishAirplaneState) -ceq 'DISABLED') {
            $offMs = [Environment]::TickCount64 - $startTicks
            break
        }
        Start-Sleep -Milliseconds $script:PollMilliseconds
    }
    if ($null -eq $offMs) {
        Stop-MishRotationAcceptance 'PRODUCT_RESTORE_OFF_FAILED' 'Normal PRODUCT stop did not restore airplane OFF after observed ON.'
    }
    Write-Host 'MISH_U5_RESTORE_PHASE=AIRPLANE_OFF_OBSERVED'

    Write-Host 'MISH_U5_RESTORE_PHASE=RESTART_START'
    Invoke-MishActivityTrigger -Component $script:MainComponent -Operation 'restore_restart_trigger'
    $readyDeadline = [Environment]::TickCount64 + ([int64]$script:RecoveryDeadlineSeconds * 1000)
    $ready = $null
    while ([Environment]::TickCount64 -lt $readyDeadline) {
        $ready = Get-MishAndroidSnapshot
        if (
            [bool]$ready.runtime.running -and
            [bool]$ready.cellular.admitted -and
            [bool]$ready.root.policy_authorized -and
            [string]$ready.readiness.state -ceq 'READY' -and
            [bool]$ready.mesh.ingress_running
        ) { break }
        Start-Sleep -Milliseconds 150
    }
    Assert-MishReadyBaseline -Snapshot $ready
    Write-Host 'MISH_U5_RESTORE_PHASE=READY'

    return [pscustomobject][ordered]@{
        airplane_on_observed = $true
        request_to_airplane_on_ms = $observedOnMs
        stop_requested_after_on = $true
        restore_off_observed = $true
        on_to_restore_off_ms = $offMs - $observedOnMs
        runtime_restarted_ready = $true
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishRotationAcceptance 'LAB_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

$initial = Get-MishAndroidSnapshot
Assert-MishReadyBaseline -Snapshot $initial
if ((Get-MishAirplaneState) -cne 'DISABLED') {
    Stop-MishRotationAcceptance 'PRODUCT_AIRPLANE_BASELINE_ON' 'Acceptance baseline requires airplane OFF.'
}

$credentialBefore = New-MishCredentialLease
$credentialVersion = [int64]$initial.credential.version
if ([int64]$credentialBefore.CredentialVersion -ne $credentialVersion) {
    Stop-MishRotationAcceptance 'PRODUCT_CREDENTIAL_VERSION_MISMATCH' 'Provisioned credential version does not match native owner diagnostics.'
}
$metricsBefore = Get-MishProcessMetrics -Snapshot $initial
if ($metricsBefore.forbidden_kotlin_owner_threads -ne 0) {
    Stop-MishRotationAcceptance 'PRODUCT_EXECUTION_TOPOLOGY_INVALID' 'Removed Kotlin PRODUCT owner threads are still observable.'
}

$operations = [System.Collections.Generic.List[object]]::new()
for ($ordinal = 1; $ordinal -le $SuccessfulOperations; $ordinal++) {
    $operations.Add((Invoke-MishOneRotation -Ordinal $ordinal -ExpectedCredentialVersion $credentialVersion))
}

$postRotationSnapshot = Get-MishAndroidSnapshot
Assert-MishReadyBaseline -Snapshot $postRotationSnapshot
$metricsAfterRotations = Get-MishProcessMetrics -Snapshot $postRotationSnapshot
$runtimeGenerationStableAcrossRotations = (
    [int64]$metricsAfterRotations.runtime_generation -eq [int64]$metricsBefore.runtime_generation
)
$rootSessionStableAcrossRotations = (
    $null -ne $metricsBefore.root_session_generation -and
    $null -ne $metricsAfterRotations.root_session_generation -and
    [int64]$metricsAfterRotations.root_session_generation -eq [int64]$metricsBefore.root_session_generation
)
$rotationTasksQuiescent = (
    [int64]$metricsBefore.rotation_active_tasks -eq 0 -and
    [int64]$metricsAfterRotations.rotation_active_tasks -eq 0
)
$runtimeIoStableAcrossRotations = (
    [int]$metricsAfterRotations.runtime_io_threads -eq [int]$metricsBefore.runtime_io_threads
)
$threadsNoGrowthAcrossRotations = (
    [int]$metricsAfterRotations.threads -le [int]$metricsBefore.threads
)
$fdsNoGrowthAcrossRotations = (
    [int]$metricsAfterRotations.fd_count -le [int]$metricsBefore.fd_count
)
$ownerSessionsQuiescentAfterRotations = (
    [int64]$metricsAfterRotations.proxy_active_sessions -eq 0 -and
    ($null -eq $metricsAfterRotations.mesh_active_sessions -or [int64]$metricsAfterRotations.mesh_active_sessions -eq 0)
)
if (
    -not $runtimeGenerationStableAcrossRotations -or
    -not $rootSessionStableAcrossRotations -or
    -not $rotationTasksQuiescent -or
    -not $threadsNoGrowthAcrossRotations -or
    -not $fdsNoGrowthAcrossRotations -or
    -not $ownerSessionsQuiescentAfterRotations
) {
    Stop-MishRotationAcceptance 'PRODUCT_ROTATION_RESOURCE_REGRESSION' 'Repeated normal rotations changed runtime/root-session ownership or leaked tasks/resources.'
}

$restoreCase = Invoke-MishShutdownRestoreAfterOn -ExpectedCredentialVersion $credentialVersion
$final = Get-MishAndroidSnapshot
Assert-MishReadyBaseline -Snapshot $final
$metricsAfter = Get-MishProcessMetrics -Snapshot $final
$credentialAfter = New-MishCredentialLease

$credentialMaterialUnchanged = (
    [string]$credentialBefore.CredentialVersion -ceq [string]$credentialAfter.CredentialVersion -and
    [string]$credentialBefore.CredentialId -ceq [string]$credentialAfter.CredentialId -and
    [string]$credentialBefore.ProxyUserName -ceq [string]$credentialAfter.ProxyUserName -and
    (Test-MishSecureStringEqual -Left $credentialBefore.ProxyPassword -Right $credentialAfter.ProxyPassword)
)
if (-not $credentialMaterialUnchanged) {
    Stop-MishRotationAcceptance 'PRODUCT_CREDENTIAL_CHANGED' 'Credential version or material changed across ordinary IP rotations.'
}

$pidStable = [int]$metricsBefore.pid -eq [int]$metricsAfter.pid
$runtimeIoStable = [int]$metricsAfter.runtime_io_threads -eq [int]$metricsBefore.runtime_io_threads
$forbiddenKotlinOwnersAbsent = [int]$metricsAfter.forbidden_kotlin_owner_threads -eq 0
$threadsBounded = [int]$metricsAfter.threads -le [int]$metricsBefore.threads
$fdsBounded = [int]$metricsAfter.fd_count -le [int]$metricsBefore.fd_count
$sessionsQuiescent = (
    [int64]$metricsAfter.proxy_active_sessions -eq 0 -and
    ($null -eq $metricsAfter.mesh_active_sessions -or [int64]$metricsAfter.mesh_active_sessions -eq 0)
)

$acceptance = (
    $credentialMaterialUnchanged -and
    $runtimeGenerationStableAcrossRotations -and
    $rootSessionStableAcrossRotations -and
    $rotationTasksQuiescent -and
    $threadsNoGrowthAcrossRotations -and
    $fdsNoGrowthAcrossRotations -and
    $ownerSessionsQuiescentAfterRotations -and
    $forbiddenKotlinOwnersAbsent -and
    $threadsBounded -and
    $fdsBounded -and
    $sessionsQuiescent -and
    (Get-MishAirplaneState) -ceq 'DISABLED'
)
$classification = if ($acceptance) { 'U5_ROTATION_PHYSICAL_ACCEPTANCE_PASS' } else { 'U5_ROTATION_RESOURCE_REGRESSION' }

$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = if ($acceptance) { 'PASS' } else { 'FAIL' }
    classification = $classification
    successful_operations = @($operations)
    shutdown_restore_after_on = $restoreCase
    credential = [ordered]@{
        version = $credentialVersion
        version_unchanged = [string]$credentialBefore.CredentialVersion -ceq [string]$credentialAfter.CredentialVersion
        material_unchanged = $credentialMaterialUnchanged
        secrets_persisted_in_evidence = $false
    }
    raw_ip_persisted = $false
    resources = [ordered]@{
        before = $metricsBefore
        after_normal_rotations = $metricsAfterRotations
        after_restore_restart = $metricsAfter
        pid_stable = $pidStable
        runtime_generation_stable_across_normal_rotations = $runtimeGenerationStableAcrossRotations
        root_session_stable_across_normal_rotations = $rootSessionStableAcrossRotations
        rotation_tasks_quiescent = $rotationTasksQuiescent
        runtime_io_thread_name_observation_required = $false
        runtime_io_threads_stable_across_normal_rotations = $runtimeIoStableAcrossRotations
        total_threads_no_growth_across_normal_rotations = $threadsNoGrowthAcrossRotations
        file_descriptors_no_growth_across_normal_rotations = $fdsNoGrowthAcrossRotations
        owner_sessions_quiescent_after_normal_rotations = $ownerSessionsQuiescentAfterRotations
        runtime_io_threads_stable = $runtimeIoStable
        forbidden_kotlin_owner_threads_absent = $forbiddenKotlinOwnersAbsent
        total_threads_no_growth = $threadsBounded
        file_descriptors_no_growth = $fdsBounded
        owner_sessions_quiescent = $sessionsQuiescent
    }
    final_airplane = Get-MishAirplaneState
}

$fullPath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullPath,
    (($evidence | ConvertTo-Json -Depth 18) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_U5_ROTATION_ACCEPTANCE=$([string]$evidence.acceptance_result)"
Write-Host "MISH_U5_ROTATION_CLASSIFICATION=$classification"
Write-Host "MISH_U5_ROTATION_OPERATIONS=$SuccessfulOperations"
Write-Host "MISH_U5_ROTATION_CREDENTIAL_STABLE=$credentialMaterialUnchanged"
Write-Host "MISH_U5_ROTATION_RAW_IP_PERSISTED=false"
Write-Host "MISH_U5_ROTATION_FINAL_AIRPLANE=$([string]$evidence.final_airplane)"
Write-Host "MISH_U5_ROTATION_EVIDENCE=$fullPath"

if (-not $acceptance) {
    Stop-MishRotationAcceptance $classification 'Physical U5 rotation/resource acceptance did not satisfy all invariants.'
}
