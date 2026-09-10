[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$RepositoryCommit,
    [ValidatePattern('^[A-Za-z0-9._-]{0,64}$')]
    [string]$RunnerName = '',
    [string]$RunnerTokenProviderExecutable = '',
    [string]$RunnerTokenProviderArgumentsJson = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'LAB-1 bootstrap must run from an elevated Windows PowerShell console.'
    }
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath exited with code $LASTEXITCODE."
    }
}

function Get-RemoteFile {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [string]$Sha256 = ''
    )
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $OutFile
    if ($Sha256) {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $OutFile).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            Remove-Item -Force -LiteralPath $OutFile -ErrorAction SilentlyContinue
            throw "SHA-256 mismatch for $Uri."
        }
    }
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

function Refresh-ProcessPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = "$machine;$user"
}

function Format-NativeExitCode {
    param([Parameter(Mandatory)][int]$ExitCode)
    $unsigned = [BitConverter]::ToUInt32([BitConverter]::GetBytes($ExitCode), 0)
    return ('0x{0:X8}' -f $unsigned)
}

function Test-GitCapability {
    param([Parameter(Mandatory)][version]$MinimumVersion)
    $command = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $command) { return $false }
    $text = (& $command.Source --version 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { return $false }
    $match = [regex]::Match($text, '\b([0-9]+\.[0-9]+(?:\.[0-9]+)?)\b')
    if (-not $match.Success) { return $false }
    try { return ([version]$match.Groups[1].Value -ge $MinimumVersion) }
    catch { return $false }
}

function Get-JdkPath {
    param([Parameter(Mandatory)][int]$Major)
    $root = 'C:\Program Files\Eclipse Adoptium'
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return $null }
    foreach ($candidate in @(Get-ChildItem $root -Directory -Filter "jdk-$Major*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
        $java = Join-Path $candidate.FullName 'bin\java.exe'
        if (-not (Test-Path -LiteralPath $java -PathType Leaf)) { continue }
        $text = (& $java -version 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0 -and $text -match ('version\s+"' + [regex]::Escape([string]$Major) + '(?:\.|\")')) {
            return $candidate.FullName
        }
    }
    return $null
}

function Test-JavaCapability {
    param([Parameter(Mandatory)][int]$Major)
    return [bool](Get-JdkPath -Major $Major)
}

function Test-PortablePowerShellCapability {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][version]$ExpectedVersion
    )
    if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return $false }
    $text = (& $Executable -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $text) { return $false }
    try { return ([version]$text -eq $ExpectedVersion) }
    catch { return $false }
}

function Ensure-PortablePowerShell {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$ToolsRoot,
        [Parameter(Mandatory)][string]$TempRoot
    )
    $version = [version]([string]$Manifest.version)
    $powerShellHome = Join-Path $ToolsRoot ('powershell-' + $version.ToString())
    $exe = Join-Path $powerShellHome 'pwsh.exe'

    if (Test-PortablePowerShellCapability -Executable $exe -ExpectedVersion $version) {
        Write-Host "Portable PowerShell $version already satisfies the LAB-1 service-visible requirement."
        Add-MachinePath -PathEntry $powerShellHome
        return $exe
    }

    if (Test-Path -LiteralPath $powerShellHome) {
        Remove-Item -Recurse -Force -LiteralPath $powerShellHome
    }
    New-Item -ItemType Directory -Force -Path $powerShellHome | Out-Null

    $archive = Join-Path $TempRoot ([string]$Manifest.asset)
    Get-RemoteFile -Uri ([string]$Manifest.url) -OutFile $archive -Sha256 ([string]$Manifest.sha256)
    Expand-Archive -LiteralPath $archive -DestinationPath $powerShellHome -Force

    if (-not (Test-PortablePowerShellCapability -Executable $exe -ExpectedVersion $version)) {
        throw "Pinned portable PowerShell $version did not satisfy its exact execution postcondition."
    }

    Add-MachinePath -PathEntry $powerShellHome
    Write-Host "Pinned portable PowerShell $version materialized for LAB-1 service execution."
    return $exe
}

