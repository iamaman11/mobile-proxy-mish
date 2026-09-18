[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstallReceiptPath,
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $AndroidSdkRoot = 'C:\mish-lab\tools\android-sdk',
    [string] $ReceiptPath = (Join-Path $env:TEMP 'mish-device-install-verification-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$schema = 'mish.device-install-verification/v2'

function Stop-Verification {
    param([Parameter(Mandatory)][string] $Category, [Parameter(Mandatory)][string] $Message)
    throw "MISH_DEVICE_INSTALL_VERIFY_FAILURE|$Category|$Message"
}

function Resolve-Executable {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Verification 'HOST_PREREQUISITE_MISSING' "Required executable is missing: $Path"
    }
    return [IO.Path]::GetFullPath($Path)
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments
    )
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Text = ($lines -join "`n") }
}

if (-not (Test-Path -LiteralPath $InstallReceiptPath -PathType Leaf)) {
    Stop-Verification 'INSTALL_RECEIPT_MISSING' 'Install receipt is missing.'
}
try {
    $install = Get-Content -Raw -LiteralPath $InstallReceiptPath | ConvertFrom-Json
}
catch {
    Stop-Verification 'INSTALL_RECEIPT_INVALID' 'Install receipt is not valid JSON.'
}
if ([string]$install.schema -cne 'mish.device-candidate-install/v2' -or
    [string]$install.result -cne 'PASS' -or -not [bool]$install.installed) {
    Stop-Verification 'INSTALL_NOT_CONFIRMED' 'Install receipt does not confirm a v2 successful replacement install.'
}

