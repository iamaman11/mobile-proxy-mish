Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-u8-public-egress-rotation.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'U8 public-egress rotation probe must parse under PowerShell.'
}
if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
    throw 'U8 public-egress rotation probe must not shadow the PowerShell automatic PID variable.'
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    'mish.lab.u8-public-egress-rotation/v1',
    'https://checkip.amazonaws.com/',
    '[Net.Http.HttpClientHandler]::new()',
    '[Net.WebProxy]::new("http://127.0.0.1:$ProxyPort")',
    'CredentialProvisioning.psm1',
    'Invoke-MishExternalProxyCredentialProvisioning',
    'Open-MishExternalProxyCredentialLease',
    "'forward', 'tcp:0', 'tcp:3128'",
    "'forward', '--remove'",
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
    if ($source.Contains($forbidden)) {
        throw "U8 public-egress rotation probe contains forbidden duplicate mutation/secret/raw-IP path: $forbidden"
    }
}

Write-Host 'U8_PUBLIC_EGRESS_ROTATION_PROBE_CONTRACT=PASS'
exit 0
