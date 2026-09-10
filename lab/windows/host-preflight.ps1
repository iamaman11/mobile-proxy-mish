[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$EvidencePath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$started = [DateTimeOffset]::UtcNow
$failureCategory = $null
$failureMessage = $null
$observations = [ordered]@{}

function Stop-Lab {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('HOST_PREREQUISITE_MISSING', 'UNTRUSTED_REF', 'IDENTITY_MISMATCH', 'BUILD_FAILED', 'OBSERVATION_CONTRADICTION')]
        [string]$Category,
        [Parameter(Mandatory)][string]$Message
    )
    throw "MISH_LAB_FAILURE|$Category|$Message"
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$FailureCategory = 'HOST_PREREQUISITE_MISSING',
        [string]$FailureMessage = 'Required command failed.'
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        Stop-Lab -Category $FailureCategory -Message $FailureMessage
    }
}

function Require-Command {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message "$Name is unavailable."
    }
    return $cmd.Source
}

function Read-Version {
    param([Parameter(Mandatory)][string]$Text)
    $match = [regex]::Match($Text, '\b([0-9]+\.[0-9]+(?:\.[0-9]+)?)\b')
    if (-not $match.Success) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'A tool version could not be parsed.'
    }
    return [version]$match.Groups[1].Value
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
if (-not $EvidencePath) {
    $EvidencePath = Join-Path $env:RUNNER_TEMP 'mish-lab-host-preflight.json'
}
$manifestPath = Join-Path $RepositoryRoot 'lab\windows\toolchain.json'

