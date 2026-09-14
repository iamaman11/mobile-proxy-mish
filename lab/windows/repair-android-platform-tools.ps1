[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$RepositoryCommit,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Android platform-tools repair must run from an elevated Windows PowerShell console.'
    }
}

function Invoke-NativeTextProbe {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string]$ArgumentsLine = ''
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = $ArgumentsLine
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Failed to start native probe: $FilePath"
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Text = (($stdout + "`n" + $stderr).Trim())
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile
    )
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
}

function Add-MachinePath {
    param([Parameter(Mandatory)][string]$PathEntry)
    $current = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $parts = @($current -split ';' | Where-Object { $_ })
    if (-not ($parts | Where-Object { $_.TrimEnd('\') -ieq $PathEntry.TrimEnd('\') })) {
        [Environment]::SetEnvironmentVariable('Path', (($parts + $PathEntry) -join ';'), 'Machine')
    }
}

function Set-MachineVariable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    Set-Item -Path "Env:$Name" -Value $Value
}

function Get-JdkPath {
    param([Parameter(Mandatory)][int]$Major)
    $root = 'C:\Program Files\Eclipse Adoptium'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    foreach ($candidate in @(Get-ChildItem $root -Directory -Filter "jdk-$Major*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $java = Join-Path $candidate.FullName 'bin\java.exe'
        if (-not (Test-Path -LiteralPath $java -PathType Leaf)) { continue }
        $probe = Invoke-NativeTextProbe -FilePath $java -ArgumentsLine '-version'
        if ($probe.ExitCode -eq 0 -and $probe.Text -match ('version\s+"' + [regex]::Escape([string]$Major) + '(?:\.|\")')) {
            return $candidate.FullName
        }
    }
    return $null
}

function Test-CanonicalAdbCapability {
    param([Parameter(Mandatory)][string]$AdbPath)
    if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) { return $false }
    $probe = Invoke-NativeTextProbe -FilePath $AdbPath -ArgumentsLine 'version'
    return ($probe.ExitCode -eq 0 -and $probe.Text -match 'Android Debug Bridge')
}

function Ensure-CanonicalAdb {
    param(
        [Parameter(Mandatory)][string]$SdkManager,
        [Parameter(Mandatory)][string]$SdkRoot
    )

    $adbPath = Join-Path $SdkRoot 'platform-tools\adb.exe'
    if (Test-CanonicalAdbCapability -AdbPath $adbPath) {
        Write-Host 'Canonical Android platform-tools already satisfy the LAB requirement; sdkmanager install skipped.'
        return $adbPath
    }

    if (-not (Test-Path -LiteralPath $SdkManager -PathType Leaf)) {
        throw "Pinned canonical sdkmanager is unavailable: $SdkManager"
    }

    & $SdkManager "--sdk_root=$SdkRoot" 'platform-tools'
    $sdkManagerExit = [int]$LASTEXITCODE
    if (-not (Test-CanonicalAdbCapability -AdbPath $adbPath)) {
        throw "sdkmanager exited with code $sdkManagerExit, but canonical ADB postcondition is not satisfied: $adbPath"
    }
    if ($sdkManagerExit -ne 0) {
        Write-Host "sdkmanager returned $sdkManagerExit, but the exact canonical ADB execution postcondition is satisfied; continuing."
    }
    return $adbPath
}

function Get-ConfiguredRunnerService {
    param([Parameter(Mandatory)][string]$RunnerRoot)

    $runnerConfig = Join-Path $RunnerRoot '.runner'
    $serviceFile = Join-Path $RunnerRoot '.service'
    $hasConfig = Test-Path -LiteralPath $runnerConfig -PathType Leaf
    $hasService = Test-Path -LiteralPath $serviceFile -PathType Leaf
    if ($hasConfig -xor $hasService) {
        throw 'Runner configuration markers are inconsistent; refusing implicit repair or replacement.'
    }
    if (-not $hasConfig) {
        throw 'Existing repository runner registration is required for bounded Android platform-tools repair.'
    }

    $serviceName = (Get-Content -Raw -LiteralPath $serviceFile).Trim()
    if (-not $serviceName) { throw 'Runner service marker is empty.' }
    $escaped = $serviceName.Replace("'", "''")
    $service = Get-CimInstance Win32_Service -Filter ("Name='" + $escaped + "'")
    if (-not $service) { throw 'Configured runner service was not found.' }
    if ($service.StartName -ine 'NT AUTHORITY\NETWORK SERVICE') {
        throw 'Runner service identity is not NetworkService.'
    }
    return $service
}

function Invoke-RepairSelfTest {
    $root = Join-Path $env:TEMP ('mish-lab-adb-repair-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    try {
        $sdkRoot = Join-Path $root 'android-sdk'
        $sdkManager = Join-Path $root 'sdkmanager.cmd'
        New-Item -ItemType Directory -Force -Path $sdkRoot | Out-Null
        Set-Content -Encoding Ascii -LiteralPath $sdkManager -Value @(
            '@echo off',
            'exit /b 0'
        )

        $failedClosed = $false
        try {
            [void](Ensure-CanonicalAdb -SdkManager $sdkManager -SdkRoot $sdkRoot)
        }
        catch {
            if ($_.Exception.Message -notmatch 'sdkmanager exited with code 0, but canonical ADB postcondition is not satisfied') {
                throw
            }
            $failedClosed = $true
        }
        if (-not $failedClosed) {
            throw 'Android platform-tools repair self-test failed: sdkmanager exit 0 without adb.exe produced a false PASS.'
        }

        Write-Host 'Android platform-tools repair self-test passed.'
    }
    finally {
        Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
    }
}

if ($SelfTest) {
    Invoke-RepairSelfTest
    exit 0
}

Assert-Administrator
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'LAB-1 requires 64-bit Windows.'
}

$tempRoot = Join-Path $env:TEMP ('mish-lab-adb-repair-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    $manifestPath = Join-Path $tempRoot 'toolchain.json'
    $manifestUri = "https://raw.githubusercontent.com/iamaman11/mobile-proxy-mish/$RepositoryCommit/lab/windows/toolchain.json"
    Get-RemoteFile -Uri $manifestUri -OutFile $manifestPath
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    if ($manifest.schema -ne 'mish.lab.windows-toolchain/v1') {
        throw 'Unsupported LAB-1 toolchain manifest schema.'
    }

    $runnerRoot = [string]$manifest.host.runner_root
    $toolsRoot = [string]$manifest.host.tools_root
    $sdkRoot = [string]$manifest.android.sdk_root
    $canonicalSdkRoot = 'C:\mish-lab\tools\android-sdk'
    if ([IO.Path]::GetFullPath($sdkRoot).TrimEnd('\') -ine $canonicalSdkRoot) {
        throw "Android SDK root contract drifted from the canonical service-owned path: $sdkRoot"
    }

    $sdkPackages = @($manifest.android.packages | ForEach-Object { [string]$_ })
    if (-not ($sdkPackages -contains 'platform-tools')) {
        throw 'Toolchain manifest does not declare the required platform-tools package.'
    }

    $jdkPath = Get-JdkPath -Major ([int]$manifest.java.major)
    if (-not $jdkPath) {
        throw 'Pinned Temurin JDK is unavailable; bounded Android platform-tools repair will not install unrelated host dependencies.'
    }
    Set-MachineVariable -Name 'JAVA_HOME' -Value $jdkPath

    $sdkManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path -LiteralPath $sdkManager -PathType Leaf)) {
        throw 'Pinned canonical sdkmanager is unavailable; bounded repair refuses to install or replace the wider Android toolchain.'
    }

    Set-MachineVariable -Name 'ANDROID_SDK_ROOT' -Value $sdkRoot
    Set-MachineVariable -Name 'ANDROID_HOME' -Value $sdkRoot
    Add-MachinePath -PathEntry (Join-Path $sdkRoot 'platform-tools')
    Add-MachinePath -PathEntry (Join-Path $sdkRoot 'cmdline-tools\latest\bin')

    $adbPath = Ensure-CanonicalAdb -SdkManager $sdkManager -SdkRoot $sdkRoot

    & icacls.exe $toolsRoot /grant '*S-1-5-20:(OI)(CI)RX' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to grant NetworkService read/execute access to the LAB tools root.'
    }

    $service = Get-ConfiguredRunnerService -RunnerRoot $runnerRoot
    $controller = Get-Service -Name ([string]$service.Name)
    if ($controller.Status -ne 'Running') {
        Start-Service -Name $controller.Name
        $controller = Get-Service -Name $controller.Name
        $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))
    }

    $adbProbe = Invoke-NativeTextProbe -FilePath $adbPath -ArgumentsLine 'version'
    if ($adbProbe.ExitCode -ne 0 -or $adbProbe.Text -notmatch 'Android Debug Bridge') {
        throw 'Canonical adb.exe failed its final execution postcondition.'
    }

    $deviceOutput = @(& $adbPath devices)
    if ($LASTEXITCODE -ne 0) {
        throw 'Canonical adb.exe failed to enumerate devices.'
    }
    $deviceRows = @($deviceOutput | Where-Object { $_ -match '^\S+\s+\S+\s*$' })
    $authorizedRows = @($deviceRows | Where-Object { $_ -match '^\S+\s+device\s*$' })
    if ($authorizedRows.Count -ne 1 -or $deviceRows.Count -ne 1) {
        throw 'Exactly one authorized DEVICE-1 must be visible through canonical ADB, with no additional ADB device rows.'
    }

    $api = (& $adbPath shell getprop ro.build.version.sdk 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $api -ne '30') {
        throw "DEVICE-1 Android API must be 30; observed '$api'."
    }
    $abi = (& $adbPath shell getprop ro.product.cpu.abi 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $abi -ne 'armeabi-v7a') {
        throw "DEVICE-1 ABI must be armeabi-v7a; observed '$abi'."
    }

    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $rootText = (& $adbPath shell su -c id 2>&1 | Out-String).Trim()
        $rootExit = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }
    if ($rootExit -ne 0 -or $rootText -notmatch '\buid=0\b') {
        throw 'Magisk/root authority is not available to DEVICE-1 through canonical ADB.'
    }

    Write-Host 'REPAIR_ANDROID_PLATFORM_TOOLS=PASS'
    Write-Host 'CANONICAL_ADB_PRESENT=PASS'
    Write-Host 'ADB_VERSION=PASS'
    Write-Host 'AUTHORIZED_DEVICE_COUNT=1'
    Write-Host 'ANDROID_API=30'
    Write-Host 'ANDROID_ABI=armeabi-v7a'
    Write-Host 'MAGISK_ROOT=PASS'
    Write-Host 'RUNNER_SERVICE=PASS'
    Write-Host 'LOCAL_BUILD_PERFORMED=NO'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}
