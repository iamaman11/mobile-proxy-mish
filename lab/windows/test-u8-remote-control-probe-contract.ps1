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
    "-Path '/v1/rotate'",
    "mish.control.rotate/v1",
    "wrong_manager_auth_status = 401",
    "wrong_manager_auth_zero_rotation_mutation = `$true",
    "authenticated_invalid_request_status = 400",
    "authenticated_invalid_request_zero_rotation_mutation = `$true",
    "INVALID_AUTHENTICATED_REQUEST_NOT_REJECTED",
    "INVALID_AUTHENTICATED_REQUEST_MUTATED_ROTATION",
    "MISH_U8_REMOTE_CONTROL_INVALID_AUTHENTICATED_REQUEST=400_ZERO_MUTATION",
    "manager_api_schema = 'mish.control.rotate/v1'",
    "public_rotate_path = '/v1/rotate'",
    "public_rotate_body = 'EMPTY'",
    "server_generated_request_id = `$true",
    "single_http_command = `$true",
    "logical_rotation_requests = 1",
    "operation_polls = 0",
    "client_request_id_generated = `$false",
    "client_device_id_required_for_rotation = `$false",
    "hosted_idempotency_contract = `$true",
    "@('CHANGED', 'UNCHANGED')",
    "REMOTE_REQUEST_ID_INVALID",
    "REMOTE_OPERATION_ID_INVALID",
    "PRODUCT_OPERATION_ID_MISMATCH",
    "POST_ROTATION_PROXY_E2E_FAILED",
    "U8_REMOTE_CONTROL_ROTATION_PASS",
    "manager_token_persisted = `$false",
    "public_spki_persisted = `$false",
    "raw_public_ip_persisted = `$false",
    "secrets_persisted_in_evidence = `$false",
    "MISH_U8_REMOTE_CONTROL_PUBLIC_COMMANDS=1",
    "MISH_U8_REMOTE_CONTROL_SERVER_REQUEST_ID=PASS",
    "MISH_U8_REMOTE_CONTROL_MANAGER_POLLING=0"
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
    "public_key_spki_b64 = `$publicSpki`n",
    "/v1/devices/`$deviceId/rotate",
    "/operations/",
    "duplicate_same_request_replays",
    "REMOTE_IDEMPOTENCY_FAILED",
    "MISH_U8_REMOTE_CONTROL_IDEMPOTENT_REPLAY",
    '$requestId = "u8e_'
)) {
    if ($source.Contains($forbidden)) { throw "U8 remote-control probe contains forbidden second-owner/secret path: $forbidden" }
}

$validCommandLiteral = '$remote = Invoke-MishManagerRequest -Method POST -Path ''/v1/rotate'' -BearerToken $env:MISH_MANAGER_TOKEN -Body $null'
$validCommandPattern = [regex]::Escape($validCommandLiteral)
if (([regex]::Matches($source, $validCommandPattern)).Count -ne 1) {
    throw 'U8 remote-control acceptance must contain exactly one valid public POST /v1/rotate command.'
}
if (([regex]::Matches($source, [regex]::Escape("-Path '/v1/rotate'"))).Count -ne 3) {
    throw 'U8 remote-control acceptance must contain only wrong-auth, invalid-body and one valid public rotate request.'
}

Write-Host 'U8_REMOTE_CONTROL_PROBE_CONTRACT=PASS'
exit 0
