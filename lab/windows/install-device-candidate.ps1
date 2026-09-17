[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CandidateDirectory,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ExpectedPrNumber,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceSha,
    [string]$AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string]$AndroidSdkRoot = 'C:\mish-lab\tools\android-sdk',
    [string]$StateRoot = 'C:\mish-lab\runner\.state\device-candidate',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$schema = 'mish-device-candidate-v1'
$productName = 'mobile-proxy-mish-debug.apk'
$testName = 'mobile-proxy-mish-debug-androidTest.apk'
$applicationId = 'com.mobileproxymish.app.debug'
$testApplicationId = 'com.mobileproxymish.app.test'
$keystorePassword = 'mish-lab-device-candidate-v1'
$keyAlias = 'mish-lab-device-candidate-v1'
$legacyStateRoot = 'C:\mish-lab\runner\_work\.mish-device-candidate'

function Stop-Candidate {
    param([Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][string]$Message)
    throw "MISH_DEVICE_CANDIDATE_FAILURE|$Category|$Message"
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Candidate 'ARTIFACT_MISSING' "Required candidate file is missing: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    # Windows PowerShell 5.1 can promote native stderr to NativeCommandError when the caller
    # uses ErrorActionPreference=Stop. Capture stderr as ordinary bounded text so the installer
    # can classify the native exit code itself and always return a typed MISH failure.
    $previousErrorActionPreference = $ErrorActionPreference
    $lines = @()
    $exitCode = -1
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = ($lines -join "`n")
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )
    $result = Invoke-NativeCapture -FilePath $FilePath -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        Stop-Candidate $Category $Message
    }
    return $result
}

function Invoke-AdbInstallBounded {
    param(
        [Parameter(Mandatory)][string]$Adb,
        [Parameter(Mandatory)][string]$ApkPath,
        [switch]$TestOnly,
        [ValidateRange(10, 300)][int]$TimeoutSeconds = 90
    )

    $arguments = @('install', '-r')
    if ($TestOnly) { $arguments += '-t' }
    $arguments += $ApkPath

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Adb
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $arguments) {
        [void]$start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Stop-Candidate 'INSTALL_FAILED' 'adb install could not be started.'
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            try { [void]$process.WaitForExit(5000) } catch { }
            Stop-Candidate 'INSTALL_TIMEOUT' "adb install exceeded the bounded ${TimeoutSeconds}s timeout."
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Text = (($stdout, $stderr | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n").Trim()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Test-FullyQualifiedWindowsPath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path -match '^(?:[A-Za-z]:[\\/]|\\\\)'
}

function Resolve-Executable {
    param([Parameter(Mandatory)][string]$PathOrName)
    if (Test-FullyQualifiedWindowsPath $PathOrName) {
        if (-not (Test-Path -LiteralPath $PathOrName -PathType Leaf)) {
            Stop-Candidate 'HOST_PREREQUISITE_MISSING' "Required executable is missing: $PathOrName"
        }
        return [IO.Path]::GetFullPath($PathOrName)
    }
    $resolved = Get-Command $PathOrName -CommandType Application -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Stop-Candidate 'HOST_PREREQUISITE_MISSING' "Required executable is unavailable: $PathOrName"
    }
    return $resolved.Source
}

$root = [IO.Path]::GetFullPath($CandidateDirectory)
$manifestPath = Join-Path $root 'candidate.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Stop-Candidate 'ARTIFACT_MISSING' 'candidate.json is missing.'
}
try {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
}
catch {
    Stop-Candidate 'ARTIFACT_INVALID' 'candidate.json is not valid JSON.'
}

if ([string]$manifest.schema -ne $schema) {
    Stop-Candidate 'ARTIFACT_INVALID' 'Candidate schema mismatch.'
}
if ([int]$manifest.pr_number -ne $ExpectedPrNumber) {
    Stop-Candidate 'IDENTITY_MISMATCH' 'Candidate PR number mismatch.'
}
if ([string]$manifest.source_sha -ne $ExpectedSourceSha) {
    Stop-Candidate 'IDENTITY_MISMATCH' 'Candidate source SHA mismatch.'
}
if ([string]$manifest.base_sha -notmatch '^[0-9a-f]{40}$') {
    Stop-Candidate 'IDENTITY_MISMATCH' 'Candidate base SHA is invalid.'
}
if ([string]$manifest.application_id -ne $applicationId) {
    Stop-Candidate 'IDENTITY_MISMATCH' 'Candidate application ID is not the isolated debug package.'
}
if ([string]$manifest.target_abi -notin @('armeabi-v7a', 'arm64-v8a')) {
    Stop-Candidate 'IDENTITY_MISMATCH' 'Candidate ABI is unsupported.'
}
if ([string]$manifest.product_apk.name -ne $productName -or [string]$manifest.android_test_apk.name -ne $testName) {
    Stop-Candidate 'IDENTITY_MISMATCH' 'Candidate APK names are not canonical.'
}
if ([string]$manifest.product_apk.sha256 -notmatch '^[0-9a-f]{64}$' -or [string]$manifest.android_test_apk.sha256 -notmatch '^[0-9a-f]{64}$') {
    Stop-Candidate 'ARTIFACT_INVALID' 'Candidate APK digest is invalid.'
}

