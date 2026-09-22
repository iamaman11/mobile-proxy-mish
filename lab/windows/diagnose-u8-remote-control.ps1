[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $ComponentName = 'com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity',
    [string] $ControlHost = 'api.alegria.by',
    [ValidateRange(15, 180)][int] $TerminalTimeoutSeconds = 90,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8-remote-control-v1.json'),
    [string] $BaselineDiagnosticPath = (Join-Path $env:TEMP 'mish-u8-remote-control-baseline-v2.json'),
    [string] $PostDiagnosticPath = (Join-Path $env:TEMP 'mish-u8-remote-control-post-v2.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$schema = 'mish.lab.u8-remote-control/v1'
$identityAction = 'com.mobileproxymish.app.action.READ_CONTROL_IDENTITY_V1'
$identityComponent = "$PackageName/com.mobileproxymish.app.ControlIdentityProvisioningReceiver"

function Stop-MishRemoteControl {
    param([Parameter(Mandatory)][string] $Category, [Parameter(Mandatory)][string] $Message)
    throw "MISH_U8_REMOTE_CONTROL_FAILURE|$Category|$Message"
}

function Invoke-MishAdbCapture {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{ ExitCode = [int]$LASTEXITCODE; Text = ($rows -join [Environment]::NewLine).Trim() }
}

function Read-MishJsonFile {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-MishRemoteControl 'EVIDENCE_MISSING' "Expected evidence file is missing: $Path" }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) }
    catch { Stop-MishRemoteControl 'EVIDENCE_INVALID' "Evidence JSON is malformed: $Path" }
}