function Ensure-WingetPackage {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$CapabilityName,
        [Parameter(Mandatory)][scriptblock]$ReadyScript,
        [string]$WingetPath = ''
    )

    if (& $ReadyScript) {
        Write-Host "$CapabilityName already satisfies the LAB-1 requirement; winget install skipped."
        return
    }

    if (-not $WingetPath) {
        $winget = Get-Command winget.exe -ErrorAction Stop
        $WingetPath = $winget.Source
    }

    Write-Host "Materializing $CapabilityName through winget package $Id."
    & $WingetPath install --id $Id --exact --silent --scope machine `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $exitCode = [int]$LASTEXITCODE

    Refresh-ProcessPath
    if (& $ReadyScript) {
        if ($exitCode -ne 0) {
            Write-Host "winget returned $exitCode ($(Format-NativeExitCode -ExitCode $exitCode)) for $Id, but the required capability postcondition is satisfied; continuing."
        }
        return
    }

    $hex = Format-NativeExitCode -ExitCode $exitCode
    throw "winget failed to materialize $CapabilityName ($Id): exit code $exitCode ($hex); required capability postcondition is not satisfied."
}

function Invoke-HostDependencySelfTest {
    $root = Join-Path $env:TEMP ('mish-lab-host-selftest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    try {
        $skipMarker = Join-Path $root 'skip-invoked.txt'
        $skipWinget = Join-Path $root 'skip-winget.cmd'
        Set-Content -Encoding Ascii -LiteralPath $skipWinget -Value @(
            '@echo off',
            "echo invoked>`"$skipMarker`"",
            'exit /b 1'
        )
        Ensure-WingetPackage -Id 'SelfTest.Skip' -CapabilityName 'self-test ready capability' `
            -ReadyScript { $true } -WingetPath $skipWinget
        if (Test-Path -LiteralPath $skipMarker) {
            throw 'Host dependency self-test failed: a ready capability still invoked winget.'
        }

        $postMarker = Join-Path $root 'postcondition.txt'
        $postWinget = Join-Path $root 'post-winget.cmd'
        Set-Content -Encoding Ascii -LiteralPath $postWinget -Value @(
            '@echo off',
            "echo ready>`"$postMarker`"",
            'exit /b 1'
        )
        Ensure-WingetPackage -Id 'SelfTest.Postcondition' -CapabilityName 'self-test materialized capability' `
            -ReadyScript { Test-Path -LiteralPath $postMarker } -WingetPath $postWinget
        if (-not (Test-Path -LiteralPath $postMarker)) {
            throw 'Host dependency self-test failed: postcondition marker was not materialized.'
        }

        $failWinget = Join-Path $root 'fail-winget.cmd'
        Set-Content -Encoding Ascii -LiteralPath $failWinget -Value @(
            '@echo off',
            'exit /b 1'
        )
        $failedAsExpected = $false
        try {
            Ensure-WingetPackage -Id 'SelfTest.Fail' -CapabilityName 'self-test missing capability' `
                -ReadyScript { $false } -WingetPath $failWinget
        }
        catch {
            if ($_.Exception.Message -notmatch 'exit code 1 \(0x00000001\).*postcondition is not satisfied') {
                throw
            }
            $failedAsExpected = $true
        }
        if (-not $failedAsExpected) {
            throw 'Host dependency self-test failed: missing capability did not fail closed.'
        }

        $fakePwsh = Join-Path $root 'pwsh.cmd'
        Set-Content -Encoding Ascii -LiteralPath $fakePwsh -Value @('@echo off', 'echo 7.6.6', 'exit /b 0')
        if (-not (Test-PortablePowerShellCapability -Executable $fakePwsh -ExpectedVersion ([version]'7.6.6'))) {
            throw 'Host dependency self-test failed: exact portable PowerShell version was rejected.'
        }
        if (Test-PortablePowerShellCapability -Executable $fakePwsh -ExpectedVersion ([version]'7.6.5')) {
            throw 'Host dependency self-test failed: wrong portable PowerShell version was accepted.'
        }

        Write-Host 'Bootstrap host dependency self-test passed.'
    }
    finally {
        Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
    }
}