$productPath = Join-Path $root $productName
$testPath = Join-Path $root $testName
$productSha = Get-Sha256 $productPath
$testSha = Get-Sha256 $testPath
if ($productSha -ne [string]$manifest.product_apk.sha256) {
    Stop-Candidate 'DIGEST_MISMATCH' 'Product APK SHA-256 mismatch.'
}
if ($testSha -ne [string]$manifest.android_test_apk.sha256) {
    Stop-Candidate 'DIGEST_MISMATCH' 'AndroidTest APK SHA-256 mismatch.'
}

if ($VerifyOnly) {
    [pscustomobject]@{
        result = 'PASS'
        mode = 'verify-only'
        pr_number = $ExpectedPrNumber
        source_sha = $ExpectedSourceSha
        target_abi = [string]$manifest.target_abi
        product_apk_sha256 = $productSha
        android_test_apk_sha256 = $testSha
        local_build = $false
    } | ConvertTo-Json -Compress
    exit 0
}

$adb = Resolve-Executable $AdbPath
$buildTools = Join-Path $AndroidSdkRoot 'build-tools\36.0.0'
$apksigner = Resolve-Executable (Join-Path $buildTools 'apksigner.bat')
$keytool = if ($env:JAVA_HOME) { Join-Path $env:JAVA_HOME 'bin\keytool.exe' } else { 'keytool.exe' }
$keytool = Resolve-Executable $keytool

$deviceResult = Invoke-NativeCapture -FilePath $adb -Arguments @('devices')
if ($deviceResult.ExitCode -ne 0) {
    Stop-Candidate 'DEVICE_UNAVAILABLE' 'adb devices failed.'
}
$deviceRows = @(
    $deviceResult.Text -split "`r?`n" |
        Where-Object { $_ -match '^\S+\s+device\s*$' }
)
if ($deviceRows.Count -ne 1) {
    Stop-Candidate 'DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.'
}

$state = [IO.Path]::GetFullPath($StateRoot)
[IO.Directory]::CreateDirectory($state) | Out-Null
$keystore = Join-Path $state 'device-candidate.p12'
$legacyKeystore = Join-Path $legacyStateRoot 'device-candidate.p12'

if (Test-Path -LiteralPath $keystore -PathType Leaf) {
    if (Test-Path -LiteralPath $legacyKeystore -PathType Leaf) {
        $durableHash = Get-Sha256 $keystore
        $legacyHash = Get-Sha256 $legacyKeystore
        if ($durableHash -ne $legacyHash) {
            Stop-Candidate 'SIGNING_IDENTITY_CONFLICT' 'Durable and legacy LAB signing identities differ; refusing to choose one implicitly.'
        }
    }
}
elseif (Test-Path -LiteralPath $legacyKeystore -PathType Leaf) {
    Copy-Item -LiteralPath $legacyKeystore -Destination $keystore
    $legacyHash = Get-Sha256 $legacyKeystore
    $durableHash = Get-Sha256 $keystore
    if ($legacyHash -ne $durableHash) {
        Remove-Item -Force -LiteralPath $keystore -ErrorAction SilentlyContinue
        Stop-Candidate 'SIGNING_MIGRATION_FAILED' 'LAB signing identity copy did not preserve exact bytes.'
    }
    Write-Host "Migrated existing LAB signing identity into durable state: $state"
}
else {
    $installedProbe = Invoke-NativeCapture -FilePath $adb -Arguments @('shell', 'pm', 'path', $applicationId)
    $debugAlreadyInstalled = $installedProbe.ExitCode -eq 0 -and $installedProbe.Text -match '(?m)^package:'
    if ($debugAlreadyInstalled) {
        Stop-Candidate 'SIGNING_IDENTITY_MISSING' 'Debug package is already installed but no known LAB signing identity exists; refusing to create an incompatible key.'
    }

    Invoke-Native $keytool @(
        '-genkeypair',
        '-keystore', $keystore,
        '-storetype', 'PKCS12',
        '-storepass', $keystorePassword,
        '-keypass', $keystorePassword,
        '-alias', $keyAlias,
        '-keyalg', 'RSA',
        '-keysize', '3072',
        '-validity', '36500',
        '-dname', 'CN=MISH LAB Device Candidate,O=MISH LAB,C=ZZ',
        '-noprompt'
    ) 'SIGNING_FAILED' 'Persistent LAB device-candidate signing key could not be created.' | Out-Null
}