function Invoke-MishManagerRequest {
    param(
        [Parameter(Mandatory)][ValidateSet('GET','PUT','POST')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $BearerToken,
        [AllowNull()][object] $Body
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $response = $null
    $request = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $httpMethod = [Net.Http.HttpMethod]::new($Method)
        $request = [Net.Http.HttpRequestMessage]::new($httpMethod, "https://$ControlHost$Path")
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $BearerToken)
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Compress -Depth 6
            $request.Content = [Net.Http.StringContent]::new($json, [Text.Encoding]::UTF8, 'application/json')
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $text = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $parsed = $null
        if (-not [string]::IsNullOrWhiteSpace($text)) { try { $parsed = $text | ConvertFrom-Json } catch { $parsed = $null } }
        return [pscustomobject]@{ Status = [int]$response.StatusCode; Json = $parsed }
    }
    catch { Stop-MishRemoteControl 'MANAGER_TRANSPORT_FAILED' 'HTTPS manager request failed.' }
    finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-MishDiagnostic {
    param([Parameter(Mandatory)][string] $Path)
    & (Join-Path $PSScriptRoot 'collect-device-diagnostic.ps1') -AdbPath $AdbPath -PackageName $PackageName -EvidencePath $Path | Out-Host
    $diagnostic = Read-MishJsonFile -Path $Path
    if ([string]$diagnostic.classification -cne 'PASS') {
        Stop-MishRemoteControl 'PRODUCT_NOT_READY' "Canonical diagnostic classification is $([string]$diagnostic.classification)."
    }
    return $diagnostic
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) { Stop-MishRemoteControl 'ADB_MISSING' 'Canonical ADB executable is missing.' }
if ([string]::IsNullOrWhiteSpace($env:MISH_MANAGER_TOKEN) -or $env:MISH_MANAGER_TOKEN.Length -lt 32) { Stop-MishRemoteControl 'MANAGER_TOKEN_MISSING' 'Protected MISH_MANAGER_TOKEN is unavailable.' }
if ($ControlHost -cne 'api.alegria.by') { Stop-MishRemoteControl 'CONTROL_HOST_MISMATCH' 'Physical U8-E acceptance is pinned to api.alegria.by.' }

$devices = @(& $AdbPath devices | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) { Stop-MishRemoteControl 'DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.' }

$startBefore = Join-Path $env:TEMP 'mish-u8-remote-control-start-before-v1.json'
& (Join-Path $PSScriptRoot 'start-device-app.ps1') -AdbPath $AdbPath -PackageName $PackageName -ComponentName $ComponentName -ReceiptPath $startBefore | Out-Host

$identity = Invoke-MishAdbCapture -Arguments @('shell', 'am', 'broadcast', '-a', $identityAction, '-n', $identityComponent)
if ($identity.ExitCode -ne 0) { Stop-MishRemoteControl 'IDENTITY_READ_FAILED' 'DUMP-only public control identity broadcast failed.' }
$identityMatch = [regex]::Match($identity.Text, 'result=1,\s*data="mish-control-identity-v1:(?<device>[0-9a-f]{64}):(?<spki>[A-Za-z0-9+/=]+)"')
if (-not $identityMatch.Success) { Stop-MishRemoteControl 'IDENTITY_INVALID' 'DUMP-only public control identity response was absent or malformed.' }
$deviceId = $identityMatch.Groups['device'].Value
$publicSpki = $identityMatch.Groups['spki'].Value

$enroll = Invoke-MishManagerRequest -Method PUT -Path "/v1/devices/$deviceId" -BearerToken $env:MISH_MANAGER_TOKEN -Body ([ordered]@{ public_key_spki_b64 = $publicSpki })
if ($enroll.Status -ne 200 -or $null -eq $enroll.Json -or $enroll.Json.enrolled -ne $true) { Stop-MishRemoteControl 'ENROLLMENT_FAILED' "Manager enrollment returned HTTP $($enroll.Status)." }

# Restart exactly once after enrollment so the outbound WSS attempts immediately with the enrolled identity.
$startAfter = Join-Path $env:TEMP 'mish-u8-remote-control-start-after-v1.json'
& (Join-Path $PSScriptRoot 'start-device-app.ps1') -AdbPath $AdbPath -PackageName $PackageName -ComponentName $ComponentName -ReceiptPath $startAfter | Out-Host

$baseline = Invoke-MishDiagnostic -Path $BaselineDiagnosticPath
$baselineRotationId = $baseline.android.rotation.operation_id
$baselineRotationState = [string]$baseline.android.rotation.state
$baselineTerminal = $baseline.android.rotation.terminal_result

# Wrong manager authentication must be rejected before Durable Object/device mutation.
$invalidRequestId = "invalid_$env:GITHUB_RUN_ID"
$wrongAuth = Invoke-MishManagerRequest -Method POST -Path "/v1/devices/$deviceId/rotate" -BearerToken 'definitely-wrong-manager-token-not-a-secret' -Body ([ordered]@{ request_id = $invalidRequestId })
if ($wrongAuth.Status -ne 401) { Stop-MishRemoteControl 'WRONG_MANAGER_AUTH_NOT_REJECTED' "Expected HTTP 401, observed $($wrongAuth.Status)." }
Start-Sleep -Milliseconds 750
$afterWrongAuthPath = Join-Path $env:TEMP 'mish-u8-remote-control-after-wrong-auth-v2.json'
$afterWrongAuth = Invoke-MishDiagnostic -Path $afterWrongAuthPath
if ([string]$afterWrongAuth.android.rotation.state -cne $baselineRotationState -or [string]$afterWrongAuth.android.rotation.operation_id -cne [string]$baselineRotationId -or [string]$afterWrongAuth.android.rotation.terminal_result -cne [string]$baselineTerminal) {
    Stop-MishRemoteControl 'WRONG_MANAGER_AUTH_MUTATED_ROTATION' 'Rejected manager authentication changed Rotation-owner state.'
}

# Authenticated malformed manager input must fail before Durable Object/device mutation.
$invalidAuthenticatedRequest = Invoke-MishManagerRequest -Method POST -Path "/v1/devices/$deviceId/rotate" -BearerToken $env:MISH_MANAGER_TOKEN -Body ([ordered]@{ request_id = 'invalid request id' })
if ($invalidAuthenticatedRequest.Status -ne 400) { Stop-MishRemoteControl 'INVALID_AUTHENTICATED_REQUEST_NOT_REJECTED' "Expected HTTP 400, observed $($invalidAuthenticatedRequest.Status)." }
Start-Sleep -Milliseconds 750
$afterInvalidRequestPath = Join-Path $env:TEMP 'mish-u8-remote-control-after-invalid-request-v2.json'
$afterInvalidRequest = Invoke-MishDiagnostic -Path $afterInvalidRequestPath
if ([string]$afterInvalidRequest.android.rotation.state -cne $baselineRotationState -or [string]$afterInvalidRequest.android.rotation.operation_id -cne [string]$baselineRotationId -or [string]$afterInvalidRequest.android.rotation.terminal_result -cne [string]$baselineTerminal) {
    Stop-MishRemoteControl 'INVALID_AUTHENTICATED_REQUEST_MUTATED_ROTATION' 'Authenticated invalid manager request changed Rotation-owner state.'
}

$requestId = "u8e_$env:GITHUB_RUN_ID"
$dispatch = Invoke-MishManagerRequest -Method POST -Path "/v1/devices/$deviceId/rotate" -BearerToken $env:MISH_MANAGER_TOKEN -Body ([ordered]@{ request_id = $requestId })
# Exactly one valid dispatch attempt. DEVICE_OFFLINE is an acceptance failure, never a retry loop.
if ($dispatch.Status -ne 202 -or $null -eq $dispatch.Json) {
    $errorCode = if ($null -ne $dispatch.Json) { [string]$dispatch.Json.error } else { 'NONE' }
    Stop-MishRemoteControl 'REMOTE_DISPATCH_FAILED' "Expected one HTTP 202 dispatch; observed HTTP $($dispatch.Status), error=$errorCode."
}
if ([string]$dispatch.Json.request_id -cne $requestId -or [string]$dispatch.Json.status -cne 'DISPATCHED') { Stop-MishRemoteControl 'REMOTE_DISPATCH_INVALID' 'Remote dispatch response did not preserve request id/status.' }

$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TerminalTimeoutSeconds)
$operationId = $null
$terminalResult = $null
$terminal = $null
$polls = 0
while ([DateTimeOffset]::UtcNow -lt $deadline) {
    Start-Sleep -Seconds 1
    $polls += 1
    $observation = Invoke-MishManagerRequest -Method GET -Path "/v1/devices/$deviceId/operations/$requestId" -BearerToken $env:MISH_MANAGER_TOKEN -Body $null
    if ($observation.Status -ne 200 -or $null -eq $observation.Json) { Stop-MishRemoteControl 'REMOTE_OPERATION_READ_FAILED' "Operation read returned HTTP $($observation.Status)." }
    if ([string]$observation.Json.request_id -cne $requestId) { Stop-MishRemoteControl 'REMOTE_CORRELATION_CHANGED' 'Operation read changed request_id.' }
    if ($null -ne $observation.Json.operation_id) {
        $observedId = [int64]$observation.Json.operation_id
        if ($observedId -le 0) { Stop-MishRemoteControl 'REMOTE_OPERATION_ID_INVALID' 'Operation id must be positive.' }
        if ($null -eq $operationId) { $operationId = $observedId } elseif ($operationId -ne $observedId) { Stop-MishRemoteControl 'REMOTE_OPERATION_ID_CHANGED' 'Operation id changed during one request correlation.' }
    }
    if ([string]$observation.Json.status -ceq 'TERMINAL') { $terminal = $observation.Json; $terminalResult = [string]$observation.Json.result; break }
}
if ($null -eq $terminal) { Stop-MishRemoteControl 'REMOTE_TERMINAL_TIMEOUT' 'One remote rotation did not reach terminal state inside the bounded deadline.' }
if ($null -eq $operationId) { Stop-MishRemoteControl 'REMOTE_OPERATION_ID_MISSING' 'Terminal remote rotation has no operation id.' }
if ($terminalResult -notin @('CHANGED', 'UNCHANGED')) { Stop-MishRemoteControl 'REMOTE_TERMINAL_UNACCEPTABLE' "Expected CHANGED or UNCHANGED, observed $terminalResult." }