function Get-RunnerRegistrationSecureToken {
    param(
        [string]$ProviderExecutable,
        [string]$ProviderArgumentsJson
    )

    if ($ProviderArgumentsJson -and -not $ProviderExecutable) {
        throw 'RunnerTokenProviderArgumentsJson requires RunnerTokenProviderExecutable.'
    }

    if (-not $ProviderExecutable) {
        Write-Host ''
        Write-Host 'Open Settings > Actions > Runners > New self-hosted runner for this repository.'
        Write-Host 'Paste only its short-lived registration token below.'
        $interactiveToken = Read-Host 'GitHub runner registration token' -AsSecureString
        if ($interactiveToken.Length -eq 0) { throw 'Runner registration token is required.' }
        return $interactiveToken
    }

    if (-not [IO.Path]::IsPathRooted($ProviderExecutable)) {
        throw 'Runner token provider executable must be an absolute Windows path.'
    }
    if (-not (Test-Path -LiteralPath $ProviderExecutable -PathType Leaf)) {
        throw 'Runner token provider executable was not found.'
    }

    $providerArguments = @()
    if ($ProviderArgumentsJson) {
        try {
            $decoded = ConvertFrom-Json -InputObject $ProviderArgumentsJson
        }
        catch {
            throw 'Runner token provider arguments must be a JSON array of strings.'
        }
        if ($decoded -is [string]) {
            throw 'Runner token provider arguments must be a JSON array of strings.'
        }
        foreach ($argument in @($decoded)) {
            if ($null -eq $argument) {
                throw 'Runner token provider arguments must not contain null.'
            }
            $providerArguments += [string]$argument
        }
    }

    Write-Host 'Retrieving short-lived GitHub runner registration token from the configured out-of-band provider.'
    $providerOutput = $null
    $plainProviderToken = $null
    try {
        $providerOutput = @(& $ProviderExecutable @providerArguments 2>$null)
        $providerExitCode = $LASTEXITCODE
        if ($providerExitCode -ne 0) {
            throw "Runner token provider failed with exit code $providerExitCode. Provider output is intentionally suppressed."
        }

        $plainProviderToken = (($providerOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
        if (-not $plainProviderToken) {
            throw 'Runner token provider returned an empty value.'
        }
        if ($plainProviderToken -match '\s') {
            throw 'Runner token provider must return exactly one token with no surrounding or embedded whitespace.'
        }

        return ConvertTo-SecureString -String $plainProviderToken -AsPlainText -Force
    }
    finally {
        $plainProviderToken = $null
        $providerOutput = $null
    }
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
    if (-not $hasConfig) { return $null }

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

if ($SelfTest) {
    Invoke-HostDependencySelfTest
    exit 0
}

Assert-Administrator
if (-not [Environment]::Is64BitOperatingSystem) {
    throw 'LAB-1 requires 64-bit Windows.'
}

$tempRoot = Join-Path $env:TEMP ('mish-lab-bootstrap-' + [guid]::NewGuid().ToString('N'))
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
    $cargoHome = Join-Path $toolsRoot 'cargo'
    $rustupHome = Join-Path $toolsRoot 'rustup'
    $gradleHome = Join-Path $toolsRoot ('gradle-' + [string]$manifest.gradle.version)

    New-Item -ItemType Directory -Force -Path $runnerRoot, $toolsRoot, $cargoHome, $rustupHome, $sdkRoot | Out-Null

    Ensure-WingetPackage -Id ([string]$manifest.git.winget_id) -CapabilityName 'Git' `
        -ReadyScript { Test-GitCapability -MinimumVersion ([version]([string]$manifest.git.minimum_version)) }
    Ensure-WingetPackage -Id ([string]$manifest.java.winget_id) -CapabilityName 'Temurin JDK' `
        -ReadyScript { Test-JavaCapability -Major ([int]$manifest.java.major) }
    Refresh-ProcessPath

    $powerShellExe = Ensure-PortablePowerShell -Manifest $manifest.powershell -ToolsRoot $toolsRoot -TempRoot $tempRoot
    Refresh-ProcessPath

    $jdkPath = Get-JdkPath -Major ([int]$manifest.java.major)
    if (-not $jdkPath) { throw 'Temurin JDK 17 was not found after materialization.' }
    Set-MachineVariable -Name 'JAVA_HOME' -Value $jdkPath
    Add-MachinePath -PathEntry (Join-Path $jdkPath 'bin')

    if (-not (Test-Path -LiteralPath (Join-Path $gradleHome 'bin\gradle.bat'))) {
        $gradleZip = Join-Path $tempRoot ([string]$manifest.gradle.asset)
        Get-RemoteFile -Uri ([string]$manifest.gradle.url) -OutFile $gradleZip -Sha256 ([string]$manifest.gradle.sha256)
        Expand-Archive -LiteralPath $gradleZip -DestinationPath $toolsRoot -Force
    }
    Add-MachinePath -PathEntry (Join-Path $gradleHome 'bin')

    $sdkManager = Join-Path $sdkRoot 'cmdline-tools\latest\bin\sdkmanager.bat'
    if (-not (Test-Path -LiteralPath $sdkManager)) {
        $androidZip = Join-Path $tempRoot ([string]$manifest.android.commandline_tools_asset)
        $androidExtract = Join-Path $tempRoot 'android-tools'
        Get-RemoteFile -Uri ([string]$manifest.android.commandline_tools_url) `
            -OutFile $androidZip -Sha256 ([string]$manifest.android.commandline_tools_sha256)
        New-Item -ItemType Directory -Force -Path $androidExtract | Out-Null
        Expand-Archive -LiteralPath $androidZip -DestinationPath $androidExtract -Force
        $latest = Join-Path $sdkRoot 'cmdline-tools\latest'
        New-Item -ItemType Directory -Force -Path $latest | Out-Null
        Copy-Item -Recurse -Force -Path (Join-Path $androidExtract 'cmdline-tools\*') -Destination $latest
    }

    Set-MachineVariable -Name 'ANDROID_SDK_ROOT' -Value $sdkRoot
    Set-MachineVariable -Name 'ANDROID_HOME' -Value $sdkRoot
    Add-MachinePath -PathEntry (Join-Path $sdkRoot 'platform-tools')
    Add-MachinePath -PathEntry (Join-Path $sdkRoot 'cmdline-tools\latest\bin')

    Write-Host 'Android SDK licenses may require acceptance in this console.'
    Invoke-NativeChecked -FilePath $sdkManager -Arguments @("--sdk_root=$sdkRoot", '--licenses')
    $sdkPackages = @($manifest.android.packages | ForEach-Object { [string]$_ })
    Invoke-NativeChecked -FilePath $sdkManager -Arguments (@("--sdk_root=$sdkRoot") + $sdkPackages)

    Set-MachineVariable -Name 'RUSTUP_HOME' -Value $rustupHome
    Set-MachineVariable -Name 'CARGO_HOME' -Value $cargoHome
    Add-MachinePath -PathEntry (Join-Path $cargoHome 'bin')

    $rustupInit = Join-Path $tempRoot 'rustup-init.exe'
    $rustupShaFile = Join-Path $tempRoot 'rustup-init.exe.sha256'
    Get-RemoteFile -Uri ([string]$manifest.rust.rustup_init_url) -OutFile $rustupInit
    Get-RemoteFile -Uri ([string]$manifest.rust.rustup_init_sha_url) -OutFile $rustupShaFile
    $shaMatch = [regex]::Match((Get-Content -Raw -LiteralPath $rustupShaFile), '(?i)\b[0-9a-f]{64}\b')
    if (-not $shaMatch.Success) { throw 'rustup-init SHA-256 sidecar did not contain a digest.' }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $rustupInit).Hash.ToLowerInvariant() -ne $shaMatch.Value.ToLowerInvariant()) {
        throw 'rustup-init SHA-256 verification failed.'
    }

    $rustup = Join-Path $cargoHome 'bin\rustup.exe'
    $cargo = Join-Path $cargoHome 'bin\cargo.exe'
    if (-not (Test-Path -LiteralPath $rustup -PathType Leaf)) {
        Invoke-NativeChecked -FilePath $rustupInit -Arguments @(
            '-y', '--no-modify-path', '--profile', 'minimal', '--default-toolchain', ([string]$manifest.rust.toolchain)
        )
    }
    Refresh-ProcessPath
    $env:RUSTUP_HOME = $rustupHome
    $env:CARGO_HOME = $cargoHome
    $env:Path = "$(Join-Path $cargoHome 'bin');$env:Path"
    Invoke-NativeChecked -FilePath $rustup -Arguments @('toolchain', 'install', ([string]$manifest.rust.toolchain), '--profile', 'minimal')
    Invoke-NativeChecked -FilePath $rustup -Arguments @('target', 'add', ([string]$manifest.rust.target), '--toolchain', ([string]$manifest.rust.toolchain))

    $cargoNdkText = (& $cargo ('+' + [string]$manifest.rust.toolchain) ndk --version 2>$null | Out-String)
    if ($LASTEXITCODE -ne 0 -or $cargoNdkText -notmatch ([regex]::Escape([string]$manifest.rust.cargo_ndk))) {
        Invoke-NativeChecked -FilePath $cargo -Arguments @(
            ('+' + [string]$manifest.rust.toolchain), 'install', 'cargo-ndk', '--version', ([string]$manifest.rust.cargo_ndk), '--locked'
        )
    }

    Refresh-ProcessPath
    $env:JAVA_HOME = $jdkPath
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:ANDROID_HOME = $sdkRoot
    $env:RUSTUP_HOME = $rustupHome
    $env:CARGO_HOME = $cargoHome

    & icacls.exe $toolsRoot /grant '*S-1-5-20:(OI)(CI)RX' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to grant NetworkService read/execute access to tools root.' }
    & icacls.exe $cargoHome /grant '*S-1-5-20:(OI)(CI)M' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to grant NetworkService modify access to Cargo home.' }

    $service = Get-ConfiguredRunnerService -RunnerRoot $runnerRoot
    if ($service) {
        Write-Host "Existing repository runner registration detected; preserving service $($service.Name) and skipping token retrieval."
    }
    else {
        $runnerAsset = [string]$manifest.runner.asset
        $runnerConfigCmd = Join-Path $runnerRoot 'config.cmd'
        if (-not (Test-Path -LiteralPath $runnerConfigCmd -PathType Leaf)) {
            $runnerZip = Join-Path $tempRoot $runnerAsset
            $runnerUri = "https://github.com/actions/runner/releases/download/v$($manifest.runner.version)/$runnerAsset"
            Get-RemoteFile -Uri $runnerUri -OutFile $runnerZip -Sha256 ([string]$manifest.runner.sha256)
            Expand-Archive -LiteralPath $runnerZip -DestinationPath $runnerRoot -Force
        }

        if (-not $RunnerName) { $RunnerName = 'mish-lab-' + $env:COMPUTERNAME.ToLowerInvariant() }
        $secureToken = Get-RunnerRegistrationSecureToken `
            -ProviderExecutable $RunnerTokenProviderExecutable `
            -ProviderArgumentsJson $RunnerTokenProviderArgumentsJson
        if ($secureToken.Length -eq 0) { throw 'Runner registration token is required.' }

        $bstr = [IntPtr]::Zero
        $plainToken = $null
        try {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
            $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            Push-Location $runnerRoot
            try {
                Invoke-NativeChecked -FilePath $runnerConfigCmd -Arguments @(
                    '--unattended',
                    '--url', 'https://github.com/iamaman11/mobile-proxy-mish',
                    '--token', $plainToken,
                    '--name', $RunnerName,
                    '--labels', ([string]$manifest.host.runner_custom_label),
                    '--work', '_work',
                    '--runasservice',
                    '--windowslogonaccount', 'NT AUTHORITY\NETWORK SERVICE',
                    '--disableupdate'
                )
            }
            finally { Pop-Location }
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
            $plainToken = $null
            if ($secureToken) { $secureToken.Dispose() }
        }

        $service = Get-ConfiguredRunnerService -RunnerRoot $runnerRoot
        if (-not $service) { throw 'Runner registration completed without a valid Windows service.' }
    }

    $serviceName = [string]$service.Name
    $controller = Get-Service -Name $serviceName
    if ($controller.Status -eq 'Running') {
        Restart-Service -Name $serviceName -Force
    }
    else {
        Start-Service -Name $serviceName
    }
    $controller = Get-Service -Name $serviceName
    $controller.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(30))

    if (-not (Test-PortablePowerShellCapability -Executable $powerShellExe -ExpectedVersion ([version]([string]$manifest.powershell.version)))) {
        throw 'LAB-owned portable PowerShell failed its final bootstrap execution postcondition.'
    }

    Write-Host ''
    Write-Host 'LAB-1 Windows bootstrap completed.'
    Write-Host "Runner root: $runnerRoot"
    Write-Host "PowerShell: $powerShellExe"
    Write-Host "Custom label: $($manifest.host.runner_custom_label)"
    Write-Host 'Service identity: NetworkService'
    Write-Host 'Existing runner registrations are reused only when .runner/.service and NetworkService identity are consistent.'
    Write-Host 'No Cloudflare/R2/provider credential was requested or installed.'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}