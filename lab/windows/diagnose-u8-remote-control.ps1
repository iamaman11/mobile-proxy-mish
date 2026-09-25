[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $ComponentName = 'com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity',
    [string] $ControlHost = 'api.alegria.by',
    [ValidateRange(20, 120)][int] $TerminalTimeoutSeconds = 20,
    [ValidateRange(5, 30)][int] $ExternalProbeTimeoutSeconds = 15,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8-remote-control-v1.json'),
    [string] $BaselineDiagnosticPath = (Join-Path $env:TEMP 'mish-u8-remote-control-baseline-v2.json'),
    [string] $PostDiagnosticPath = (Join-Path $env:TEMP 'mish-u8-remote-control-post-v2.json'),
    [switch] $CollectTelephonyDetachEvidence,
    [string] $TelephonyDetachEvidencePath = (Join-Path $env:TEMP 'mish-u8-telephony-detach-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$schema = 'mish.lab.u8-remote-control/v1'
$identityAction = 'com.mobileproxymish.app.action.READ_CONTROL_IDENTITY_V1'
$identityComponent = "$PackageName/com.mobileproxymish.app.ControlIdentityProvisioningReceiver"

Import-Module (Join-Path $PSScriptRoot 'PublicEgressObservation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'TelephonyDetachObservation.psm1') -Force

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

function Invoke-MishDiagnosticSnapshot {
    param([Parameter(Mandatory)][string] $Path)
    & (Join-Path $PSScriptRoot 'collect-device-diagnostic.ps1') -AdbPath $AdbPath -PackageName $PackageName -EvidencePath $Path | Out-Host
    return (Read-MishJsonFile -Path $Path)
}

function Invoke-MishDiagnostic {
    param([Parameter(Mandatory)][string] $Path)
    $diagnostic = Invoke-MishDiagnosticSnapshot -Path $Path
    if ([string]$diagnostic.classification -cne 'PASS') {
        Stop-MishRemoteControl 'PRODUCT_NOT_READY' "Canonical diagnostic classification is $([string]$diagnostic.classification)."
    }
    return $diagnostic
}

function Invoke-MishControlSnapshot {
    $capture = Invoke-MishAdbCapture -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', 'control_snapshot_v1'
    )
    if ($capture.ExitCode -ne 0) {
        Stop-MishRemoteControl 'CONTROL_SNAPSHOT_FAILED' 'DUMP-only control snapshot call failed.'
    }
    $payloadMatch = [regex]::Match($capture.Text, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $payloadMatch.Success) {
        Stop-MishRemoteControl 'CONTROL_SNAPSHOT_INVALID' 'Control diagnostics bridge returned no payload.'
    }

    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
        $snapshot = ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch {
        Stop-MishRemoteControl 'CONTROL_SNAPSHOT_INVALID' 'Control diagnostics payload is malformed.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if ([string]$snapshot.schema -cne 'mish.control.diagnostics/v1' -or
        [string]$snapshot.application_id -cne $PackageName) {
        Stop-MishRemoteControl 'CONTROL_SNAPSHOT_IDENTITY_MISMATCH' 'Control diagnostics schema/package identity mismatch.'
    }
    return $snapshot
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

# Prove the control session is not merely fresh from the restart above. Wait beyond the Worker's
# 10 s authentication grace and require native heartbeats to advance without any reconnect.
$controlBeforeIdle = Invoke-MishControlSnapshot
if ([string]$controlBeforeIdle.control.state -cne 'READY') {
    Stop-MishRemoteControl 'CONTROL_NOT_READY_BEFORE_IDLE' "Control state is $([string]$controlBeforeIdle.control.state)."
}
$heartbeatBeforeIdle = [int64]$controlBeforeIdle.control.application_heartbeat_count
$reconnectBeforeIdle = [int64]$controlBeforeIdle.control.reconnect_count
$idleProofSeconds = 12
Start-Sleep -Seconds $idleProofSeconds
$controlAfterIdle = Invoke-MishControlSnapshot
if ([string]$controlAfterIdle.control.state -cne 'READY') {
    Stop-MishRemoteControl 'CONTROL_NOT_READY_AFTER_IDLE' "Control state is $([string]$controlAfterIdle.control.state)."
}
$heartbeatAfterIdle = [int64]$controlAfterIdle.control.application_heartbeat_count
$reconnectAfterIdle = [int64]$controlAfterIdle.control.reconnect_count
$heartbeatDelta = $heartbeatAfterIdle - $heartbeatBeforeIdle
if ($heartbeatDelta -lt 2) {
    Stop-MishRemoteControl 'CONTROL_HEARTBEAT_NOT_ADVANCING' "Expected at least two heartbeat ACKs during idle proof; observed delta=$heartbeatDelta."
}
if ($reconnectAfterIdle -ne $reconnectBeforeIdle) {
    Stop-MishRemoteControl 'CONTROL_RECONNECTED_DURING_IDLE' "Control reconnect count changed during idle proof: $reconnectBeforeIdle -> $reconnectAfterIdle."
}
if ($null -eq $controlAfterIdle.control.session_age_ms -or
    [int64]$controlAfterIdle.control.session_age_ms -lt 10000) {
    Stop-MishRemoteControl 'CONTROL_SESSION_NOT_LONG_LIVED' 'Control session did not remain READY beyond the Worker authentication freshness grace.'
}

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

# Independent observer uses the already-serving PRODUCT HTTP CONNECT listener. It does not
# trigger Rotation and never persists the raw addresses; it exists only to cross-check the native
# CHANGED/UNCHANGED terminal result from outside the Rotation owner.
$observationContext = $null
$beforeAddress = $null
$afterAddress = $null
$telephonyObservationStarted = $false
$telephonySnapshot = $null
$radioDetachResearch = $null
try {
    $observationContext = New-MishPublicEgressObservationContext `
        -AdbPath $AdbPath `
        -PackageName $PackageName
    $externalBefore = Invoke-MishExternalPublicIpObservation `
        -Context $observationContext `
        -TimeoutSeconds $ExternalProbeTimeoutSeconds
    $beforeAddress = [string]$externalBefore.Address
    $externalBeforeMs = [int64]$externalBefore.ElapsedMs

if ($CollectTelephonyDetachEvidence) {
    [void](Start-MishTelephonyDetachObservation -AdbPath $AdbPath -PackageName $PackageName)
    $telephonyObservationStarted = $true
}

# Exactly one public manager command. Worker owns device routing, request_id generation and terminal wait.
$remote = Invoke-MishManagerRequest -Method POST -Path '/v1/rotate' -BearerToken $env:MISH_MANAGER_TOKEN -Body $null -TimeoutSeconds $TerminalTimeoutSeconds
if ($null -eq $remote.Json) {
    Stop-MishRemoteControl 'REMOTE_ROTATE_FAILED' "Manager returned HTTP $($remote.Status) without a typed response."
}
if ([string]$remote.Json.schema -cne 'mish.control.rotate/v1') { Stop-MishRemoteControl 'REMOTE_SCHEMA_INVALID' 'Remote response schema mismatch.' }
if ([string]$remote.Json.request_id -notmatch '^mgr_[0-9a-f]{32}$') { Stop-MishRemoteControl 'REMOTE_REQUEST_ID_INVALID' 'Worker did not generate the canonical manager request id.' }
if (-not [bool]$remote.Json.dispatched -or [bool]$remote.Json.retryable) { Stop-MishRemoteControl 'REMOTE_DISPATCH_SEMANTICS_INVALID' 'Dispatched remote operation must be non-retryable.' }
if ($null -eq $remote.Json.timing -or [int64]$remote.Json.timing.duration_ms -lt 0) { Stop-MishRemoteControl 'REMOTE_TIMING_INVALID' 'Typed remote timing is absent or invalid.' }

$requestId = [string]$remote.Json.request_id
$operationId = if ($null -eq $remote.Json.operation_id) { 0L } else { [int64]$remote.Json.operation_id }
$managerDurationMs = [int64]$remote.Json.timing.duration_ms
$managerTimedOut = (
    $remote.Status -eq 504 -and
    [string]$remote.Json.result -ceq 'UNKNOWN' -and
    [string]$remote.Json.reason -ceq 'TIMEOUT' -and
    -not [bool]$remote.Json.terminal
)

# A manager timeout is an observation boundary, not permission to retry. Capture exactly one
# CONTROL snapshot and one canonical PRODUCT snapshot immediately, persist only redacted state,
# then fail acceptance. The durable PRODUCT operation may continue under its existing owner.
if ($managerTimedOut) {
    $timeoutControl = $null
    $timeoutControlCapture = 'FAILED'
    try {
        $timeoutControl = Invoke-MishControlSnapshot
        $timeoutControlCapture = 'CAPTURED'
    }
    catch {
        $timeoutControlCapture = 'FAILED'
    }

    $timeoutPost = $null
    $timeoutPostCapture = 'FAILED'
    try {
        $timeoutPost = Invoke-MishDiagnosticSnapshot -Path $PostDiagnosticPath
        $timeoutPostCapture = 'CAPTURED'
    }
    catch {
        $timeoutPostCapture = 'FAILED'
    }

    $timeoutOperationTiming = if ($null -eq $timeoutControl) {
        $null
    } else {
        $timeoutControl.control.operation_timing
    }
    $timeoutOperationId = if ($operationId -gt 0) {
        $operationId
    } elseif ($null -ne $timeoutOperationTiming -and $null -ne $timeoutOperationTiming.operation_id) {
        [int64]$timeoutOperationTiming.operation_id
    } else {
        0L
    }

    $timeoutControlState = if ($null -eq $timeoutControl) { $null } else { [string]$timeoutControl.control.state }
    $timeoutPending = if ($null -eq $timeoutControl) { $null } else { [bool]$timeoutControl.control.pending_operation }
    $timeoutPendingId = if ($null -eq $timeoutControl) { $null } else { $timeoutControl.control.pending_operation_id }
    $timeoutLastTerminal = if ($null -eq $timeoutControl) { $null } else { $timeoutControl.control.last_terminal_result }

    $timeoutProductClassification = if ($null -eq $timeoutPost) { $null } else { [string]$timeoutPost.classification }
    $timeoutRotationState = if ($null -eq $timeoutPost) { $null } else { [string]$timeoutPost.android.rotation.state }
    $timeoutRotationOperationId = if ($null -eq $timeoutPost) { $null } else { $timeoutPost.android.rotation.operation_id }
    $timeoutRotationTerminal = if ($null -eq $timeoutPost) { $null } else { $timeoutPost.android.rotation.terminal_result }
    $timeoutRotationFailure = if ($null -eq $timeoutPost) { $null } else { $timeoutPost.android.rotation.failure }
    $timeoutRotationActiveTasks = if ($null -eq $timeoutPost) { $null } else { $timeoutPost.android.rotation.active_tasks }
    $timeoutRestoreRequired = if ($null -eq $timeoutPost) { $null } else { $timeoutPost.android.rotation.restore_required }
    $timeoutCellularState = if ($null -eq $timeoutPost) { $null } else { [string]$timeoutPost.android.cellular.state }
    $timeoutCellularGeneration = if ($null -eq $timeoutPost) { $null } else { $timeoutPost.android.cellular.owner_sequence }
    $timeoutRootAuthorized = if ($null -eq $timeoutPost) { $null } else { $timeoutPost.android.root.policy_authorized }
    $timeoutRootGeneration = if ($null -eq $timeoutPost) { $null } else { $timeoutPost.android.root.policy_authorized_generation }
    $timeoutProxyState = if ($null -eq $timeoutPost) { $null } else { [string]$timeoutPost.android.proxy.state }
    $timeoutMeshState = if ($null -eq $timeoutPost) { $null } else { [string]$timeoutPost.android.mesh.state }
    $timeoutReadinessState = if ($null -eq $timeoutPost) { $null } else { [string]$timeoutPost.android.readiness.state }

    $timeoutEvidence = [ordered]@{
        schema = $schema
        collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        acceptance_result = 'FAIL'
        classification = 'U8_REMOTE_CONTROL_MANAGER_TIMEOUT_DIAGNOSTIC'
        exact_candidate_acceptance = 'FAIL'
        control_host = $ControlHost
        public_rotate_path = '/v1/rotate'
        public_rotate_body = 'EMPTY'
        single_http_command = $true
        logical_rotation_requests = 1
        operation_polls = 0
        client_request_id_generated = $false
        manager_api_schema = 'mish.control.rotate/v1'
        manager_http_status = 504
        manager_result = 'UNKNOWN'
        manager_reason = 'TIMEOUT'
        manager_terminal = $false
        manager_dispatched = $true
        manager_retryable = $false
        manager_duration_ms = $managerDurationMs
        manager_server_bound_ms = 18000
        client_bound_seconds = $TerminalTimeoutSeconds
        operation_id = $timeoutOperationId
        control_snapshot_capture = $timeoutControlCapture
        control_state_at_timeout = $timeoutControlState
        pending_operation_at_timeout = $timeoutPending
        pending_operation_id_at_timeout = $timeoutPendingId
        last_terminal_result_at_timeout = $timeoutLastTerminal
        device_timeline_at_timeout = $timeoutOperationTiming
        product_snapshot_capture = $timeoutPostCapture
        product_classification_at_timeout = $timeoutProductClassification
        rotation_state_at_timeout = $timeoutRotationState
        rotation_operation_id_at_timeout = $timeoutRotationOperationId
        rotation_terminal_result_at_timeout = $timeoutRotationTerminal
        rotation_failure_at_timeout = $timeoutRotationFailure
        rotation_active_tasks_at_timeout = $timeoutRotationActiveTasks
        restore_required_at_timeout = $timeoutRestoreRequired
        cellular_state_at_timeout = $timeoutCellularState
        cellular_generation_at_timeout = $timeoutCellularGeneration
        root_authorized_at_timeout = $timeoutRootAuthorized
        root_authorized_generation_at_timeout = $timeoutRootGeneration
        proxy_state_at_timeout = $timeoutProxyState
        mesh_state_at_timeout = $timeoutMeshState
        readiness_state_at_timeout = $timeoutReadinessState
        external_public_ip_before_observation_ms = $externalBeforeMs
        external_public_ip_after_observation_ms = $null
        external_public_ip_consensus = $null
        manager_token_persisted = $false
        public_spki_persisted = $false
        raw_public_ip_persisted = $false
        secrets_persisted_in_evidence = $false
    }

    $timeoutFullPath = [IO.Path]::GetFullPath($EvidencePath)
    $timeoutParent = Split-Path -Parent $timeoutFullPath
    if ($timeoutParent) { [IO.Directory]::CreateDirectory($timeoutParent) | Out-Null }
    [IO.File]::WriteAllText(
        $timeoutFullPath,
        (($timeoutEvidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    $beforeAddress = $null
    Write-Host "MISH_U8_REMOTE_CONTROL_TIMEOUT_DIAGNOSTIC=CAPTURED/operation_id=$timeoutOperationId/manager_duration_ms=$managerDurationMs/control=$timeoutControlCapture/product=$timeoutPostCapture"
    Stop-MishRemoteControl 'REMOTE_ROTATE_TIMEOUT' 'Manager reached the 18 second public deadline; no retry or polling was issued and PRODUCT-side evidence was captured.'
}

if ($remote.Status -ne 200) {
    Stop-MishRemoteControl 'REMOTE_ROTATE_FAILED' "Expected HTTP 200 or typed diagnostic 504; observed HTTP $($remote.Status), reason=$([string]$remote.Json.reason)."
}
if (-not [bool]$remote.Json.terminal) { Stop-MishRemoteControl 'REMOTE_NOT_TERMINAL' 'One public manager command did not return a terminal result.' }
if ([string]$remote.Json.result -notin @('CHANGED', 'UNCHANGED')) { Stop-MishRemoteControl 'REMOTE_TERMINAL_UNACCEPTABLE' "Expected CHANGED or UNCHANGED, observed $([string]$remote.Json.result)." }
if ([string]$remote.Json.reason -cne 'NONE') { Stop-MishRemoteControl 'REMOTE_REASON_INVALID' "Successful terminal response reason is $([string]$remote.Json.reason)." }
if ($operationId -le 0) { Stop-MishRemoteControl 'REMOTE_OPERATION_ID_INVALID' 'Terminal remote rotation has no positive operation id.' }
if ([string]$remote.Json.result -ceq 'CHANGED' -and [bool]$remote.Json.changed -ne $true) { Stop-MishRemoteControl 'REMOTE_CHANGED_FLAG_INVALID' 'CHANGED result must report changed=true.' }
if ([string]$remote.Json.result -ceq 'UNCHANGED' -and [bool]$remote.Json.changed -ne $false) { Stop-MishRemoteControl 'REMOTE_CHANGED_FLAG_INVALID' 'UNCHANGED result must report changed=false.' }
if ($managerDurationMs -gt 18000) {
    Stop-MishRemoteControl 'REMOTE_RESPONSE_TOO_SLOW' "Manager response exceeded the 18 second server bound: $managerDurationMs ms."
}

$terminalResult = [string]$remote.Json.result
$post = Invoke-MishDiagnostic -Path $PostDiagnosticPath
if ([int64]$post.android.rotation.operation_id -ne $operationId) { Stop-MishRemoteControl 'PRODUCT_OPERATION_ID_MISMATCH' 'PRODUCT Rotation owner and broker disagree on operation_id.' }
if ([string]$post.android.rotation.terminal_result -cne $terminalResult) { Stop-MishRemoteControl 'PRODUCT_TERMINAL_MISMATCH' 'PRODUCT Rotation owner and broker disagree on terminal result.' }
if ([string]$post.external.adb_loopback_proxy_e2e.result -cne 'PASS' -or [string]$post.external.mesh_proxy_e2e.result -cne 'PASS') { Stop-MishRemoteControl 'POST_ROTATION_PROXY_E2E_FAILED' 'Post-rotation proxy E2E did not pass.' }

$externalAfter = Invoke-MishExternalPublicIpObservation `
    -Context $observationContext `
    -TimeoutSeconds $ExternalProbeTimeoutSeconds
$afterAddress = [string]$externalAfter.Address
$externalPublicIpChanged = $beforeAddress -cne $afterAddress
$externalPublicIpOutcome = if ($externalPublicIpChanged) { 'CHANGED' } else { 'UNCHANGED' }
$externalPublicIpConsensus = $externalPublicIpOutcome -ceq $terminalResult
$externalAfterMs = [int64]$externalAfter.ElapsedMs
$beforeAddress = $null
$afterAddress = $null
if (-not $externalPublicIpConsensus) {
    Stop-MishRemoteControl 'EXTERNAL_PUBLIC_IP_RESULT_MISMATCH' 'Independent PRODUCT-proxy public-IP observation disagrees with the native Rotation terminal result.'
}

# Read one bounded timing record from the same real remote operation. This is observation only:
# no second trigger, local Rotation call, polling loop, radio mutation or public-IP probe is added.
$controlTimeline = Invoke-MishControlSnapshot
$operationTiming = $controlTimeline.control.operation_timing
if ($null -eq $operationTiming -or [string]$operationTiming.origin -cne 'REMOTE_COMMAND_RECEIVED') {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_MISSING' 'Control diagnostics did not expose the canonical remote-command timing origin.'
}
$rotationTiming = $operationTiming.rotation
if ($null -eq $rotationTiming -or
    $null -eq $operationTiming.operation_id -or [int64]$operationTiming.operation_id -ne $operationId -or
    $null -eq $rotationTiming.operation_id -or [int64]$rotationTiming.operation_id -ne $operationId) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_OPERATION_MISMATCH' 'CONTROL and Rotation timing evidence are not correlated to the manager operation id.'
}

foreach ($field in @(
    'operation_age_ms',
    'operation_reserved_ms',
    'accepted_sent_ms',
    'rotation_terminal_ms',
    'result_sent_ms',
    'result_ack_ms',
    'rotation_origin_from_command_ms'
)) {
    if ($null -eq $operationTiming.$field -or [int64]$operationTiming.$field -lt 0) {
        Stop-MishRemoteControl 'DEVICE_TIMELINE_INCOMPLETE' "Missing/invalid CONTROL timing field: $field."
    }
}
if ([string]$operationTiming.rotation_terminal_control_state -notin @('CONNECTING', 'AUTHENTICATING', 'READY', 'BACKOFF')) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_INCOMPLETE' 'Missing/invalid CONTROL state at Rotation terminal.'
}
foreach ($counter in @(
    'post_terminal_connect_attempts',
    'post_terminal_transport_connections'
)) {
    if ($null -eq $operationTiming.$counter -or [int64]$operationTiming.$counter -lt 0) {
        Stop-MishRemoteControl 'DEVICE_TIMELINE_INCOMPLETE' "Missing/invalid CONTROL reconnect counter: $counter."
    }
}
foreach ($field in @(
    'operation_age_ms',
    'activated_ms',
    'pre_rotation_probe_started_ms',
    'pre_rotation_probe_completed_ms',
    'airplane_enable_started_ms',
    'airplane_enable_effect_completed_ms',
    'airplane_on_observed_ms',
    'cellular_loss_observed_ms',
    'radio_power_off_observed_ms',
    'airplane_disable_started_ms',
    'airplane_disable_effect_completed_ms',
    'airplane_off_observed_ms',
    'cellular_request_rearm_started_ms',
    'cellular_request_rearm_completed_ms',
    'first_platform_cellular_observation_ms',
    'fresh_cellular_observed_ms',
    'fresh_cellular_generation',
    'root_authorized_ms',
    'root_authorized_generation',
    'post_rotation_probe_started_ms',
    'post_rotation_probe_completed_ms',
    'terminal_ms'
)) {
    if ($null -eq $rotationTiming.$field -or [int64]$rotationTiming.$field -lt 0) {
        Stop-MishRemoteControl 'DEVICE_TIMELINE_INCOMPLETE' "Missing/invalid Rotation timing field: $field."
    }
}
if ($null -eq $rotationTiming.platform_cellular_observations_after_rearm -or
    [int64]$rotationTiming.platform_cellular_observations_after_rearm -lt 1) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_INCOMPLETE' 'No Android Cellular observation entered Rust after request rearm.'
}
if ([bool]$controlTimeline.control.pending_operation) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_NOT_ACKED' 'RESULT correlation is still pending after the manager returned and post diagnostics completed.'
}
if ([int64]$rotationTiming.fresh_cellular_generation -ne [int64]$rotationTiming.root_authorized_generation -or
    [int64]$rotationTiming.fresh_cellular_generation -ne [int64]$post.android.rotation.after_generation) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_GENERATION_MISMATCH' 'Fresh Cellular, root authorization and terminal Rotation generation are not exact.'
}

$rotationOriginFromCommandMs = [int64]$operationTiming.rotation_origin_from_command_ms
$rotationActivatedFromCommandMs = $rotationOriginFromCommandMs + [int64]$rotationTiming.activated_ms
$rotationTerminalFromCommandMs = $rotationOriginFromCommandMs + [int64]$rotationTiming.terminal_ms

if ($null -ne $operationTiming.post_terminal_connect_started_ms -and
    [int64]$operationTiming.post_terminal_connect_started_ms -lt [int64]$operationTiming.rotation_terminal_ms) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_ORDER_INVALID' 'Post-terminal CONTROL connect attempt precedes Rotation terminal.'
}
if ($null -ne $operationTiming.post_terminal_transport_connected_ms -and
    [int64]$operationTiming.post_terminal_transport_connected_ms -lt [int64]$operationTiming.rotation_terminal_ms) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_ORDER_INVALID' 'Post-terminal CONTROL transport connection precedes Rotation terminal.'
}
if ($null -ne $operationTiming.post_terminal_connect_started_ms -and
    $null -ne $operationTiming.post_terminal_transport_connected_ms -and
    [int64]$operationTiming.post_terminal_connect_started_ms -gt [int64]$operationTiming.post_terminal_transport_connected_ms) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_ORDER_INVALID' 'Post-terminal CONTROL transport connected before its recorded connect attempt.'
}