# Replay the same logical request id exactly once; this must never create a second Rotation operation.
$duplicate = Invoke-MishManagerRequest -Method POST -Path "/v1/devices/$deviceId/rotate" -BearerToken $env:MISH_MANAGER_TOKEN -Body ([ordered]@{ request_id = $requestId })
if ($duplicate.Status -ne 200 -or $null -eq $duplicate.Json -or [string]$duplicate.Json.status -cne 'TERMINAL' -or [int64]$duplicate.Json.operation_id -ne $operationId -or [string]$duplicate.Json.result -cne $terminalResult) {
    Stop-MishRemoteControl 'REMOTE_IDEMPOTENCY_FAILED' 'Same request_id did not return the same terminal operation/result.'
}

$post = Invoke-MishDiagnostic -Path $PostDiagnosticPath
if ([int64]$post.android.rotation.operation_id -ne $operationId) { Stop-MishRemoteControl 'PRODUCT_OPERATION_ID_MISMATCH' 'PRODUCT Rotation owner and broker disagree on operation_id.' }
if ([string]$post.android.rotation.terminal_result -cne $terminalResult) { Stop-MishRemoteControl 'PRODUCT_TERMINAL_MISMATCH' 'PRODUCT Rotation owner and broker disagree on terminal result.' }
if ([string]$post.external.adb_loopback_proxy_e2e.result -cne 'PASS' -or [string]$post.external.mesh_proxy_e2e.result -cne 'PASS') { Stop-MishRemoteControl 'POST_ROTATION_PROXY_E2E_FAILED' 'Post-rotation proxy E2E did not pass.' }

