[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $AdbPath,
    [Parameter(Mandatory)][string] $PackageName,
    [Parameter(Mandatory)][string] $ExpectedInstalledApkSha256,
    [Parameter(Mandatory)][string] $ExpectedSourceSha,
    [Parameter(Mandatory)][string] $EvidencePath,
    [string] $TargetHost = 'example.com',
    [ValidateRange(1, 65535)][int] $TargetPort = 80,
    [ValidateRange(250, 15000)][int] $TimeoutMs = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-MishProtocolParityProbe {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_PROTOCOL_PARITY_FAILURE|$Category|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments)

    $output = @(& $AdbPath @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) {
        Stop-MishProtocolParityProbe 'ADB_FAILED' 'Canonical ADB command failed.'
    }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Test-MishMeshAddress {
    param([Parameter(Mandatory)][string] $Address)
    try {
        $bytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
    }
    catch { return $false }
    if ($bytes.Length -ne 4 -or $bytes[0] -ne 100) { return $false }
    return ([int]$bytes[1] -ge 96 -and [int]$bytes[1] -le 111)
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishProtocolParityProbe 'ADB_MISSING' 'Canonical ADB executable is missing.'
}
if ($ExpectedInstalledApkSha256 -notmatch '^[0-9a-f]{64}$') {
    Stop-MishProtocolParityProbe 'INPUT_INVALID' 'Expected installed APK SHA-256 is invalid.'
}
if ($ExpectedSourceSha -notmatch '^[0-9a-f]{40}$') {
    Stop-MishProtocolParityProbe 'INPUT_INVALID' 'Expected source SHA is invalid.'
}

Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DiagnosticConnectProbe.psm1') -Force

$pidBefore = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
if ([string]::IsNullOrWhiteSpace($pidBefore) -or $pidBefore -match '\s') {
    Stop-MishProtocolParityProbe 'PRODUCT_PROCESS_NOT_RUNNING' 'Exactly one PRODUCT process is required.'
}

$packagePathOutput = Invoke-MishAdbText -Arguments @('shell', 'pm', 'path', $PackageName)
$packagePaths = @(
    $packagePathOutput -split '\r?\n' |
        Where-Object { $_ -match '^package:(?<path>.+/base\.apk)$' } |
        ForEach-Object { [regex]::Match($_, '^package:(?<path>.+/base\.apk)$').Groups['path'].Value }
)
if ($packagePaths.Count -ne 1) {
    Stop-MishProtocolParityProbe 'PACKAGE_IDENTITY_UNAVAILABLE' 'Exactly one installed base.apk is required.'
}

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
if ([string]::IsNullOrWhiteSpace($tempRoot)) {
    Stop-MishProtocolParityProbe 'TEMP_UNAVAILABLE' 'Temporary storage is unavailable.'
}
$pulledApk = Join-Path ([IO.Path]::GetFullPath($tempRoot)) ('mish-protocol-parity-' + [Guid]::NewGuid().ToString('N') + '.apk')
$credentialStorePath = Join-Path ([IO.Path]::GetFullPath($tempRoot)) ('mish-protocol-parity-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
$lease = $null

try {
    $pullOutput = @(& $AdbPath pull $packagePaths[0] $pulledApk 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $pulledApk -PathType Leaf)) {
        Stop-MishProtocolParityProbe 'PACKAGE_IDENTITY_UNAVAILABLE' 'Installed base.apk could not be read.'
    }
    $installedApkSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $pulledApk).Hash.ToLowerInvariant()
    if ($installedApkSha256 -cne $ExpectedInstalledApkSha256) {
        Stop-MishProtocolParityProbe 'PACKAGE_IDENTITY_MISMATCH' 'Installed PRODUCT bytes do not match the accepted U2 candidate.'
    }

    $addressOutput = Invoke-MishAdbText -Arguments @('shell', 'ip', '-o', '-4', 'addr', 'show')
    $meshAddresses = @(
        [regex]::Matches($addressOutput, '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/\d+') |
            ForEach-Object { $_.Groups['ip'].Value } |
            Where-Object { Test-MishMeshAddress $_ } |
            Sort-Object -Unique
    )
    if ($meshAddresses.Count -ne 1) {
        Stop-MishProtocolParityProbe 'MESH_ENDPOINT_NOT_UNIQUE' "Expected one Mesh address; observed $($meshAddresses.Count)."
    }
    $meshAddress = [string]$meshAddresses[0]
    try {
        $route = @(Find-NetRoute -RemoteIPAddress $meshAddress -ErrorAction Stop) | Select-Object -First 1
    }
    catch {
        Stop-MishProtocolParityProbe 'WINDOWS_MESH_ROUTE_UNAVAILABLE' 'Windows has no route to the admitted Mesh endpoint.'
    }
    if ($null -eq $route) {
        Stop-MishProtocolParityProbe 'WINDOWS_MESH_ROUTE_UNAVAILABLE' 'Windows has no route to the admitted Mesh endpoint.'
    }

    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
    if ($null -eq $lease) {
        Stop-MishProtocolParityProbe 'CREDENTIAL_LEASE_UNAVAILABLE' 'Credential lease is unavailable.'
    }

    $probes = [ordered]@{
        http_3128_positive = Invoke-MishDiagnosticHttpRelayProbe -ProxyHost $meshAddress -ProxyPort 3128 -ProxyUserName $lease.ProxyUserName -ProxyPassword $lease.ProxyPassword -TargetHost $TargetHost -TargetPort $TargetPort -TimeoutMs $TimeoutMs
        http_3128_negative_auth = Invoke-MishDiagnosticHttpRelayProbe -ProxyHost $meshAddress -ProxyPort 3128 -ProxyUserName $lease.ProxyUserName -ProxyPassword $lease.ProxyPassword -TargetHost $TargetHost -TargetPort $TargetPort -TimeoutMs $TimeoutMs -ExpectAuthRejection
        socks5_1081_positive = Invoke-MishDiagnosticSocks5RelayProbe -ProxyHost $meshAddress -ProxyPort 1081 -ProxyUserName $lease.ProxyUserName -ProxyPassword $lease.ProxyPassword -TargetHost $TargetHost -TargetPort $TargetPort -TimeoutMs $TimeoutMs
        socks5_1081_negative_auth = Invoke-MishDiagnosticSocks5RelayProbe -ProxyHost $meshAddress -ProxyPort 1081 -ProxyUserName $lease.ProxyUserName -ProxyPassword $lease.ProxyPassword -TargetHost $TargetHost -TargetPort $TargetPort -TimeoutMs $TimeoutMs -ExpectAuthRejection
        mixed_1080_http_positive = Invoke-MishDiagnosticHttpRelayProbe -ProxyHost $meshAddress -ProxyPort 1080 -ProxyUserName $lease.ProxyUserName -ProxyPassword $lease.ProxyPassword -TargetHost $TargetHost -TargetPort $TargetPort -TimeoutMs $TimeoutMs
        mixed_1080_http_negative_auth = Invoke-MishDiagnosticHttpRelayProbe -ProxyHost $meshAddress -ProxyPort 1080 -ProxyUserName $lease.ProxyUserName -ProxyPassword $lease.ProxyPassword -TargetHost $TargetHost -TargetPort $TargetPort -TimeoutMs $TimeoutMs -ExpectAuthRejection
        mixed_1080_socks5_positive = Invoke-MishDiagnosticSocks5RelayProbe -ProxyHost $meshAddress -ProxyPort 1080 -ProxyUserName $lease.ProxyUserName -ProxyPassword $lease.ProxyPassword -TargetHost $TargetHost -TargetPort $TargetPort -TimeoutMs $TimeoutMs
        mixed_1080_socks5_negative_auth = Invoke-MishDiagnosticSocks5RelayProbe -ProxyHost $meshAddress -ProxyPort 1080 -ProxyUserName $lease.ProxyUserName -ProxyPassword $lease.ProxyPassword -TargetHost $TargetHost -TargetPort $TargetPort -TimeoutMs $TimeoutMs -ExpectAuthRejection
    }

    $pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
    $pidStable = $pidAfter -ceq $pidBefore

    $failed = @(
        $probes.GetEnumerator() |
            Where-Object { [string]$_.Value.result -cne 'PASS' } |
            ForEach-Object { [string]$_.Key }
    )
    $acceptanceResult = if ($pidStable -and $failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $classification = if (-not $pidStable) {
        'INVALID_PROCESS_CHANGED_DURING_PROTOCOL_PARITY'
    } elseif ($failed.Count -ne 0) {
        'U2_PROTOCOL_PARITY_FAILED'
    } else {
        'U2_PROTOCOL_PARITY_PASS'
    }

    $evidence = [ordered]@{
        schema = 'mish.lab.protocol-parity/v1'
        collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        acceptance_result = $acceptanceResult
        classification = $classification
        expected_source_sha = $ExpectedSourceSha
        installed_apk_sha256 = $installedApkSha256
        exact_installed_bytes = $true
        package = $PackageName
        product_pid_stable = $pidStable
        mesh_endpoint_count = 1
        mesh_route_present = $true
        target = ($TargetHost + ':' + $TargetPort)
        probes = $probes
        failed_probes = $failed
    }

    $fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $fullEvidencePath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullEvidencePath,
        (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host "MISH_PROTOCOL_PARITY_ACCEPTANCE=$acceptanceResult"
    Write-Host "MISH_PROTOCOL_PARITY_CLASSIFICATION=$classification"
    Write-Host "MISH_PROTOCOL_PARITY_PID_STABLE=$pidStable"
    Write-Host "MISH_PROTOCOL_PARITY_FAILED_COUNT=$($failed.Count)"
    Write-Host "MISH_PROTOCOL_PARITY_EVIDENCE=$fullEvidencePath"

    if ($acceptanceResult -cne 'PASS') {
        throw "MISH_PROTOCOL_PARITY_RESULT|$acceptanceResult|$classification"
    }
}
finally {
    $lease = $null
    if (Test-Path -LiteralPath $credentialStorePath -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $pulledApk -PathType Leaf) {
        Remove-Item -LiteralPath $pulledApk -Force -ErrorAction SilentlyContinue
    }
}
