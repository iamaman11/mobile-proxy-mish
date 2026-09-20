Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-u5-rotation.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'U5 rotation acceptance probe must parse under PowerShell.'
}
if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
    throw 'U5 rotation acceptance probe must not shadow the PowerShell automatic PID variable.'
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    "mish.lab.u5-rotation-acceptance/v1",
    'snapshot_v2',
    'DebugRotationActivity',
    'DebugRuntimeStopActivity',
    'DebugRuntimeStartActivity',
    "'shell', 'cmd', 'connectivity', 'airplane-mode'",
    'SuccessfulOperations = 3',
    'request_to_airplane_on_ms',
    'request_to_cellular_loss_ms',
    'loss_to_airplane_off_request_ms',
    'off_to_fresh_owner_ms',
    'off_to_root_policy_authorized_ms',
    'off_to_readiness_ready_ms',
    'off_to_functional_public_ip_ms',
    'total_rotation_ms',
    'PRODUCT_FAIL_CLOSED_VIOLATION',
    'PRODUCT_FRESH_GENERATION_MISSING',
    'PRODUCT_GENERATION_BINDING_MISMATCH',
    'PRODUCT_RAW_IP_PERSISTED',
    'CredentialProvisioning.psm1',
    'Invoke-MishExternalProxyCredentialProvisioning',
    'Open-MishExternalProxyCredentialLease',
    'Test-MishSecureStringEqual',
    'material_unchanged = $credentialMaterialUnchanged',
    'secrets_persisted_in_evidence = $false',
    'raw_ip_persisted = $false',
    'rotation_active_tasks',
    'runtime_generation_stable_across_normal_rotations',
    'root_session_stable_across_normal_rotations',
    'rotation_tasks_quiescent',
    'runtime_io_thread_name_observation_required = $false',
    'runtime_io_threads_stable_across_normal_rotations',
    'restart_resource_quiescence',
    'Wait-MishResourceQuiescence',
    'RequiredConsecutiveSamples = 2',
    'DeadlineSeconds = 15',
    'thread_name_set = @($threadNameSet)',
    "'shell', 'run-as', $PackageName, 'ls', '-1', "/proc/$processId/fd"",
    "'shell', 'dumpsys', 'meminfo', '-s', [string]$processId",
    'rss_kb = [int64]$rssMatch.Groups[''value''].Value',
    'pss_kb = [int64]$pssMatch.Groups[''value''].Value',
    'per_normal_rotation = @($rotationResourceSamples)',
    'delta_from_before = [ordered]@{',
    '[bool]$resourceQuiescence.accepted',
    'forbidden_kotlin_owner_threads_absent',
    'file_descriptors_no_growth_across_normal_rotations',
    'owner_sessions_quiescent_after_normal_rotations',
    'U5_ROTATION_PHYSICAL_ACCEPTANCE_PASS',
    'PRODUCT_RESTORE_OFF_FAILED',
    'PRODUCT_STOP_NOT_QUIESCENT',
    'PRODUCT_RUNTIME_CREDENTIAL_NOT_CLEARED',
    'MISH_U5_RESTORE_PHASE=RUNTIME_STOPPED_CREDENTIAL_CLEARED',
    'MISH_U5_RESTORE_POST_STOP_EVIDENCE_FAILURE=',
    'MISH_U5_RESTORE_PHASE=READY_AFTER_EVIDENCE_FAILURE',
    'postStopEvidenceFailure',
    '$script:StartComponent = "$PackageName/com.mobileproxymish.app.DebugRuntimeStartActivity"',
    'runtime_stopped_observed = $runtimeStopped',
    'runtime_credential_cleared = $runtimeCredentialCleared',
    'MISH_U5_RESTORE_RESTART_STATE=',
    'restart_pid_before = $ExpectedProcessId',
    'restart_pid_after = $restartPid',
    'restart_process_stable = -not $restartPidChanged',
    'restart_recovery_elapsed_ms = $restartElapsedMs',
    'cellular_reconcile_pending=',
    'root_recovery_pending=',
    'rotation_active_tasks=',
    '''shell'', ''ps'', ''-A'', ''-T'', ''-w'', ''-o'', ''PID,TID,CMD''',
    "row = [regex]::Match",
    'Groups[''pid''].Value -eq $processId',
    'Android ps -A -T returned no PRODUCT thread rows.',
    '$_ -like ''mish-runtime-i*''',
    'MISH_U5_TOPOLOGY_THREAD_NAME_SET=',
    'MISH_U5_TOPOLOGY_RUNTIME_IO_THREADS=',
    'MISH_U5_TOPOLOGY_FORBIDDEN_KOTLIN_OWNER_THREADS=',
    'LAB_ADB_TIMEOUT',
    'WaitForExit($script:AdbTransportTimeoutMilliseconds)',
    '$process.Kill($true)',
    'MISH_U5_ROTATION_OPERATION_START=',
    '[AllowEmptyCollection()][System.Collections.Generic.List[object]] $Timeline',
    'MISH_U5_ROTATION_TIMELINE=',
    'MISH_U5_RESTORE_PHASE=',
    'Start-MishFastAirplaneObserver',
    'Stop-MishFastAirplaneObserver',
    'settings get global airplane_mode_on',
    '$startInfo.RedirectStandardInput = $true',
    '[void]$startInfo.ArgumentList.Add(''shell'')',
    '$process.StandardInput.Write($deviceScript)',
    '$process.StandardInput.Close()',
    'OBSERVER_READY',
    '$process.StandardOutput.ReadLineAsync()',
    'observer_exit_code',
    'stderr_empty',
    'sleep 0.05',
    'MISH_U5_FAST_AIRPLANE=',
    "'FAST_OBSERVER_SEPARATE'",
    'Keep this loop single-ADB',
    'STOP_TRIGGER_EXIT=',
    '$restoreTemplate.Replace(''__MAX__'', [string]$maxSamples).Replace(''__STOP__'', $StopComponent)',
    'airplane_fast_observer',
    "Invoke-MishActivityTrigger",
    "'shell', 'am', 'start', '-n'",
    'LAB_ACTIVITY_TRIGGER_FAILED',
    "final_airplane = Get-MishAirplaneState"
)) {
    if (-not $source.Contains($required)) {
        throw "U5 rotation acceptance probe lost required evidence contract: $required"
    }
}