# Preserve the accepted event model. Independent observations are intentionally not ordered
# against each other: airplane-ON/cellular-loss and fresh-Cellular/root-auth may arrive either way.
if ([int64]$operationTiming.operation_reserved_ms -gt [int64]$operationTiming.accepted_sent_ms -or
    [int64]$operationTiming.accepted_sent_ms -gt $rotationActivatedFromCommandMs -or
    [int64]$rotationTiming.activated_ms -gt [int64]$rotationTiming.pre_rotation_probe_started_ms -or
    [int64]$rotationTiming.pre_rotation_probe_started_ms -gt [int64]$rotationTiming.pre_rotation_probe_completed_ms -or
    [int64]$rotationTiming.pre_rotation_probe_completed_ms -gt [int64]$rotationTiming.airplane_enable_started_ms -or
    [int64]$rotationTiming.airplane_enable_started_ms -gt [int64]$rotationTiming.airplane_enable_effect_completed_ms -or
    [int64]$rotationTiming.airplane_on_observed_ms -gt [int64]$rotationTiming.airplane_disable_started_ms -or
    [int64]$rotationTiming.cellular_loss_observed_ms -gt [int64]$rotationTiming.airplane_disable_started_ms -or
    [int64]$rotationTiming.radio_power_off_observed_ms -gt [int64]$rotationTiming.airplane_disable_started_ms -or
    [int64]$rotationTiming.airplane_disable_started_ms -gt [int64]$rotationTiming.airplane_disable_effect_completed_ms -or
    [int64]$rotationTiming.airplane_disable_effect_completed_ms -gt [int64]$rotationTiming.airplane_off_observed_ms -or
    [int64]$rotationTiming.airplane_off_observed_ms -gt [int64]$rotationTiming.cellular_request_rearm_started_ms -or
    [int64]$rotationTiming.cellular_request_rearm_started_ms -gt [int64]$rotationTiming.cellular_request_rearm_completed_ms -or
    [int64]$rotationTiming.cellular_request_rearm_started_ms -gt [int64]$rotationTiming.first_platform_cellular_observation_ms -or
    [int64]$rotationTiming.first_platform_cellular_observation_ms -gt [int64]$rotationTiming.fresh_cellular_observed_ms -or
    [int64]$rotationTiming.airplane_off_observed_ms -gt [int64]$rotationTiming.post_rotation_probe_started_ms -or
    [int64]$rotationTiming.fresh_cellular_observed_ms -gt [int64]$rotationTiming.post_rotation_probe_started_ms -or
    [int64]$rotationTiming.root_authorized_ms -gt [int64]$rotationTiming.post_rotation_probe_started_ms -or
    [int64]$rotationTiming.post_rotation_probe_started_ms -gt [int64]$rotationTiming.post_rotation_probe_completed_ms -or
    [int64]$rotationTiming.post_rotation_probe_completed_ms -gt [int64]$rotationTiming.terminal_ms -or
    $rotationTerminalFromCommandMs -gt [int64]$operationTiming.rotation_terminal_ms -or
    [int64]$operationTiming.rotation_terminal_ms -gt [int64]$operationTiming.result_sent_ms -or
    [int64]$operationTiming.result_sent_ms -gt [int64]$operationTiming.result_ack_ms) {
    Stop-MishRemoteControl 'DEVICE_TIMELINE_ORDER_INVALID' 'Remote rotation phase evidence violates the accepted event-driven ordering.'
}

