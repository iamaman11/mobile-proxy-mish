Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-u8-public-egress-rotation.ps1'
$modulePath = Join-Path $PSScriptRoot 'PublicEgressObservation.psm1'
foreach ($parsePath in @($probePath, $modulePath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($parsePath, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        $errors | ForEach-Object { Write-Error $_.Message }
        throw "U8 public-egress observation source must parse under PowerShell: $parsePath"
    }
    if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
        throw "U8 public-egress observation source must not shadow the PowerShell automatic PID variable: $parsePath"
    }
}

$source = Get-Content -Raw -LiteralPath $probePath
$moduleSource = Get-Content -Raw -LiteralPath $modulePath

foreach ($required in @(
    'mish.lab.u8-public-egress-rotation/v1',
    'PublicEgressObservation.psm1',
    'New-MishPublicEgressObservationContext',
    'Invoke-MishExternalPublicIpObservation',
    'Close-MishPublicEgressObservationContext',
    'DebugRotationActivity',
    "'--method', `$script:SnapshotMethod",
    "'--method', `$script:ControlSnapshotMethod",
    'rotation_requests = 1',
    'product_terminal_result',
    'external_outcome',
    'observer_consensus',
    "if (`$terminal -cne 'CHANGED' -or `$externalOutcome -cne 'CHANGED')",
    'PRODUCT_IP_NOT_CHANGED',
    'mobile_data_precondition_enabled',
    'data_disable_started_ms',
    'data_disable_effect_completed_ms',
    'cellular_loss_observed_ms',
    'data_enable_started_ms',
    'data_enable_effect_completed_ms',
    'fresh_cellular_generation',
    'root_authorized_generation',
    'U8_PUBLIC_EGRESS_ROTATION_PASS',
    'raw_ip_persisted = $false',
    'secrets_persisted_in_evidence = $false',
    'MISH_U8_PUBLIC_EGRESS_RAW_IP_PERSISTED=false',
    '$beforeAddress = $null',
    '$afterAddress = $null'
)) {
    if (-not $source.Contains($required)) {
        throw "U8 public-egress rotation probe lost required Candidate A contract: $required"
    }
}

foreach ($required in @(
    'https://checkip.amazonaws.com/',
    '[Net.Http.HttpClientHandler]::new()',
    '[Net.WebProxy]::new("http://127.0.0.1:$([int]$Context.ProxyPort)")',
    'CredentialProvisioning.psm1',
    'Invoke-MishExternalProxyCredentialProvisioning',
    'Open-MishExternalProxyCredentialLease',
    "'forward', 'tcp:0', 'tcp:3128'",
    "'forward', '--remove'",
    'New-MishPublicEgressObservationContext',
    'Invoke-MishExternalPublicIpObservation',
    'Close-MishPublicEgressObservationContext'
)) {
    if (-not $moduleSource.Contains($required)) {
        throw "Shared public-egress observation module lost required contract: $required"
    }
}

foreach ($forbidden in @(
    'diagnose-u5-rotation.ps1',
    'request_to_airplane_on_ms',
    'off_to_fresh_owner_ms',
    'airplane_fast_observer',
    'retry-until-changed',
    'retry_until_changed',
    "'shell', 'su'",
    'airplane-mode enable',
    'airplane-mode disable',
    'cmd phone data disable',
    'cmd phone data enable',
    'settings put',
    'svc data',
    'ProxyPassword =',
    'before_ip =',
    'after_ip =',
    'Write-Host $beforeAddress',
    'Write-Host $afterAddress'
)) {
    if ($source.Contains($forbidden) -or $moduleSource.Contains($forbidden)) {
        throw "U8 public-egress Candidate A path contains forbidden duplicate/stale mutation or secret/raw-IP path: $forbidden"
    }
}

foreach ($forbidden in @(
    'DebugRotationActivity',
    'start_public_ip_rotation',
    'diagnose-u5-rotation.ps1',
    'airplane-mode enable',
    'airplane-mode disable',
    'cmd phone data disable',
    'cmd phone data enable'
)) {
    if ($moduleSource.Contains($forbidden)) {
        throw "Shared public-egress observation module must stay read-only: $forbidden"
    }
}

if (($source | Select-String -SimpleMatch "'shell', 'am', 'start', '-n', `$script:RotationComponent" -AllMatches).Matches.Count -ne 1) {
    throw 'U8 public-egress acceptance must contain exactly one local PRODUCT rotation trigger.'
}
if ($source.Contains('Start-Sleep -Seconds')) {
    throw 'U8 public-egress Candidate A acceptance must not add arbitrary dwell.'
}

Write-Host 'U8_PUBLIC_EGRESS_ROTATION_PROBE_CONTRACT=PASS'
exit 0
