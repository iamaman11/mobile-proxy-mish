$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$probePath = Join-Path $PSScriptRoot 'diagnose-u8-remote-control.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $probePath), [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'U8 remote-control probe PowerShell syntax is invalid.'
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    "mish.lab.u8-remote-control/v1",
    "com.mobileproxymish.app.action.READ_CONTROL_IDENTITY_V1",
    "ControlIdentityProvisioningReceiver",
    "https://`$ControlHost`$Path",
    "public_key_spki_b64 = `$publicSpki",
    "wrong_manager_auth_status = 401",
    "wrong_manager_auth_zero_rotation_mutation = `$true",
    "logical_rotation_requests = 1",
    "duplicate_same_request_replays = 1",
    "Expected one HTTP 202 dispatch",
    "DEVICE_OFFLINE is an acceptance failure, never a retry loop",
    "@('CHANGED', 'UNCHANGED')",
    "REMOTE_OPERATION_ID_CHANGED",
    "REMOTE_IDEMPOTENCY_FAILED",
    "PRODUCT_OPERATION_ID_MISMATCH",
    "POST_ROTATION_PROXY_E2E_FAILED",
    "U8_REMOTE_CONTROL_ROTATION_PASS",
    "manager_token_persisted = `$false",
    "public_spki_persisted = `$false",
    "raw_public_ip_persisted = `$false",
    "secrets_persisted_in_evidence = `$false",
    "MISH_U8_REMOTE_CONTROL_LOGICAL_ROTATION_REQUESTS=1",
    "MISH_U8_REMOTE_CONTROL_IDEMPOTENT_REPLAY=PASS"
)) {
    if (-not $source.Contains($required)) { throw "U8 remote-control probe contract drifted: $required" }
}

foreach ($forbidden in @(
    "DebugRotationActivity",
    "airplane-mode",
    "'shell', 'su'",
    "'cmd', 'phone', 'data'",
    "retry-until",
    "retry_until",
    "before_ip",
    "after_ip",
    "Write-Host `$publicSpki",
    "Write-Host `$deviceId",
    "Write-Host `$env:MISH_MANAGER_TOKEN",
    "manager_token =",
    "public_key_spki_b64 = `$publicSpki`n"
)) {
    if ($source.Contains($forbidden)) { throw "U8 remote-control probe contains forbidden second-owner/secret path: $forbidden" }
}

$validDispatchPattern = [regex]::Escape('$dispatch = Invoke-MishManagerRequest -Method POST -Path "/v1/devices/$deviceId/rotate"')
if (([regex]::Matches($source, $validDispatchPattern)).Count -ne 1) {
    throw 'U8 remote-control acceptance must contain exactly one first-time valid remote dispatch.'
}
if (([regex]::Matches($source, [regex]::Escape('$duplicate = Invoke-MishManagerRequest -Method POST -Path "/v1/devices/$deviceId/rotate"'))).Count -ne 1) {
    throw 'U8 remote-control acceptance must replay the same request exactly once for idempotency.'
}

Write-Host 'U8_REMOTE_CONTROL_PROBE_CONTRACT=PASS'
exit 0