$signedProduct = Join-Path $root 'mobile-proxy-mish-debug-lab-signed.apk'
$signedTest = Join-Path $root 'mobile-proxy-mish-debug-androidTest-lab-signed.apk'
foreach ($signed in @($signedProduct, $signedTest)) {
    Remove-Item -Force -LiteralPath $signed -ErrorAction SilentlyContinue
}

foreach ($pair in @(@($productPath, $signedProduct), @($testPath, $signedTest))) {
    Invoke-Native $apksigner @(
        'sign',
        '--ks', $keystore,
        '--ks-key-alias', $keyAlias,
        '--ks-pass', "pass:$keystorePassword",
        '--key-pass', "pass:$keystorePassword",
        '--out', $pair[1],
        $pair[0]
    ) 'SIGNING_FAILED' 'LAB device-candidate APK signing failed.' | Out-Null
    Invoke-Native $apksigner @('verify', '--verbose', $pair[1]) 'SIGNING_FAILED' 'LAB-signed candidate APK verification failed.' | Out-Null
}

$certResult = Invoke-NativeCapture -FilePath $apksigner -Arguments @('verify', '--print-certs', $signedProduct)
if ($certResult.ExitCode -ne 0) {
    Stop-Candidate 'SIGNING_FAILED' 'LAB signing certificate projection failed.'
}
$certMatch = [regex]::Match($certResult.Text, '(?im)^Signer #1 certificate SHA-256 digest:\s*([0-9a-f:]{64,95})\s*$')
if (-not $certMatch.Success) {
    Stop-Candidate 'SIGNING_FAILED' 'LAB signing certificate digest could not be parsed.'
}
$certSha = $certMatch.Groups[1].Value.Replace(':', '').ToLowerInvariant()
if ($certSha -notmatch '^[0-9a-f]{64}$') {
    Stop-Candidate 'SIGNING_FAILED' 'LAB signing certificate digest is invalid.'
}

$installResult = Invoke-AdbInstallBounded -Adb $adb -ApkPath $signedProduct -TimeoutSeconds 90
if ($installResult.ExitCode -ne 0 -or $installResult.Text -notmatch '(?m)^Success\s*$') {
    if ($installResult.Text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        Stop-Candidate 'SIGNATURE_MIGRATION_REQUIRED' 'Existing debug package uses another signing identity; perform one explicit debug-package migration, then rerun. Production package is untouched.'
    }
    Stop-Candidate 'INSTALL_FAILED' 'adb install -r did not report Success.'
}

$testInstallResult = Invoke-AdbInstallBounded -Adb $adb -ApkPath $signedTest -TestOnly -TimeoutSeconds 90
if ($testInstallResult.ExitCode -ne 0 -or $testInstallResult.Text -notmatch '(?m)^Success\s*$') {
    if ($testInstallResult.Text -match 'INSTALL_FAILED_UPDATE_INCOMPATIBLE') {
        Stop-Candidate 'TEST_HARNESS_SIGNATURE_MIGRATION_REQUIRED' "Existing $testApplicationId uses another signing identity; remove only that LAB test package once, then rerun. PRODUCT package is untouched."
    }
    Stop-Candidate 'TEST_HARNESS_INSTALL_FAILED' 'LAB-signed androidTest APK installation did not report Success.'
}

[pscustomobject]@{
    result = 'PASS'
    mode = 'install'
    pr_number = $ExpectedPrNumber
    source_sha = $ExpectedSourceSha
    target_abi = [string]$manifest.target_abi
    application_id = $applicationId
    test_application_id = $testApplicationId
    original_product_apk_sha256 = $productSha
    signed_product_apk_sha256 = Get-Sha256 $signedProduct
    signed_android_test_apk_sha256 = Get-Sha256 $signedTest
    lab_signing_certificate_sha256 = $certSha
    signing_state_root = $state
    installed = $true
    test_harness_installed = $true
    local_build = $false
} | ConvertTo-Json -Compress
