[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Start', 'Snapshot', 'Stop')]
    [string] $Action,

    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-telephony-service-state-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NativeSchema = 'mish.debug.telephony-service-state/v1'
$script:EvidenceSchema = 'mish.lab.telephony-service-state/v1'

function Stop-MishTelephonyDiagnostic {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_TELEPHONY_DIAGNOSTIC_FAILURE|$Category|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        Stop-MishTelephonyDiagnostic 'ADB_FAILED' "ADB command failed with exit code $exitCode."
    }
    return ($rows -join [Environment]::NewLine).Trim()
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishTelephonyDiagnostic 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

$method = switch ($Action) {
    'Start' { 'telephony_service_state_start_v1' }
    'Snapshot' { 'telephony_service_state_snapshot_v1' }
    'Stop' { 'telephony_service_state_stop_v1' }
}

$capture = Invoke-MishAdbText -Arguments @(
    'shell', 'content', 'call',
    '--uri', "content://$PackageName.telephony-diagnostics",
    '--method', $method
)
$payloadMatch = [regex]::Match($capture, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
if (-not $payloadMatch.Success) {
    Stop-MishTelephonyDiagnostic 'SNAPSHOT_INVALID' 'Telephony diagnostics bridge returned no payload.'
}

$bytes = $null
try {
    $bytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
    $nativeJson = [Text.Encoding]::UTF8.GetString($bytes)
    $native = $nativeJson | ConvertFrom-Json
}
catch {
    Stop-MishTelephonyDiagnostic 'SNAPSHOT_INVALID' 'Telephony diagnostics payload is malformed.'
}
finally {
    if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
}

if ([string]$native.schema -cne $script:NativeSchema -or
    [string]$native.application_id -cne $PackageName -or
    [bool]$native.mutation_performed) {
    Stop-MishTelephonyDiagnostic 'IDENTITY_MISMATCH' 'Telephony diagnostics schema/package/mutation contract mismatch.'
}

$serialized = $native | ConvertTo-Json -Depth 8 -Compress
foreach ($forbidden in @(
    '"subscription_id":',
    '"operator":',
    '"operator_name":',
    '"cell_identity":',
    '"request_id":',
    '"public_ip":',
    '"manager_token":',
    '"password":'
)) {
    if ($serialized.Contains($forbidden, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-MishTelephonyDiagnostic 'SENSITIVE_FIELD_PRESENT' "Telephony diagnostics contains forbidden field $forbidden"
    }
}

if ($Action -eq 'Start') {
    if (-not [bool]$native.active -or [string]$native.status -cne 'STARTED') {
        Stop-MishTelephonyDiagnostic 'START_FAILED' 'Typed ServiceState observer did not enter active state.'
    }
    Write-Host 'MISH_TELEPHONY_DIAGNOSTIC_START=PASS'
    return
}

if ($Action -eq 'Stop') {
    if ([bool]$native.active -or [string]$native.status -cne 'STOPPED') {
        Stop-MishTelephonyDiagnostic 'STOP_FAILED' 'Typed ServiceState observer did not stop cleanly.'
    }
    Write-Host 'MISH_TELEPHONY_DIAGNOSTIC_STOP=PASS'
    return
}

$evidence = [ordered]@{
    schema = $script:EvidenceSchema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    application_id = $PackageName
    telephony = $native
    mutation_performed = $false
    adb_rotation_trigger_used = $false
    raw_subscription_id_persisted = $false
    operator_identity_persisted = $false
    cell_identity_persisted = $false
    raw_public_ip_persisted = $false
    secrets_persisted_in_evidence = $false
}
$fullPath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullPath,
    (($evidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_TELEPHONY_DIAGNOSTIC_SNAPSHOT=PASS'
Write-Host "MISH_TELEPHONY_DIAGNOSTIC_EVENTS=$([int]$native.event_count)"
Write-Host "MISH_TELEPHONY_DIAGNOSTIC_DROPPED=$([int]$native.dropped_events)"
Write-Host "MISH_TELEPHONY_DIAGNOSTIC_EVIDENCE=$fullPath"
