[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $ComponentName = 'com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity',
    [string] $ControlHost = 'api.alegria.by',
    [ValidateRange(30, 120)][int] $TerminalTimeoutSeconds = 65,
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
        [AllowNull()][object] $Body,
        [ValidateRange(1, 240)][int] $TimeoutSeconds = 20
    )
    $handler = [Net.Http.HttpClientHandler]::new()
    $client = [Net.Http.HttpClient]::new($handler)
    $response = $null
    $request = $null
    try {
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
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
$wrongAuth = Invoke-MishManagerRequest -Method POST -Path '/v1/rotate' -BearerToken 'definitely-wrong-manager-token-not-a-secret' -Body $null
if ($wrongAuth.Status -ne 401 -or $null -eq $wrongAuth.Json -or [string]$wrongAuth.Json.schema -cne 'mish.control.rotate/v1' -or [string]$wrongAuth.Json.result -cne 'REJECTED' -or [string]$wrongAuth.Json.reason -cne 'UNAUTHORIZED') {
    Stop-MishRemoteControl 'WRONG_MANAGER_AUTH_NOT_REJECTED' "Expected typed HTTP 401 UNAUTHORIZED, observed HTTP $($wrongAuth.Status)."
}
Start-Sleep -Milliseconds 750
$afterWrongAuthPath = Join-Path $env:TEMP 'mish-u8-remote-control-after-wrong-auth-v2.json'
$afterWrongAuth = Invoke-MishDiagnostic -Path $afterWrongAuthPath
if ([string]$afterWrongAuth.android.rotation.state -cne $baselineRotationState -or [string]$afterWrongAuth.android.rotation.operation_id -cne [string]$baselineRotationId -or [string]$afterWrongAuth.android.rotation.terminal_result -cne [string]$baselineTerminal) {
    Stop-MishRemoteControl 'WRONG_MANAGER_AUTH_MUTATED_ROTATION' 'Rejected manager authentication changed Rotation-owner state.'
}

# Public manager API accepts no caller body/request_id. Authenticated malformed input must fail before dispatch.
$invalidAuthenticatedRequest = Invoke-MishManagerRequest -Method POST -Path '/v1/rotate' -BearerToken $env:MISH_MANAGER_TOKEN -Body ([ordered]@{ caller_request_id = 'forbidden' })
if ($invalidAuthenticatedRequest.Status -ne 400 -or $null -eq $invalidAuthenticatedRequest.Json -or [string]$invalidAuthenticatedRequest.Json.schema -cne 'mish.control.rotate/v1' -or [string]$invalidAuthenticatedRequest.Json.result -cne 'REJECTED' -or [string]$invalidAuthenticatedRequest.Json.reason -cne 'INVALID_REQUEST') {
    Stop-MishRemoteControl 'INVALID_AUTHENTICATED_REQUEST_NOT_REJECTED' "Expected typed HTTP 400 INVALID_REQUEST, observed HTTP $($invalidAuthenticatedRequest.Status)."
}
Start-Sleep -Milliseconds 750
$afterInvalidRequestPath = Join-Path $env:TEMP 'mish-u8-remote-control-after-invalid-request-v2.json'
$afterInvalidRequest = Invoke-MishDiagnostic -Path $afterInvalidRequestPath
if ([string]$afterInvalidRequest.android.rotation.state -cne $baselineRotationState -or [string]$afterInvalidRequest.android.rotation.operation_id -cne [string]$baselineRotationId -or [string]$afterInvalidRequest.android.rotation.terminal_result -cne [string]$baselineTerminal) {
    Stop-MishRemoteControl 'INVALID_AUTHENTICATED_REQUEST_MUTATED_ROTATION' 'Authenticated invalid manager request changed Rotation-owner state.'
}

# Exactly one public manager command. Worker owns device routing, request_id generation and terminal wait.
$remote = Invoke-MishManagerRequest -Method POST -Path '/v1/rotate' -BearerToken $env:MISH_MANAGER_TOKEN -Body $null -TimeoutSeconds $TerminalTimeoutSeconds
if ($remote.Status -ne 200 -or $null -eq $remote.Json) {
    $reason = if ($null -ne $remote.Json) { [string]$remote.Json.reason } else { 'NONE' }
    Stop-MishRemoteControl 'REMOTE_ROTATE_FAILED' "Expected one typed HTTP 200 terminal response; observed HTTP $($remote.Status), reason=$reason."
}
if ([string]$remote.Json.schema -cne 'mish.control.rotate/v1') { Stop-MishRemoteControl 'REMOTE_SCHEMA_INVALID' 'Remote response schema mismatch.' }
if ([string]$remote.Json.request_id -notmatch '^mgr_[0-9a-f]{32}$') { Stop-MishRemoteControl 'REMOTE_REQUEST_ID_INVALID' 'Worker did not generate the canonical manager request id.' }
if (-not [bool]$remote.Json.terminal) { Stop-MishRemoteControl 'REMOTE_NOT_TERMINAL' 'One public manager command did not return a terminal result.' }
if ([string]$remote.Json.result -notin @('CHANGED', 'UNCHANGED')) { Stop-MishRemoteControl 'REMOTE_TERMINAL_UNACCEPTABLE' "Expected CHANGED or UNCHANGED, observed $([string]$remote.Json.result)." }
if ([string]$remote.Json.reason -cne 'NONE') { Stop-MishRemoteControl 'REMOTE_REASON_INVALID' "Successful terminal response reason is $([string]$remote.Json.reason)." }
if ($null -eq $remote.Json.operation_id -or [int64]$remote.Json.operation_id -le 0) { Stop-MishRemoteControl 'REMOTE_OPERATION_ID_INVALID' 'Terminal remote rotation has no positive operation id.' }
if (-not [bool]$remote.Json.dispatched -or [bool]$remote.Json.retryable) { Stop-MishRemoteControl 'REMOTE_DISPATCH_SEMANTICS_INVALID' 'Successful terminal response must be dispatched and non-retryable.' }
if ([string]$remote.Json.result -ceq 'CHANGED' -and [bool]$remote.Json.changed -ne $true) { Stop-MishRemoteControl 'REMOTE_CHANGED_FLAG_INVALID' 'CHANGED result must report changed=true.' }
if ([string]$remote.Json.result -ceq 'UNCHANGED' -and [bool]$remote.Json.changed -ne $false) { Stop-MishRemoteControl 'REMOTE_CHANGED_FLAG_INVALID' 'UNCHANGED result must report changed=false.' }
if ($null -eq $remote.Json.timing -or [int64]$remote.Json.timing.duration_ms -lt 0) { Stop-MishRemoteControl 'REMOTE_TIMING_INVALID' 'Typed remote timing is absent or invalid.' }

$requestId = [string]$remote.Json.request_id
$operationId = [int64]$remote.Json.operation_id
$terminalResult = [string]$remote.Json.result
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
    manager_api_schema = 'mish.control.rotate/v1'
    public_rotate_path = '/v1/rotate'
    public_rotate_body = 'EMPTY'
    server_generated_request_id = $true
    single_http_command = $true
    logical_rotation_requests = 1
    request_id = $requestId
    operation_id = $operationId
    terminal_result = $terminalResult
    operation_polls = 0
    client_request_id_generated = $false
    client_device_id_required_for_rotation = $false
    hosted_idempotency_contract = $true
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
Write-Host 'MISH_U8_REMOTE_CONTROL_PUBLIC_COMMANDS=1'
Write-Host 'MISH_U8_REMOTE_CONTROL_SERVER_REQUEST_ID=PASS'
Write-Host 'MISH_U8_REMOTE_CONTROL_MANAGER_POLLING=0'
Write-Host 'MISH_U8_REMOTE_CONTROL_RAW_IP_PERSISTED=false'
Write-Host 'MISH_U8_REMOTE_CONTROL_SECRETS_PERSISTED=false'
Write-Host "MISH_U8_REMOTE_CONTROL_EVIDENCE=$fullPath"
