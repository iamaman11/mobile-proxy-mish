[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-control-diagnostic-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:NativeSchema = 'mish.control.diagnostics/v1'
$script:EvidenceSchema = 'mish.lab.control-diagnostic/v1'

function Stop-MishControlDiagnostic {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_CONTROL_DIAGNOSTIC_FAILURE|$Category|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        Stop-MishControlDiagnostic 'ADB_FAILED' "ADB command failed with exit code $exitCode."
    }
    return ($rows -join [Environment]::NewLine).Trim()
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishControlDiagnostic 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

$pidBefore = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
if ([string]::IsNullOrWhiteSpace($pidBefore) -or $pidBefore -match '\s') {
    Stop-MishControlDiagnostic 'PRODUCT_PROCESS_NOT_RUNNING' 'Exactly one already-running PRODUCT process is required.'
}

$capture = Invoke-MishAdbText -Arguments @(
    'shell', 'content', 'call',
    '--uri', "content://$PackageName.diagnostics",
    '--method', 'control_snapshot_v1'
)
$payloadMatch = [regex]::Match($capture, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
if (-not $payloadMatch.Success) {
    Stop-MishControlDiagnostic 'CONTROL_SNAPSHOT_INVALID' 'CONTROL diagnostics bridge returned no payload.'
}

$bytes = $null
try {
    $bytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
    $nativeJson = [Text.Encoding]::UTF8.GetString($bytes)
    $native = $nativeJson | ConvertFrom-Json
}
catch {
    Stop-MishControlDiagnostic 'CONTROL_SNAPSHOT_INVALID' 'CONTROL diagnostics payload is malformed.'
}
finally {
    if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
}

if ([string]$native.schema -cne $script:NativeSchema -or
    [string]$native.application_id -cne $PackageName) {
    Stop-MishControlDiagnostic 'CONTROL_SNAPSHOT_IDENTITY_MISMATCH' 'CONTROL diagnostics schema/package identity mismatch.'
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore
if (-not $pidStable) {
    Stop-MishControlDiagnostic 'PRODUCT_PID_CHANGED' 'PRODUCT process changed during the read-only CONTROL snapshot.'
}

$serialized = $native | ConvertTo-Json -Depth 12 -Compress
foreach ($forbidden in @('password', 'proxy_password', 'manager_token', 'public_key_spki_b64', 'request_id')) {
    if ($serialized -match ('(?i)"' + [regex]::Escape($forbidden) + '"')) {
        Stop-MishControlDiagnostic 'SENSITIVE_FIELD_PRESENT' "CONTROL snapshot contains forbidden persisted field: $forbidden."
    }
}

$evidence = [ordered]@{
    schema = $script:EvidenceSchema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    application_id = $PackageName
    pid = [int64]$pidBefore
    pid_stable = $true
    captured_elapsed_ms = [int64]$native.captured_elapsed_ms
    control = $native.control
    mutation_performed = $false
    raw_public_ip_persisted = $false
    secrets_persisted_in_evidence = $false
}

$fullPath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullPath,
    (($evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_CONTROL_DIAGNOSTIC=PASS'
Write-Host "MISH_CONTROL_DIAGNOSTIC_PID_STABLE=$pidStable"
Write-Host "MISH_CONTROL_DIAGNOSTIC_STATE=$([string]$native.control.state)"
Write-Host "MISH_CONTROL_DIAGNOSTIC_OPERATION_ID=$($native.control.operation_timing.operation_id)"
Write-Host "MISH_CONTROL_DIAGNOSTIC_EVIDENCE=$fullPath"