try {
    if ($env:GITHUB_REPOSITORY -ne 'iamaman11/mobile-proxy-mish') {
        Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Repository identity mismatch.'
    }
    if ($env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_REF_PROTECTED -ne 'true') {
        Stop-Lab -Category 'UNTRUSTED_REF' -Message 'Physical preflight requires protected main.'
    }
    if ($env:GITHUB_SHA -notmatch '^[0-9a-f]{40}$') {
        Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Git commit identity is invalid.'
    }
    if ($env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64') {
        Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'LAB-1 requires the Windows x64 runner.'
    }
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'Toolchain manifest is unavailable.'
    }

    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.schema -ne 'mish.lab.windows-toolchain/v1') {
        Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Toolchain manifest schema mismatch.'
    }

    $runnerRoot = [IO.Path]::GetFullPath([string]$manifest.host.runner_root).TrimEnd('\')
    $workspace = [IO.Path]::GetFullPath($env:RUNNER_WORKSPACE)
    $workPrefix = $runnerRoot + '\_work\'
    if (-not $workspace.StartsWith($workPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Runner checkout is outside the dedicated runner work root.'
    }

    $identityName = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($identityName -ine 'NT AUTHORITY\NETWORK SERVICE') {
        Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Runner service account is not NetworkService.'
    }

    $gitPath = Require-Command 'git'
    Push-Location $RepositoryRoot
    try {
        $head = (& $gitPath rev-parse HEAD).Trim()
        if ($LASTEXITCODE -ne 0 -or $head -ne $env:GITHUB_SHA) {
            Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Checkout HEAD does not match GITHUB_SHA.'
        }
        $dirty = & $gitPath status --porcelain=v1
        if ($LASTEXITCODE -ne 0 -or $dirty) {
            Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Checkout is not clean before preflight.'
        }
    }
    finally { Pop-Location }

    $toolsRoot = [string]$manifest.host.tools_root
    $cargoHome = Join-Path $toolsRoot 'cargo'
    $rustupHome = Join-Path $toolsRoot 'rustup'
    $gradleHome = Join-Path $toolsRoot ('gradle-' + [string]$manifest.gradle.version)
    $sdkRoot = [string]$manifest.android.sdk_root

    $env:CARGO_HOME = $cargoHome
    $env:RUSTUP_HOME = $rustupHome
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:ANDROID_HOME = $sdkRoot
    $env:ANDROID_NDK_HOME = Join-Path $sdkRoot ('ndk\' + [string]$manifest.android.ndk)
    $env:ANDROID_NDK_ROOT = $env:ANDROID_NDK_HOME
    $env:ANDROID_NDK = $env:ANDROID_NDK_HOME
    $env:Path = "$(Join-Path $cargoHome 'bin');$(Join-Path $gradleHome 'bin');$(Join-Path $sdkRoot 'platform-tools');$(Join-Path $sdkRoot 'cmdline-tools\latest\bin');$env:Path"

    $gradlePath = Require-Command 'gradle'
    $rustcPath = Require-Command 'rustc'
    $cargoPath = Require-Command 'cargo'
    $adbPath = Require-Command 'adb'
    $javaPath = Require-Command 'java'
    $null = Require-Command 'pwsh'

    $gitVersion = Read-Version ((& $gitPath --version 2>&1 | Out-String).Trim())
    if ($gitVersion -lt [version]([string]$manifest.git.minimum_version)) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'Git is older than the LAB-1 minimum.'
    }

    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion -lt [version]([string]$manifest.powershell.minimum_version)) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'PowerShell is older than the LAB-1 minimum.'
    }

    $javaText = (& $javaPath -version 2>&1 | Out-String)
    $javaMatch = [regex]::Match($javaText, 'version "([0-9]+)(?:\.|\")')
    if (-not $javaMatch.Success -or [int]$javaMatch.Groups[1].Value -ne [int]$manifest.java.major) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'JDK major version does not match the LAB-1 manifest.'
    }

    $gradleText = (& $gradlePath --version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $gradleText -notmatch ('Gradle\s+' + [regex]::Escape([string]$manifest.gradle.version))) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'Gradle version does not match the LAB-1 manifest.'
    }

    $rustText = (& $rustcPath --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $rustText -notmatch ('^rustc\s+' + [regex]::Escape([string]$manifest.rust.toolchain) + '\b')) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'Rust toolchain does not match the LAB-1 manifest.'
    }

    $cargoNdkText = (& $cargoPath ndk --version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $cargoNdkText -notmatch ([regex]::Escape([string]$manifest.rust.cargo_ndk))) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'cargo-ndk version does not match the LAB-1 manifest.'
    }

    $sdkManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
    $ndkPath = Join-Path $sdkRoot ('ndk\' + [string]$manifest.android.ndk)
    $expectedPlatformDir = 'android-{0}.{1}' -f [int]$manifest.android.compile_sdk, [int]$manifest.android.compile_sdk_minor
    $platformDir = [string]$manifest.android.platform_dir
    $platformPackage = [string]$manifest.android.platform_package
    if ($platformDir -ne $expectedPlatformDir -or $platformPackage -ne ('platforms;' + $expectedPlatformDir)) {
        Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Android platform manifest coordinate is inconsistent.'
    }
    if (-not (@($manifest.android.packages | ForEach-Object { [string]$_ }) -contains $platformPackage)) {
        Stop-Lab -Category 'IDENTITY_MISMATCH' -Message 'Android platform package is missing from the install set.'
    }
    $platformPath = Join-Path $sdkRoot ('platforms\' + $platformDir)
    if (-not (Test-Path -LiteralPath $sdkManager) -or -not (Test-Path -LiteralPath $ndkPath) -or -not (Test-Path -LiteralPath $platformPath)) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'Pinned Android SDK/NDK components are incomplete.'
    }

    $adbText = (& $adbPath version 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0 -or $adbText -notmatch 'Android Debug Bridge') {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'adb is unavailable.'
    }

    $adbDevices = & $adbPath devices
    if ($LASTEXITCODE -ne 0) {
        Stop-Lab -Category 'HOST_PREREQUISITE_MISSING' -Message 'adb device enumeration failed.'
    }
    # Any row with a serial + state means a device is physically represented to ADB.
    # Do not log the row: the public evidence records only the boolean absence invariant.
    $adbDeviceRows = @($adbDevices | Where-Object { $_ -match '^\S+\s+\S+\s*$' })
    if ($adbDeviceRows.Count -ne 0) {
        Stop-Lab -Category 'OBSERVATION_CONTRADICTION' -Message 'An ADB device is present during pre-phone LAB-1.'
    }

    Push-Location $RepositoryRoot
    try {
        Invoke-NativeChecked -FilePath $cargoPath -Arguments @(
            'ndk', '-P', ([string]$manifest.android.min_sdk), '-t', 'arm64-v8a',
            'build', '-p', 'mish-runtime', '--example', 'android_cellular_connector_link', '--release', '--locked'
        ) -FailureCategory 'BUILD_FAILED' -FailureMessage 'Android arm64 Rust cross-build failed.'

        $connector = Join-Path $RepositoryRoot 'target\aarch64-linux-android\release\examples\android_cellular_connector_link'
        if (-not (Test-Path -LiteralPath $connector)) {
            Stop-Lab -Category 'BUILD_FAILED' -Message 'Android arm64 connector artifact was not produced.'
        }

        Invoke-NativeChecked -FilePath $gradlePath -Arguments @('--no-daemon', '-p', 'android', ':app:assembleDebug') `
            -FailureCategory 'BUILD_FAILED' -FailureMessage 'Android debug assembly failed.'

        $apk = Join-Path $RepositoryRoot 'android\app\build\outputs\apk\debug\app-debug.apk'
        if (-not (Test-Path -LiteralPath $apk)) {
            Stop-Lab -Category 'BUILD_FAILED' -Message 'Android debug APK was not produced.'
        }

        $observations = [ordered]@{
            host = [ordered]@{
                os = 'Windows'
                architecture = 'x86_64'
                service_identity = 'NetworkService'
                runner_work_root_enforced = $true
                phone_absent = $true
            }
            tools = [ordered]@{
                git = $gitVersion.ToString()
                powershell = $psVersion.ToString()
                java_major = [int]$manifest.java.major
                gradle = [string]$manifest.gradle.version
                rust = [string]$manifest.rust.toolchain
                cargo_ndk = [string]$manifest.rust.cargo_ndk
                android_compile_sdk = [int]$manifest.android.compile_sdk
                android_compile_sdk_minor = [int]$manifest.android.compile_sdk_minor
                android_platform_package = [string]$manifest.android.platform_package
                android_ndk = [string]$manifest.android.ndk
            }
            cross_build = [ordered]@{
                target = [string]$manifest.rust.target
                connector_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $connector).Hash.ToLowerInvariant()
                debug_apk_sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $apk).Hash.ToLowerInvariant()
            }
        }
    }
    finally { Pop-Location }
}
catch {
    $raw = $_.Exception.Message
    if ($raw -match '^MISH_LAB_FAILURE\|([^|]+)\|(.+)$') {
        $failureCategory = $Matches[1]
        $failureMessage = $Matches[2]
    }
    else {
        $failureCategory = 'HOST_PREREQUISITE_MISSING'
        $failureMessage = 'Unexpected host-preflight failure.'
    }
}
finally {
    $completed = [DateTimeOffset]::UtcNow
    $result = if ($failureCategory) { 'FAIL' } else { 'PASS' }
    $failure = if ($failureCategory) {
        [ordered]@{ category = $failureCategory; message = $failureMessage }
    }
    else { $null }

    $evidence = [ordered]@{
        schema = 'mish.lab.evidence/v1'
        run_kind = 'host-preflight'
        repository = 'iamaman11/mobile-proxy-mish'
        git_ref = $env:GITHUB_REF
        git_commit = $env:GITHUB_SHA
        started_at_utc = $started.ToString('o')
        completed_at_utc = $completed.ToString('o')
        result = $result
        failure = $failure
        observations = $observations
    }

    $parent = Split-Path -Parent $EvidencePath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $evidence | ConvertTo-Json -Depth 8 | Set-Content -Encoding utf8NoBOM -LiteralPath $EvidencePath
}

if ($failureCategory) {
    throw "LAB-1 host preflight failed: $failureCategory."
}
Write-Host 'LAB-1 host preflight PASS.'
