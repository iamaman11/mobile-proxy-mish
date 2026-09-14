[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'toolchain.json'),
    [string]$StateRoot = 'C:\mish-lab\runner\_work\.mish-device-candidate\tools',
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$ProgressPreference = 'SilentlyContinue'

function Test-ExactPowerShell {
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

function Publish-ResolvedPowerShell {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][version]$Version,
        [Parameter(Mandatory)][string]$Source
    )

    $resolved = [IO.Path]::GetFullPath($Executable)
    if (-not (Test-ExactPowerShell -Executable $resolved -ExpectedVersion $Version)) {
        throw "Resolved PowerShell does not satisfy exact version $Version."
    }

    if ($env:GITHUB_ENV) {
        Add-Content -LiteralPath $env:GITHUB_ENV -Encoding utf8 -Value "LAB_POWERSHELL_EXE=$resolved"
    }

    [pscustomobject]@{
        result = 'PASS'
        version = $Version.ToString()
        executable = $resolved
        source = $Source
        materialized = ($Source -eq 'lab-state')
    } | ConvertTo-Json -Compress
}

$manifestFullPath = [IO.Path]::GetFullPath($ManifestPath)
if (-not (Test-Path -LiteralPath $manifestFullPath -PathType Leaf)) {
    throw "LAB toolchain manifest is missing: $manifestFullPath"
}
$manifest = Get-Content -Raw -LiteralPath $manifestFullPath | ConvertFrom-Json
if ([string]$manifest.schema -ne 'mish.lab.windows-toolchain/v1') {
    throw 'Unexpected LAB toolchain manifest schema.'
}

$version = [version]([string]$manifest.powershell.version)
$asset = [string]$manifest.powershell.asset
$url = [string]$manifest.powershell.url
$expectedSha256 = ([string]$manifest.powershell.sha256).ToLowerInvariant()
if ($asset -ne ('PowerShell-{0}-win-x64.zip' -f $version.ToString())) {
    throw 'Pinned PowerShell asset does not match the exact x64 version.'
}
if ($url -ne ('https://github.com/PowerShell/PowerShell/releases/download/v{0}/{1}' -f $version.ToString(), $asset)) {
    throw 'Pinned PowerShell URL does not match the exact official release coordinate.'
}
if ($expectedSha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Pinned PowerShell SHA-256 is invalid.'
}

$canonical = Join-Path ([string]$manifest.host.tools_root) ('powershell-{0}\pwsh.exe' -f $version.ToString())
if (Test-ExactPowerShell -Executable $canonical -ExpectedVersion $version) {
    Publish-ResolvedPowerShell -Executable $canonical -Version $version -Source 'canonical'
    exit 0
}

$pathPwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction SilentlyContinue
if ($pathPwsh -and (Test-ExactPowerShell -Executable $pathPwsh.Source -ExpectedVersion $version)) {
    Publish-ResolvedPowerShell -Executable $pathPwsh.Source -Version $version -Source 'path'
    exit 0
}

if ($VerifyOnly) {
    [pscustomobject]@{
        result = 'PASS'
        version = $version.ToString()
        canonical_available = $false
        exact_path_available = $false
        would_materialize = $true
    } | ConvertTo-Json -Compress
    exit 0
}

$state = [IO.Path]::GetFullPath($StateRoot)
$powerShellHome = Join-Path $state ('powershell-{0}' -f $version.ToString())
$resolvedExe = Join-Path $powerShellHome 'pwsh.exe'
if (Test-ExactPowerShell -Executable $resolvedExe -ExpectedVersion $version) {
    Publish-ResolvedPowerShell -Executable $resolvedExe -Version $version -Source 'lab-state'
    exit 0
}

New-Item -ItemType Directory -Force -Path $state | Out-Null
if (Test-Path -LiteralPath $powerShellHome) {
    Remove-Item -Recurse -Force -LiteralPath $powerShellHome
}
New-Item -ItemType Directory -Force -Path $powerShellHome | Out-Null

$downloadRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }
$archive = Join-Path $downloadRoot $asset
Remove-Item -Force -LiteralPath $archive -ErrorAction SilentlyContinue

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
if ($actualSha256 -ne $expectedSha256) {
    Remove-Item -Force -LiteralPath $archive -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $powerShellHome -ErrorAction SilentlyContinue
    throw 'Pinned PowerShell download SHA-256 mismatch.'
}

Expand-Archive -LiteralPath $archive -DestinationPath $powerShellHome -Force
Remove-Item -Force -LiteralPath $archive -ErrorAction SilentlyContinue

if (-not (Test-ExactPowerShell -Executable $resolvedExe -ExpectedVersion $version)) {
    Remove-Item -Recurse -Force -LiteralPath $powerShellHome -ErrorAction SilentlyContinue
    throw "Pinned PowerShell $version failed its execution postcondition after materialization."
}

Publish-ResolvedPowerShell -Executable $resolvedExe -Version $version -Source 'lab-state'
