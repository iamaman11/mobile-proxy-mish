[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-cellular-primitive-capabilities-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.cellular-primitive-capabilities/v1'

function Stop-MishCapabilityAudit {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_CELLULAR_CAPABILITY_FAILURE|$Category|$Message"
}

function Invoke-MishAdbCapture {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode) { $exitCode = -1 }
    [pscustomobject]@{
        ExitCode = [int]$exitCode
        Text = ($rows -join [Environment]::NewLine).Trim()
    }
}

function Get-MishRequiredText {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [Parameter(Mandatory)][string] $Operation
    )

    $capture = Invoke-MishAdbCapture -Arguments $Arguments
    if ($capture.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($capture.Text)) {
        Stop-MishCapabilityAudit 'READ_FAILED' "Read-only operation '$Operation' failed."
    }
    return $capture.Text.Trim()
}

function Convert-MishBinarySetting {
    param([string] $Value)

    switch (($Value ?? '').Trim()) {
        '0' { return 'DISABLED' }
        '1' { return 'ENABLED' }
        default { return 'UNKNOWN' }
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishCapabilityAudit 'ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

$devices = @(& $AdbPath devices | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {
    Stop-MishCapabilityAudit 'DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.'
}

$model = Get-MishRequiredText -Arguments @('shell','getprop','ro.product.model') -Operation 'model'
$api = Get-MishRequiredText -Arguments @('shell','getprop','ro.build.version.sdk') -Operation 'API'
$abi = Get-MishRequiredText -Arguments @('shell','getprop','ro.product.cpu.abi') -Operation 'ABI'
$buildType = Get-MishRequiredText -Arguments @('shell','getprop','ro.build.type') -Operation 'build type'

if ($model -cne 'SM-A022G' -or $api -cne '30' -or $abi -cne 'armeabi-v7a') {
    Stop-MishCapabilityAudit 'DEVICE_IDENTITY_MISMATCH' "Expected SM-A022G/API30/armeabi-v7a; observed $model/API$api/$abi."
}

# Capability discovery is intentionally read-only. Help text is inspected only in memory and is
# never persisted because vendor output is not part of the evidence contract.
$rootIdentity = Invoke-MishAdbCapture -Arguments @('shell','su','-c','id -u')
$rootAvailable = $rootIdentity.ExitCode -eq 0 -and $rootIdentity.Text.Trim() -ceq '0'

$svcHelp = if ($rootAvailable) {
    Invoke-MishAdbCapture -Arguments @('shell','su','-c','svc help')
} else {
    [pscustomobject]@{ ExitCode = -1; Text = '' }
}

$phoneHelp = if ($rootAvailable) {
    Invoke-MishAdbCapture -Arguments @('shell','su','-c','cmd phone help')
} else {
    [pscustomobject]@{ ExitCode = -1; Text = '' }
}

$svcDataAvailable = (
    $rootAvailable -and
    $svcHelp.ExitCode -eq 0 -and
    $svcHelp.Text -match '(?im)^\s*data(?:\s|:)'
)

$cmdPhoneAvailable = $rootAvailable -and $phoneHelp.ExitCode -eq 0
$cmdPhoneDataAdvertised = (
    $cmdPhoneAvailable -and
    $phoneHelp.Text -match '(?im)^\s*data(?:\s|:)'
)
$cmdPhoneRadioAdvertised = (
    $cmdPhoneAvailable -and
    $phoneHelp.Text -match '(?im)^\s*radio(?:\s|:)'
)
$cmdPhoneRestartModemAdvertised = (
    $cmdPhoneAvailable -and
    $phoneHelp.Text -match '(?im)^\s*restart-modem(?:\s|:)'
)

$airplaneCapture = Invoke-MishAdbCapture -Arguments @(
    'shell','settings','get','global','airplane_mode_on'
)
$mobileDataCapture = Invoke-MishAdbCapture -Arguments @(
    'shell','settings','get','global','mobile_data'
)

$airplaneSetting = if ($airplaneCapture.ExitCode -eq 0) {
    Convert-MishBinarySetting -Value $airplaneCapture.Text
} else {
    'UNKNOWN'
}
$mobileDataSetting = if ($mobileDataCapture.ExitCode -eq 0) {
    Convert-MishBinarySetting -Value $mobileDataCapture.Text
} else {
    'UNKNOWN'
}

$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'PASS'
    classification = 'CELLULAR_PRIMITIVE_CAPABILITY_AUDIT_PASS'
    device = [ordered]@{
        model = $model
        api = [int]$api
        abi = $abi
        build_type = $buildType
    }
    authority = [ordered]@{
        existing_root_readonly_available = [bool]$rootAvailable
    }
    command_surfaces = [ordered]@{
        svc_data_available = [bool]$svcDataAvailable
        cmd_phone_available = [bool]$cmdPhoneAvailable
        cmd_phone_data_advertised = [bool]$cmdPhoneDataAdvertised
        cmd_phone_radio_advertised = [bool]$cmdPhoneRadioAdvertised
        cmd_phone_restart_modem_advertised = [bool]$cmdPhoneRestartModemAdvertised
    }
    initial_settings = [ordered]@{
        airplane_mode = $airplaneSetting
        mobile_data = $mobileDataSetting
    }
    mutation = [ordered]@{
        product_mutation_performed = $false
        data_mutation_performed = $false
        radio_mutation_performed = $false
        modem_mutation_performed = $false
        rotation_triggered = $false
        app_restart_performed = $false
        install_performed = $false
    }
    raw_command_help_persisted = $false
    raw_public_ip_persisted = $false
    subscription_id_persisted = $false
    operator_identity_persisted = $false
    secrets_persisted_in_evidence = $false
    architecture_decision = 'NOT_MADE'
}

$fullPath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullPath,
    (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_CELLULAR_PRIMITIVE_CAPABILITY_AUDIT=PASS'
Write-Host "MISH_CELLULAR_CAPABILITY_ROOT=$rootAvailable"
Write-Host "MISH_CELLULAR_CAPABILITY_SVC_DATA=$svcDataAvailable"
Write-Host "MISH_CELLULAR_CAPABILITY_CMD_PHONE_DATA=$cmdPhoneDataAdvertised"
Write-Host "MISH_CELLULAR_CAPABILITY_CMD_PHONE_RADIO=$cmdPhoneRadioAdvertised"
Write-Host "MISH_CELLULAR_CAPABILITY_RESTART_MODEM=$cmdPhoneRestartModemAdvertised"
Write-Host 'MISH_CELLULAR_CAPABILITY_MUTATION=false'
Write-Host "MISH_CELLULAR_CAPABILITY_EVIDENCE=$fullPath"
