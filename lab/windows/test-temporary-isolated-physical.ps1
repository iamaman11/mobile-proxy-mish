[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FixtureDirectory,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string]$ExpectedSourceSha,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ExpectedPrNumber,
    [string]$AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# The only installable identity is a disposable TEST UID; installed PRODUCT is read-only.
$stable = 'com.mobileproxymish.app.debug'
$isolated = 'com.mobileproxymish.app.isolated.debug'
$testPackage = "$isolated.test"
$runner = "$testPackage/androidx.test.runner.AndroidJUnitRunner"
$fixture = [IO.Path]::GetFullPath($FixtureDirectory)
$manifestPath = Join-Path $fixture 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'TEMP_ISOLATED|ARTIFACT_MISSING'
}
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ([string]$manifest.schema -cne 'mish-temporary-isolated-fixture-v1' -or
    [string]$manifest.source_sha -cne $ExpectedSourceSha -or
    [int]$manifest.pr_number -ne $ExpectedPrNumber -or
    [string]$manifest.application_id -cne $isolated -or
    -not [bool]$manifest.no_production_install) {
    throw 'TEMP_ISOLATED|ARTIFACT_IDENTITY_MISMATCH'
}
$app = Join-Path $fixture 'disposable-app.apk'
$test = Join-Path $fixture 'disposable-androidTest.apk'
foreach ($item in @(@{Path=$app;Name='disposable-app.apk'}, @{Path=$test;Name='disposable-androidTest.apk'})) {
    if (-not (Test-Path -LiteralPath $item.Path -PathType Leaf)) {
        throw 'TEMP_ISOLATED|APK_MISSING'
    }
    $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $item.Path).Hash.ToLowerInvariant()
    if ($digest -cne [string]$manifest.sha256.($item.Name)) {
        throw 'TEMP_ISOLATED|APK_DIGEST_MISMATCH'
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    throw 'TEMP_ISOLATED|ADB_MISSING'
}
function Run-Adb {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 45
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $AdbPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'TEMP_ISOLATED|ADB_START_FAILED' }
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            throw "TEMP_ISOLATED|ADB_TIMEOUT|$($Arguments[0])"
        }
        $stdout = $outTask.GetAwaiter().GetResult()
        [void]$errTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            throw "TEMP_ISOLATED|ADB_FAILED|$($Arguments[0])"
        }
        return @($stdout -split '\r?\n' | Where-Object { $_.Trim() -ne '' })
    }
    finally { $process.Dispose() }
}
$devices = @(Run-Adb @('devices') | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($devices.Count -ne 1) { throw 'TEMP_ISOLATED|DEVICE_IDENTITY_MISMATCH' }
if (([string](Run-Adb @('shell','getprop','ro.build.version.sdk'))).Trim() -cne '30' -or
    ([string](Run-Adb @('shell','getprop','ro.product.cpu.abi'))).Trim() -cne 'armeabi-v7a') {
    throw 'TEMP_ISOLATED|ANDROID_VERSION_OR_ABI_MISMATCH'
}
function Installed-Path {
    param([Parameter(Mandatory)][string]$Package)
    $lines = @(Run-Adb @('shell','pm','path',$Package))
    $matches = @($lines | Where-Object { $_ -match '^package:(.+/base\.apk)\s*$' })
    if ($matches.Count -eq 0) { return $null }
    if ($matches.Count -ne 1) { throw 'TEMP_ISOLATED|AMBIGUOUS_PACKAGE' }
    return ([regex]::Match([string]$matches[0], '^package:(.+/base\.apk)\s*$')).Groups[1].Value
}
if ((Installed-Path $isolated) -or (Installed-Path $testPackage)) {
    throw 'TEMP_ISOLATED|DISPOSABLE_PACKAGE_ALREADY_EXISTS'
}
function Read-Stable-Hash {
    $path = Installed-Path $stable
    if (-not $path) { throw 'TEMP_ISOLATED|PRIMARY_PRODUCT_MISSING' }
    $tmp = Join-Path $env:RUNNER_TEMP 'mish-stable-installed-base.apk'
    try {
        [void](Run-Adb -Arguments @('pull', $path, $tmp) -TimeoutSeconds 90)
        return (Get-FileHash -Algorithm SHA256 -LiteralPath $tmp).Hash.ToLowerInvariant()
    }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
function Check-Primary {
    param([Parameter(Mandatory)][string]$EvidencePath)
    & .\lab\windows\collect-device-diagnostic.ps1 -AdbPath $AdbPath -PackageName $stable -EvidencePath $EvidencePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $EvidencePath)) {
        throw 'TEMP_ISOLATED|PRIMARY_DIAGNOSTIC_FAILED'
    }
    $d = Get-Content -Raw -LiteralPath $EvidencePath | ConvertFrom-Json
    if ([string]$d.classification -cne 'PASS' -or
        [string]$d.android.proxy.state -cne 'RUNNING' -or
        -not [bool]$d.android.proxy.healthy -or
        [string]$d.external.adb_loopback_proxy_e2e.result -cne 'PASS' -or
        [string]$d.external.mesh_proxy_e2e.result -cne 'PASS') {
        throw 'TEMP_ISOLATED|PRIMARY_NOT_READY'
    }
}

