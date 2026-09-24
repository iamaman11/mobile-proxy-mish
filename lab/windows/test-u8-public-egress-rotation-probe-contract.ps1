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
    'diagnose-u5-rotation.ps1',
    '-SuccessfulOperations 1',
    '-SkipShutdownRestoreAfterOn',
    'rotation_requests = 1',
    'product_terminal_result',
    'external_outcome',
    'observer_consensus',
    'PRODUCT_EXTERNAL_EGRESS_RESULT_MISMATCH',
    'U8_PUBLIC_EGRESS_ROTATION_PASS',
    'raw_ip_persisted = $false',
    'secrets_persisted_in_evidence = $false',
    'MISH_U8_PUBLIC_EGRESS_RAW_IP_PERSISTED=false',
    '$beforeAddress = $null',
    '$afterAddress = $null'
)) {
    if (-not $source.Contains($required)) {
        throw "U8 public-egress rotation probe lost required contract: $required"
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
    'curl.exe',
    'Invoke-WebRequest',
    'Invoke-RestMethod',
    'retry-until-changed',
    'retry_until_changed',
    "'shell', 'su'",
    'airplane-mode enable',
    'airplane-mode disable',
    'settings put',
    'svc data',
    'ProxyPassword =',
    'before_ip =',
    'after_ip =',
    'Write-Host $beforeAddress',
    'Write-Host $afterAddress'
)) {
    if ($source.Contains($forbidden) -or $moduleSource.Contains($forbidden)) {
        throw "U8 public-egress observation path contains forbidden duplicate mutation/secret/raw-IP path: $forbidden"
    }
}
foreach ($forbidden in @(
    'diagnose-u5-rotation.ps1',
    'start_public_ip_rotation',
    'airplane-mode enable',
    'airplane-mode disable'
)) {
    if ($moduleSource.Contains($forbidden)) {
        throw "Shared public-egress observation module must stay read-only: $forbidden"
    }
}

Write-Host 'U8_PUBLIC_EGRESS_ROTATION_PROBE_CONTRACT=PASS'
exit 0
