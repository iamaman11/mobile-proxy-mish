[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$RepositoryCommit,
    [ValidatePattern('^[A-Za-z0-9._-]{0,64}$')]
    [string]$RunnerName = '',
    [string]$RunnerTokenProviderExecutable = '',
    [string]$RunnerTokenProviderArgumentsJson = ''
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

function Install-WingetPackage {
    param([Parameter(Mandatory)][string]$Id)
    $winget = Get-Command winget.exe -ErrorAction Stop
    & $winget.Source install --id $Id --exact --silent --scope machine `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $Id."
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

    Install-WingetPackage -Id ([string]$manifest.git.winget_id)
    Install-WingetPackage -Id ([string]$manifest.powershell.winget_id)
    Install-WingetPackage -Id ([string]$manifest.java.winget_id)
    Refresh-ProcessPath

    $jdk = Get-ChildItem 'C:\Program Files\Eclipse Adoptium' -Directory -Filter 'jdk-17*' -ErrorAction Stop |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if (-not $jdk) { throw 'Temurin JDK 17 was not found after installation.' }
    Set-MachineVariable -Name 'JAVA_HOME' -Value $jdk.FullName
    Add-MachinePath -PathEntry (Join-Path $jdk.FullName 'bin')

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

    Invoke-NativeChecked -FilePath $rustupInit -Arguments @(
        '-y', '--no-modify-path', '--profile', 'minimal', '--default-toolchain', ([string]$manifest.rust.toolchain)
    )
    Refresh-ProcessPath
    $env:RUSTUP_HOME = $rustupHome
    $env:CARGO_HOME = $cargoHome
    $env:Path = "$(Join-Path $cargoHome 'bin');$env:Path"
    $rustup = Join-Path $cargoHome 'bin\rustup.exe'
    $cargo = Join-Path $cargoHome 'bin\cargo.exe'
    Invoke-NativeChecked -FilePath $rustup -Arguments @('target', 'add', ([string]$manifest.rust.target))
    Invoke-NativeChecked -FilePath $cargo -Arguments @(
        ('+' + [string]$manifest.rust.toolchain), 'install', 'cargo-ndk', '--version', ([string]$manifest.rust.cargo_ndk), '--locked'
    )

    Refresh-ProcessPath
    $env:JAVA_HOME = $jdk.FullName
    $env:ANDROID_SDK_ROOT = $sdkRoot
    $env:ANDROID_HOME = $sdkRoot
    $env:RUSTUP_HOME = $rustupHome
    $env:CARGO_HOME = $cargoHome

    # The runner service uses the built-in NetworkService identity. The runner itself
    # grants runner/_work ACLs. Only the tool access required by this fixture is added.
    & icacls.exe $toolsRoot /grant '*S-1-5-20:(OI)(CI)RX' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to grant NetworkService read/execute access to tools root.' }
    & icacls.exe $cargoHome /grant '*S-1-5-20:(OI)(CI)M' /T /C | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Failed to grant NetworkService modify access to Cargo home.' }

    $runnerConfig = Join-Path $runnerRoot '.runner'
    if (Test-Path -LiteralPath $runnerConfig) {
        throw 'Runner root is already configured. Refusing implicit replacement.'
    }

    $runnerAsset = [string]$manifest.runner.asset
    $runnerZip = Join-Path $tempRoot $runnerAsset
    $runnerUri = "https://github.com/actions/runner/releases/download/v$($manifest.runner.version)/$runnerAsset"
    Get-RemoteFile -Uri $runnerUri -OutFile $runnerZip -Sha256 ([string]$manifest.runner.sha256)
    Expand-Archive -LiteralPath $runnerZip -DestinationPath $runnerRoot -Force

    if (-not $RunnerName) { $RunnerName = 'mish-lab-' + $env:COMPUTERNAME.ToLowerInvariant() }

    $secureToken = Get-RunnerRegistrationSecureToken `
        -ProviderExecutable $RunnerTokenProviderExecutable `
        -ProviderArgumentsJson $RunnerTokenProviderArgumentsJson
    if ($secureToken.Length -eq 0) { throw 'Runner registration token is required.' }

    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    try {
        $plainToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        Push-Location $runnerRoot
        try {
            Invoke-NativeChecked -FilePath (Join-Path $runnerRoot 'config.cmd') -Arguments @(
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
        $secureToken.Dispose()
    }

    $serviceFile = Join-Path $runnerRoot '.service'
    if (-not (Test-Path -LiteralPath $serviceFile)) { throw 'Runner service marker was not created.' }
    $serviceName = (Get-Content -Raw -LiteralPath $serviceFile).Trim()
    $service = Get-CimInstance Win32_Service -Filter ("Name='" + $serviceName.Replace("'", "''") + "'")
    if (-not $service) { throw 'Configured runner service was not found.' }
    if ($service.StartName -ine 'NT AUTHORITY\NETWORK SERVICE') { throw 'Runner service identity is not NetworkService.' }
    if ((Get-Service -Name $serviceName).Status -ne 'Running') { Start-Service -Name $serviceName }

    Write-Host ''
    Write-Host 'LAB-1 Windows bootstrap completed.'
    Write-Host "Runner root: $runnerRoot"
    Write-Host "Custom label: $($manifest.host.runner_custom_label)"
    Write-Host 'Service identity: NetworkService'
    Write-Host 'No Cloudflare/R2/provider credential was requested or installed.'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tempRoot -ErrorAction SilentlyContinue
}