$beforeHash = Read-Stable-Hash
Check-Primary -EvidencePath (Join-Path $env:RUNNER_TEMP 'primary-before-isolated.json')
$touchApp = $false
$touchTest = $false
$testPassed = $false
$operationError = $null
try {
    $touchApp = $true
    $appResult = @(Run-Adb -Arguments @('install','-t',$app) -TimeoutSeconds 90)
    if (-not (($appResult -join ' ') -match 'Success')) { throw 'TEMP_ISOLATED|APP_INSTALL_NOT_SUCCESS' }
    $touchTest = $true
    $testResult = @(Run-Adb -Arguments @('install','-t',$test) -TimeoutSeconds 90)
    if (-not (($testResult -join ' ') -match 'Success')) { throw 'TEMP_ISOLATED|TEST_INSTALL_NOT_SUCCESS' }
    if (-not (Installed-Path $isolated) -or -not (Installed-Path $testPackage)) {
        throw 'TEMP_ISOLATED|INSTALLED_TEST_UID_MISSING'
    }

    $classes = @(
        'com.mobileproxymish.app.TemporaryAccessIsolatedPackageInstrumentedTest',
        'com.mobileproxymish.app.TemporaryProxyCredentialDurabilityInstrumentedTest',
        'com.mobileproxymish.app.TemporaryProxyAccessDialogInstrumentedTest'
    ) -join ','
    $output = @(Run-Adb -Arguments @('shell','am','instrument','-w','-r','-e','class',$classes,$runner) -TimeoutSeconds 240)
    $joined = $output -join [Environment]::NewLine
    if ($joined -notmatch 'INSTRUMENTATION_CODE:\s*-1' -or
        $joined -notmatch 'OK \([1-9][0-9]* tests?\)' -or
        $joined -match 'FAILURES!!!|INSTRUMENTATION_FAILED|Process crashed') {
        throw 'TEMP_ISOLATED|INSTRUMENTATION_NOT_PASS'
    }
    $testPassed = $true
}
catch { $operationError = $_.Exception.Message }
finally {
    if ($touchTest) {
        try { [void](Run-Adb -Arguments @('uninstall', $testPackage) -TimeoutSeconds 90) }
        catch { if (-not $operationError) { $operationError = 'TEMP_ISOLATED|TEST_CLEANUP_FAILED' } }
    }
    if ($touchApp) {
        try { [void](Run-Adb -Arguments @('uninstall', $isolated) -TimeoutSeconds 90) }
        catch { if (-not $operationError) { $operationError = 'TEMP_ISOLATED|APP_CLEANUP_FAILED' } }
    }
    if ((Installed-Path $isolated) -or (Installed-Path $testPackage)) {
        $operationError = 'TEMP_ISOLATED|CLEANUP_NOT_VERIFIED'
    }
    if ((Read-Stable-Hash) -cne $beforeHash) {
        $operationError = 'TEMP_ISOLATED|PRIMARY_APK_CHANGED'
    }
    try {
        Check-Primary -EvidencePath (Join-Path $env:RUNNER_TEMP 'primary-after-isolated.json')
    }
    catch { $operationError = 'TEMP_ISOLATED|PRIMARY_POSTCHECK_FAILED' }

    if ($env:GITHUB_STEP_SUMMARY) {
        @(
            '### #463 isolated DEVICE-1 instrumentation'
            "Exact source: $ExpectedSourceSha"
            "Disposable package: $isolated (never replaces $stable)"
            "Instrumented tests PASS: $testPassed"
            "Result: $(if ($operationError) { 'FAILED' } else { 'PASS' })"
        ) | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
    }
}
if ($operationError) { throw $operationError }
if (-not $testPassed) { throw 'TEMP_ISOLATED|NOT_VERIFIED' }
Write-Host 'TEMP_ISOLATED_PHYSICAL=PASS'