$applicationId = [string]$install.application_id
$sourceSha = [string]$install.source_sha
$hostedSha = [string]$install.hosted_product_apk_sha256
$expectedSha = [string]$install.lab_signed_product_apk_sha256
$expectedCert = [string]$install.lab_signing_certificate_sha256
if ($applicationId -notmatch '^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$') {
    Stop-Verification 'INSTALL_RECEIPT_INVALID' 'Application id is invalid.'
}
if ($sourceSha -notmatch '^[0-9a-f]{40}

$adb = Resolve-Executable $AdbPath
$apksigner = Resolve-Executable (Join-Path $AndroidSdkRoot 'build-tools\36.0.0\apksigner.bat')

$pathResult = Invoke-NativeCapture -FilePath $adb -Arguments @('shell', 'pm', 'path', $applicationId)
if ($pathResult.ExitCode -ne 0) {
    Stop-Verification 'PACKAGE_PATH_UNAVAILABLE' 'pm path failed for the installed package.'
}
$basePaths = @(
    $pathResult.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^package:(?<path>.+/base\.apk)$' } |
        ForEach-Object { [regex]::Match($_, '^package:(?<path>.+/base\.apk)$').Groups['path'].Value }
)
if ($basePaths.Count -ne 1) {
    Stop-Verification 'PACKAGE_PATH_AMBIGUOUS' 'Exactly one installed base.apk path is required.'
}

$tempRoot = Join-Path $env:TEMP ('mish-installed-apk-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$pulledApk = Join-Path $tempRoot 'base.apk'
try {
    $pullResult = Invoke-NativeCapture -FilePath $adb -Arguments @('pull', $basePaths[0], $pulledApk)
    if ($pullResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pulledApk -PathType Leaf)) {
        Stop-Verification 'INSTALLED_APK_PULL_FAILED' 'Installed base.apk could not be copied for verification.'
    }

    $installedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $pulledApk).Hash.ToLowerInvariant()
    if ($installedSha -cne $expectedSha) {
        Stop-Verification 'INSTALLED_APK_DIGEST_MISMATCH' 'Installed base.apk bytes do not match the signed exact candidate.'
    }

    $certResult = Invoke-NativeCapture -FilePath $apksigner -Arguments @('verify', '--print-certs', $pulledApk)
    if ($certResult.ExitCode -ne 0) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed base.apk signature verification failed.'
    }
    $certMatch = [regex]::Match($certResult.Text, '(?im)^Signer #1 certificate SHA-256 digest:\s*([0-9a-f:]{64,95})\s*$')
    if (-not $certMatch.Success) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed signing certificate digest could not be parsed.'
    }
    $installedCert = $certMatch.Groups[1].Value.Replace(':', '').ToLowerInvariant()
    if ($installedCert -cne $expectedCert) {
        Stop-Verification 'INSTALLED_APK_CERT_MISMATCH' 'Installed APK signing identity does not match the LAB signing identity.'
    }

    $receipt = [ordered]@{
        schema = $schema
        result = 'PASS'
        source_sha = $sourceSha
        application_id = $applicationId
        hosted_product_apk_sha256 = $hostedSha
        lab_signed_product_apk_sha256 = $expectedSha
        installed_apk_sha256 = $installedSha
        signing_certificate_sha256 = $installedCert
        hosted_to_lab_signed_lineage_verified = $true
        installed_matches_lab_signed_candidate = $true
        exact_installed_bytes_verified = $true
    }
    $fullReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    $parent = Split-Path -Parent $fullReceiptPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullReceiptPath,
        (($receipt | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host 'MISH_DEVICE_INSTALL_VERIFY=PASS'
    Write-Host "MISH_DEVICE_INSTALL_VERIFY_RECEIPT=$fullReceiptPath"
    $receipt | ConvertTo-Json -Depth 5 -Compress
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}
 -or
    $hostedSha -notmatch '^[0-9a-f]{64}

$adb = Resolve-Executable $AdbPath
$apksigner = Resolve-Executable (Join-Path $AndroidSdkRoot 'build-tools\36.0.0\apksigner.bat')

$pathResult = Invoke-NativeCapture -FilePath $adb -Arguments @('shell', 'pm', 'path', $applicationId)
if ($pathResult.ExitCode -ne 0) {
    Stop-Verification 'PACKAGE_PATH_UNAVAILABLE' 'pm path failed for the installed package.'
}
$basePaths = @(
    $pathResult.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^package:(?<path>.+/base\.apk)$' } |
        ForEach-Object { [regex]::Match($_, '^package:(?<path>.+/base\.apk)$').Groups['path'].Value }
)
if ($basePaths.Count -ne 1) {
    Stop-Verification 'PACKAGE_PATH_AMBIGUOUS' 'Exactly one installed base.apk path is required.'
}

$tempRoot = Join-Path $env:TEMP ('mish-installed-apk-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$pulledApk = Join-Path $tempRoot 'base.apk'
try {
    $pullResult = Invoke-NativeCapture -FilePath $adb -Arguments @('pull', $basePaths[0], $pulledApk)
    if ($pullResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pulledApk -PathType Leaf)) {
        Stop-Verification 'INSTALLED_APK_PULL_FAILED' 'Installed base.apk could not be copied for verification.'
    }

    $installedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $pulledApk).Hash.ToLowerInvariant()
    if ($installedSha -cne $expectedSha) {
        Stop-Verification 'INSTALLED_APK_DIGEST_MISMATCH' 'Installed base.apk bytes do not match the signed exact candidate.'
    }

    $certResult = Invoke-NativeCapture -FilePath $apksigner -Arguments @('verify', '--print-certs', $pulledApk)
    if ($certResult.ExitCode -ne 0) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed base.apk signature verification failed.'
    }
    $certMatch = [regex]::Match($certResult.Text, '(?im)^Signer #1 certificate SHA-256 digest:\s*([0-9a-f:]{64,95})\s*$')
    if (-not $certMatch.Success) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed signing certificate digest could not be parsed.'
    }
    $installedCert = $certMatch.Groups[1].Value.Replace(':', '').ToLowerInvariant()
    if ($installedCert -cne $expectedCert) {
        Stop-Verification 'INSTALLED_APK_CERT_MISMATCH' 'Installed APK signing identity does not match the LAB signing identity.'
    }

    $receipt = [ordered]@{
        schema = $schema
        result = 'PASS'
        application_id = $applicationId
        installed_apk_sha256 = $installedSha
        signing_certificate_sha256 = $installedCert
        exact_bytes_verified = $true
    }
    $fullReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    $parent = Split-Path -Parent $fullReceiptPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullReceiptPath,
        (($receipt | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host 'MISH_DEVICE_INSTALL_VERIFY=PASS'
    Write-Host "MISH_DEVICE_INSTALL_VERIFY_RECEIPT=$fullReceiptPath"
    $receipt | ConvertTo-Json -Depth 5 -Compress
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}
 -or
    $expectedSha -notmatch '^[0-9a-f]{64}

$adb = Resolve-Executable $AdbPath
$apksigner = Resolve-Executable (Join-Path $AndroidSdkRoot 'build-tools\36.0.0\apksigner.bat')

$pathResult = Invoke-NativeCapture -FilePath $adb -Arguments @('shell', 'pm', 'path', $applicationId)
if ($pathResult.ExitCode -ne 0) {
    Stop-Verification 'PACKAGE_PATH_UNAVAILABLE' 'pm path failed for the installed package.'
}
$basePaths = @(
    $pathResult.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^package:(?<path>.+/base\.apk)$' } |
        ForEach-Object { [regex]::Match($_, '^package:(?<path>.+/base\.apk)$').Groups['path'].Value }
)
if ($basePaths.Count -ne 1) {
    Stop-Verification 'PACKAGE_PATH_AMBIGUOUS' 'Exactly one installed base.apk path is required.'
}

$tempRoot = Join-Path $env:TEMP ('mish-installed-apk-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$pulledApk = Join-Path $tempRoot 'base.apk'
try {
    $pullResult = Invoke-NativeCapture -FilePath $adb -Arguments @('pull', $basePaths[0], $pulledApk)
    if ($pullResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pulledApk -PathType Leaf)) {
        Stop-Verification 'INSTALLED_APK_PULL_FAILED' 'Installed base.apk could not be copied for verification.'
    }

    $installedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $pulledApk).Hash.ToLowerInvariant()
    if ($installedSha -cne $expectedSha) {
        Stop-Verification 'INSTALLED_APK_DIGEST_MISMATCH' 'Installed base.apk bytes do not match the signed exact candidate.'
    }

    $certResult = Invoke-NativeCapture -FilePath $apksigner -Arguments @('verify', '--print-certs', $pulledApk)
    if ($certResult.ExitCode -ne 0) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed base.apk signature verification failed.'
    }
    $certMatch = [regex]::Match($certResult.Text, '(?im)^Signer #1 certificate SHA-256 digest:\s*([0-9a-f:]{64,95})\s*$')
    if (-not $certMatch.Success) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed signing certificate digest could not be parsed.'
    }
    $installedCert = $certMatch.Groups[1].Value.Replace(':', '').ToLowerInvariant()
    if ($installedCert -cne $expectedCert) {
        Stop-Verification 'INSTALLED_APK_CERT_MISMATCH' 'Installed APK signing identity does not match the LAB signing identity.'
    }

    $receipt = [ordered]@{
        schema = $schema
        result = 'PASS'
        application_id = $applicationId
        installed_apk_sha256 = $installedSha
        signing_certificate_sha256 = $installedCert
        exact_bytes_verified = $true
    }
    $fullReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    $parent = Split-Path -Parent $fullReceiptPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullReceiptPath,
        (($receipt | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host 'MISH_DEVICE_INSTALL_VERIFY=PASS'
    Write-Host "MISH_DEVICE_INSTALL_VERIFY_RECEIPT=$fullReceiptPath"
    $receipt | ConvertTo-Json -Depth 5 -Compress
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}
 -or
    $expectedCert -notmatch '^[0-9a-f]{64}

$adb = Resolve-Executable $AdbPath
$apksigner = Resolve-Executable (Join-Path $AndroidSdkRoot 'build-tools\36.0.0\apksigner.bat')

$pathResult = Invoke-NativeCapture -FilePath $adb -Arguments @('shell', 'pm', 'path', $applicationId)
if ($pathResult.ExitCode -ne 0) {
    Stop-Verification 'PACKAGE_PATH_UNAVAILABLE' 'pm path failed for the installed package.'
}
$basePaths = @(
    $pathResult.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^package:(?<path>.+/base\.apk)$' } |
        ForEach-Object { [regex]::Match($_, '^package:(?<path>.+/base\.apk)$').Groups['path'].Value }
)
if ($basePaths.Count -ne 1) {
    Stop-Verification 'PACKAGE_PATH_AMBIGUOUS' 'Exactly one installed base.apk path is required.'
}

$tempRoot = Join-Path $env:TEMP ('mish-installed-apk-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$pulledApk = Join-Path $tempRoot 'base.apk'
try {
    $pullResult = Invoke-NativeCapture -FilePath $adb -Arguments @('pull', $basePaths[0], $pulledApk)
    if ($pullResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pulledApk -PathType Leaf)) {
        Stop-Verification 'INSTALLED_APK_PULL_FAILED' 'Installed base.apk could not be copied for verification.'
    }

    $installedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $pulledApk).Hash.ToLowerInvariant()
    if ($installedSha -cne $expectedSha) {
        Stop-Verification 'INSTALLED_APK_DIGEST_MISMATCH' 'Installed base.apk bytes do not match the signed exact candidate.'
    }

    $certResult = Invoke-NativeCapture -FilePath $apksigner -Arguments @('verify', '--print-certs', $pulledApk)
    if ($certResult.ExitCode -ne 0) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed base.apk signature verification failed.'
    }
    $certMatch = [regex]::Match($certResult.Text, '(?im)^Signer #1 certificate SHA-256 digest:\s*([0-9a-f:]{64,95})\s*$')
    if (-not $certMatch.Success) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed signing certificate digest could not be parsed.'
    }
    $installedCert = $certMatch.Groups[1].Value.Replace(':', '').ToLowerInvariant()
    if ($installedCert -cne $expectedCert) {
        Stop-Verification 'INSTALLED_APK_CERT_MISMATCH' 'Installed APK signing identity does not match the LAB signing identity.'
    }

    $receipt = [ordered]@{
        schema = $schema
        result = 'PASS'
        application_id = $applicationId
        installed_apk_sha256 = $installedSha
        signing_certificate_sha256 = $installedCert
        exact_bytes_verified = $true
    }
    $fullReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    $parent = Split-Path -Parent $fullReceiptPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullReceiptPath,
        (($receipt | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host 'MISH_DEVICE_INSTALL_VERIFY=PASS'
    Write-Host "MISH_DEVICE_INSTALL_VERIFY_RECEIPT=$fullReceiptPath"
    $receipt | ConvertTo-Json -Depth 5 -Compress
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}
) {
    Stop-Verification 'INSTALL_RECEIPT_INVALID' 'Source, hosted APK, LAB-signed APK or signing digest is invalid.'
}