foreach ($forbidden in @(
    'Warning: Activity not started',
    'airplane-mode enable',
    'airplane-mode disable',
    "'shell', 'su'",
    "'shell', 'iptables'",
    "'shell', 'ip6tables'",
    'settings put',
    'svc data',
    "'cmd', 'phone', 'data'",
    'warp-cli',
    'com.cloudflare',
    'sing-box',
    'gradle ',
    'cargo build',
    'assembleDebug',
    'ProxyUserName =',
    'ProxyPassword =',
    'before_ip',
    'after_ip',
    'retry-until-changed',
    'retry_until_changed',
    '$metricsBefore.runtime_io_threads -lt 1',
    '-not $runtimeIoStableAcrossRotations -or',
    '$runtimeIoStable -and',
    'task/*/comm',
    '| wc -l',
    "'shell', 'ps', '-T', '-p'",
    "'-o', 'NAME'",
    '$output = @(& $AdbPath @Arguments',
    "'shell', 'am', 'start', '-W'",
    "@('shell', 'sh', '-c', `$shell)",
    'foreach ($argument in @(''shell'', $shell))',
    'Invoke-MishActivityTrigger -Component $script:StopComponent -Operation ''restore_stop_trigger''',
    'Credential version changed during restore case.',
    '$airplane = Get-MishAirplaneState',
    '$metricsAfter.threads -le ([int]$metricsBefore.threads +',
    '$threadsBounded = $true'
)) {
    if ($source.Contains($forbidden)) {
        throw "U5 rotation acceptance probe contains forbidden duplicate PRODUCT/control/secret path: $forbidden"
    }
}

$rotationStart = $source.IndexOf('$script:RotationComponent', [StringComparison]::Ordinal)
$readOnlyAirplane = $source.IndexOf("'shell', 'cmd', 'connectivity', 'airplane-mode'", [StringComparison]::Ordinal)
$stopTrigger = $source.IndexOf('$script:StopComponent', [StringComparison]::Ordinal)
if ($rotationStart -lt 0 -or $readOnlyAirplane -lt 0 -or $stopTrigger -lt 0) {
    throw 'U5 rotation probe must retain PRODUCT trigger, read-only airplane observation and normal stop trigger.'
}

Write-Host 'U5_ROTATION_PROBE_CONTRACT=PASS'
exit 0