$evidence = [ordered]@{
    schema = $schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'PASS'
    classification = 'U8_REMOTE_CONTROL_ROTATION_PASS'
    exact_candidate_acceptance = 'PASS'
    control_host = $ControlHost
    public_identity_read = $true
    enrollment = 'PASS'
    restart_after_enrollment = 'PASS'
    wrong_manager_auth_status = 401
    wrong_manager_auth_zero_rotation_mutation = $true
    authenticated_invalid_request_status = 400
    authenticated_invalid_request_zero_rotation_mutation = $true
    logical_rotation_requests = 1
    duplicate_same_request_replays = 1
    request_id = $requestId
    operation_id = $operationId
    terminal_result = $terminalResult
    operation_polls = $polls
    idempotent_same_operation = $true
    post_product_diagnostic = [string]$post.classification
    post_readiness = [string]$post.android.readiness.state
    post_root_authorized = [bool]$post.android.root.policy_authorized
    post_proxy_state = [string]$post.android.proxy.state
    post_mesh_admitted = [bool]$post.android.mesh.admitted
    post_mesh_ingress = [bool]$post.android.mesh.ingress_running
    post_loopback_proxy_e2e = [string]$post.external.adb_loopback_proxy_e2e.result
    post_mesh_proxy_e2e = [string]$post.external.mesh_proxy_e2e.result
    manager_token_persisted = $false
    public_spki_persisted = $false
    raw_public_ip_persisted = $false
    secrets_persisted_in_evidence = $false
}
$fullPath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($fullPath, (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
$publicSpki = $null
$env:MISH_MANAGER_TOKEN = $null

Write-Host 'MISH_U8_REMOTE_CONTROL=PASS'
Write-Host 'MISH_U8_REMOTE_CONTROL_CLASSIFICATION=U8_REMOTE_CONTROL_ROTATION_PASS'
Write-Host "MISH_U8_REMOTE_CONTROL_OPERATION_ID=$operationId"
Write-Host "MISH_U8_REMOTE_CONTROL_TERMINAL=$terminalResult"
Write-Host 'MISH_U8_REMOTE_CONTROL_INVALID_AUTHENTICATED_REQUEST=400_ZERO_MUTATION'
Write-Host 'MISH_U8_REMOTE_CONTROL_LOGICAL_ROTATION_REQUESTS=1'
Write-Host 'MISH_U8_REMOTE_CONTROL_IDEMPOTENT_REPLAY=PASS'
Write-Host 'MISH_U8_REMOTE_CONTROL_RAW_IP_PERSISTED=false'
Write-Host 'MISH_U8_REMOTE_CONTROL_SECRETS_PERSISTED=false'
Write-Host "MISH_U8_REMOTE_CONTROL_EVIDENCE=$fullPath"