$adb = Resolve-Executable $AdbPath
$apksigner = Resolve-Executable (Join-Path $AndroidSdkRoot 'build-tools\36.0.0\apksigner.bat')

$pathResult = Invoke-NativeCapture -FilePath $adb -Arguments @('shell', 'pm', 'path', $applicationId)
if ($pathResult.ExitCode -ne 0) {
    Stop-Verification 'PACKAGE_PATH_UNAVAILABLE' 'pm path failed for the installed package.'
}
$basePaths = @(
    $pathResult.Text -split "`r?`n" |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -match '^package:(?<path>.+/base\.apk)$' } |
        ForEach-Object { [regex]::Match($_, '^package:(?<path>.+/base\.apk)$').Groups['path'].Value }
)
if ($basePaths.Count -ne 1) {
    Stop-Verification 'PACKAGE_PATH_AMBIGUOUS' 'Exactly one installed base.apk path is required.'
}

$tempRoot = Join-Path $env:TEMP ('mish-installed-apk-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$pulledApk = Join-Path $tempRoot 'base.apk'
try {
    $pullResult = Invoke-NativeCapture -FilePath $adb -Arguments @('pull', $basePaths[0], $pulledApk)
    if ($pullResult.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $pulledApk -PathType Leaf)) {
        Stop-Verification 'INSTALLED_APK_PULL_FAILED' 'Installed base.apk could not be copied for verification.'
    }

    $installedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $pulledApk).Hash.ToLowerInvariant()
    if ($installedSha -cne $expectedSha) {
        Stop-Verification 'INSTALLED_APK_DIGEST_MISMATCH' 'Installed base.apk bytes do not match the signed exact candidate.'
    }

    $certResult = Invoke-NativeCapture -FilePath $apksigner -Arguments @('verify', '--print-certs', $pulledApk)
    if ($certResult.ExitCode -ne 0) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed base.apk signature verification failed.'
    }
    $certMatch = [regex]::Match($certResult.Text, '(?im)^Signer #1 certificate SHA-256 digest:\s*([0-9a-f:]{64,95})\s*$')
    if (-not $certMatch.Success) {
        Stop-Verification 'INSTALLED_APK_SIGNATURE_INVALID' 'Installed signing certificate digest could not be parsed.'
    }
    $installedCert = $certMatch.Groups[1].Value.Replace(':', '').ToLowerInvariant()
    if ($installedCert -cne $expectedCert) {
        Stop-Verification 'INSTALLED_APK_CERT_MISMATCH' 'Installed APK signing identity does not match the LAB signing identity.'
    }

    $receipt = [ordered]@{
        schema = $schema
        result = 'PASS'
        application_id = $applicationId
        installed_apk_sha256 = $installedSha
        signing_certificate_sha256 = $installedCert
        exact_bytes_verified = $true
    }
    $fullReceiptPath = [IO.Path]::GetFullPath($ReceiptPath)
    $parent = Split-Path -Parent $fullReceiptPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullReceiptPath,
        (($receipt | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host 'MISH_DEVICE_INSTALL_VERIFY=PASS'
    Write-Host "MISH_DEVICE_INSTALL_VERIFY_RECEIPT=$fullReceiptPath"
    $receipt | ConvertTo-Json -Depth 5 -Compress
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}