if ($CollectTelephonyDetachEvidence) {
    $telephonySnapshot = Stop-MishTelephonyDetachObservation -AdbPath $AdbPath -PackageName $PackageName -EvidencePath $TelephonyDetachEvidencePath
    $telephonyObservationStarted = $false
    $radioDetachResearch = New-MishTelephonyDetachResearchProjection -Observation $telephonySnapshot -OperationId $operationId -RotationTiming $rotationTiming
}

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
    idle_liveness_proof = $true
    idle_seconds = $idleProofSeconds
    heartbeat_count_before_idle = $heartbeatBeforeIdle
    heartbeat_count_after_idle = $heartbeatAfterIdle
    heartbeat_delta = $heartbeatDelta
    reconnect_count_before_idle = $reconnectBeforeIdle
    reconnect_count_after_idle = $reconnectAfterIdle
    long_lived_session_age_ms = [int64]$controlAfterIdle.control.session_age_ms
    manager_duration_ms = $managerDurationMs
    manager_server_bound_ms = 18000
    client_bound_seconds = $TerminalTimeoutSeconds
    external_public_ip_observer_proof = $true
    external_public_ip_outcome = $externalPublicIpOutcome
    external_public_ip_changed = [bool]$externalPublicIpChanged
    external_public_ip_consensus = [bool]$externalPublicIpConsensus
    external_public_ip_before_observation_ms = $externalBeforeMs
    external_public_ip_after_observation_ms = $externalAfterMs
    device_timeline_proof = $true
    telephony_detach_research = $radioDetachResearch
    device_timeline = [ordered]@{
        origin = 'REMOTE_COMMAND_RECEIVED'
        operation_id = [int64]$operationTiming.operation_id
        operation_age_ms = [int64]$operationTiming.operation_age_ms
        operation_reserved_ms = [int64]$operationTiming.operation_reserved_ms
        accepted_sent_ms = [int64]$operationTiming.accepted_sent_ms
        reconnect_started_ms = if ($null -eq $operationTiming.reconnect_started_ms) { $null } else { [int64]$operationTiming.reconnect_started_ms }
        reconnect_ready_ms = if ($null -eq $operationTiming.reconnect_ready_ms) { $null } else { [int64]$operationTiming.reconnect_ready_ms }
        rotation_terminal_control_state = [string]$operationTiming.rotation_terminal_control_state
        post_terminal_connect_started_ms = if ($null -eq $operationTiming.post_terminal_connect_started_ms) { $null } else { [int64]$operationTiming.post_terminal_connect_started_ms }
        post_terminal_connect_attempts = [int64]$operationTiming.post_terminal_connect_attempts
        post_terminal_transport_connected_ms = if ($null -eq $operationTiming.post_terminal_transport_connected_ms) { $null } else { [int64]$operationTiming.post_terminal_transport_connected_ms }
        post_terminal_transport_connections = [int64]$operationTiming.post_terminal_transport_connections
        rotation_origin_from_command_ms = $rotationOriginFromCommandMs
        rotation_terminal_ms = [int64]$operationTiming.rotation_terminal_ms
        result_sent_ms = [int64]$operationTiming.result_sent_ms
        result_ack_ms = [int64]$operationTiming.result_ack_ms
        rotation_terminal_from_command_ms = $rotationTerminalFromCommandMs
        rotation = [ordered]@{
            activated_ms = [int64]$rotationTiming.activated_ms
            pre_rotation_probe_started_ms = [int64]$rotationTiming.pre_rotation_probe_started_ms
            pre_rotation_probe_completed_ms = [int64]$rotationTiming.pre_rotation_probe_completed_ms
            airplane_enable_started_ms = [int64]$rotationTiming.airplane_enable_started_ms
            airplane_enable_effect_completed_ms = [int64]$rotationTiming.airplane_enable_effect_completed_ms
            airplane_on_observed_ms = [int64]$rotationTiming.airplane_on_observed_ms
            cellular_loss_observed_ms = [int64]$rotationTiming.cellular_loss_observed_ms
            radio_power_off_observed_ms = [int64]$rotationTiming.radio_power_off_observed_ms
            airplane_disable_started_ms = [int64]$rotationTiming.airplane_disable_started_ms
            airplane_disable_effect_completed_ms = [int64]$rotationTiming.airplane_disable_effect_completed_ms
            airplane_off_observed_ms = [int64]$rotationTiming.airplane_off_observed_ms
            cellular_request_rearm_started_ms = [int64]$rotationTiming.cellular_request_rearm_started_ms
            cellular_request_rearm_completed_ms = [int64]$rotationTiming.cellular_request_rearm_completed_ms
            first_platform_cellular_observation_ms = [int64]$rotationTiming.first_platform_cellular_observation_ms
            platform_cellular_observations_after_rearm = [int64]$rotationTiming.platform_cellular_observations_after_rearm
            fresh_cellular_observed_ms = [int64]$rotationTiming.fresh_cellular_observed_ms
            fresh_cellular_generation = [int64]$rotationTiming.fresh_cellular_generation
            root_authorized_ms = [int64]$rotationTiming.root_authorized_ms
            root_authorized_generation = [int64]$rotationTiming.root_authorized_generation
            post_rotation_probe_started_ms = [int64]$rotationTiming.post_rotation_probe_started_ms
            post_rotation_probe_completed_ms = [int64]$rotationTiming.post_rotation_probe_completed_ms
            terminal_ms = [int64]$rotationTiming.terminal_ms
        }
    }
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

