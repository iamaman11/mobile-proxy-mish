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
    'runtime_io_threads_stable_across_normal_rotations',
    'forbidden_kotlin_owner_threads_absent',
    'file_descriptors_no_growth_across_normal_rotations',
    'owner_sessions_quiescent_after_normal_rotations',
    'U5_ROTATION_PHYSICAL_ACCEPTANCE_PASS',
    'PRODUCT_RESTORE_OFF_FAILED',
    "'shell', 'ps', '-T', '-p'",
    'Android ps -T returned no PRODUCT thread names.',
    "final_airplane = Get-MishAirplaneState"
)) {
    if (-not $source.Contains($required)) {
        throw "U5 rotation acceptance probe lost required evidence contract: $required"
    }
}

foreach ($forbidden in @(
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
    'task/*/comm'
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