Write-Host 'MISH_U8_REMOTE_CONTROL=PASS'
Write-Host 'MISH_U8_REMOTE_CONTROL_CLASSIFICATION=U8_REMOTE_CONTROL_ROTATION_PASS'
Write-Host "MISH_U8_REMOTE_CONTROL_OPERATION_ID=$operationId"
Write-Host "MISH_U8_REMOTE_CONTROL_TERMINAL=$terminalResult"
Write-Host 'MISH_U8_REMOTE_CONTROL_INVALID_AUTHENTICATED_REQUEST=400_ZERO_MUTATION'
Write-Host 'MISH_U8_REMOTE_CONTROL_LOGICAL_ROTATION_REQUESTS=1'
Write-Host 'MISH_U8_REMOTE_CONTROL_PUBLIC_COMMANDS=1'
Write-Host 'MISH_U8_REMOTE_CONTROL_SERVER_REQUEST_ID=PASS'
Write-Host 'MISH_U8_REMOTE_CONTROL_MANAGER_POLLING=0'
Write-Host "MISH_U8_REMOTE_CONTROL_IDLE_LIVENESS=PASS/heartbeat_delta=$heartbeatDelta/reconnect_delta=$($reconnectAfterIdle - $reconnectBeforeIdle)"
Write-Host "MISH_U8_REMOTE_CONTROL_MANAGER_DURATION_MS=$managerDurationMs"
Write-Host "MISH_U8_REMOTE_CONTROL_DEVICE_TIMELINE=PASS/terminal_from_command_ms=$rotationTerminalFromCommandMs/result_ack_ms=$([int64]$operationTiming.result_ack_ms)"
Write-Host "MISH_U8_REMOTE_CONTROL_EXTERNAL_PUBLIC_IP=PASS/outcome=$externalPublicIpOutcome/consensus=$externalPublicIpConsensus"
if ($CollectTelephonyDetachEvidence) {
    Write-Host "MISH_U8_REMOTE_CONTROL_TELEPHONY_DETACH=PASS/power_off=$([bool]$radioDetachResearch.power_off_observed)/vs_disable=$([string]$radioDetachResearch.power_off_vs_airplane_disable_started)"
}
Write-Host 'MISH_U8_REMOTE_CONTROL_RAW_IP_PERSISTED=false'
Write-Host 'MISH_U8_REMOTE_CONTROL_SECRETS_PERSISTED=false'
Write-Host "MISH_U8_REMOTE_CONTROL_EVIDENCE=$fullPath"
}
finally {
    if ($telephonyObservationStarted) {
        try {
            [void](Stop-MishTelephonyDetachObservation -AdbPath $AdbPath -PackageName $PackageName -EvidencePath $TelephonyDetachEvidencePath)
        }
        catch {
            Write-Warning 'Typed telephony observer cleanup failed after the primary remote-control result.'
        }
        $telephonyObservationStarted = $false
    }
    $beforeAddress = $null
    $afterAddress = $null
    Close-MishPublicEgressObservationContext -Context $observationContext
    $observationContext = $null
    $publicSpki = $null
    $env:MISH_MANAGER_TOKEN = $null
}
