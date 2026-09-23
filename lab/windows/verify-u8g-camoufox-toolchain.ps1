[CmdletBinding()]
param(
    [string]$RepositoryRoot = '',
    [string]$EvidencePath = (Join-Path $env:RUNNER_TEMP 'mish-u8g-camoufox-toolchain-verify-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Category, [string]$Message) {
    throw "MISH_U8G_CAMOUFOX_VERIFY|$Category|$Message"
}

function Normalize-PackageName([string]$Name) {
    return ([regex]::Replace($Name.ToLowerInvariant(), '[-_.]+', '-'))
}

function Read-Lock([string]$Path) {
    $expected = [ordered]@{}
    foreach ($raw in Get-Content -LiteralPath $Path) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -notmatch '^(?<name>[A-Za-z0-9_.-]+)==(?<version>[^ ]+)\s+--hash=sha256:(?<sha>[0-9a-f]{64})$') {
            Fail 'LOCK_FORMAT' "Unexpected requirements lock line: $line"
        }
        $name = Normalize-PackageName $Matches.name
        if ($expected.Contains($name)) { Fail 'LOCK_DUPLICATE' "Duplicate locked package: $name" }
        $expected[$name] = [ordered]@{ version = $Matches.version; sha256 = $Matches.sha }
    }
    return $expected
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

if ($env:GITHUB_REPOSITORY -ne 'iamaman11/mobile-proxy-mish') {
    Fail 'REPOSITORY_IDENTITY' 'Repository identity mismatch.'
}
if ($env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_REF_PROTECTED -ne 'true') {
    Fail 'TRUST_BOUNDARY' 'Camoufox runner verification requires protected main.'
}
if ($env:GITHUB_SHA -notmatch '^[0-9a-f]{40}$') {
    Fail 'TRUST_BOUNDARY' 'GitHub commit identity is invalid.'
}
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($identity -ine 'NT AUTHORITY\NETWORK SERVICE') {
    Fail 'RUNNER_IDENTITY' 'Camoufox runner verification must execute as NetworkService.'
}

$git = (Get-Command git.exe -ErrorAction Stop).Source
Push-Location $RepositoryRoot
try {
    $head = (& $git rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -ne $env:GITHUB_SHA) {
        Fail 'CHECKOUT_IDENTITY' 'Checkout HEAD does not match GITHUB_SHA.'
    }
    $dirty = @(& $git status --porcelain=v1)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
        Fail 'CHECKOUT_DIRTY' 'Checkout must remain clean during toolchain verification.'
    }
}
finally {
    Pop-Location
}

$manifestPath = Join-Path $RepositoryRoot 'lab\windows\u8g-camoufox-toolchain.json'
$lockPath = Join-Path $RepositoryRoot 'lab\windows\u8g-camoufox-requirements.lock'
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schema -ne 'mish.lab.u8g-camoufox-toolchain/v1') {
    Fail 'MANIFEST_SCHEMA' 'Unexpected Camoufox toolchain manifest schema.'
}
$expected = Read-Lock $lockPath
if ($expected.Count -ne [int]$manifest.python_env.package_count) {
    Fail 'LOCK_COUNT' 'Exact lock package count disagrees with manifest.'
}

$venvRoot = [IO.Path]::GetFullPath([string]$manifest.python_env.install_root)
$browserRoot = [IO.Path]::GetFullPath([string]$manifest.browser.install_root)
$venvPython = Join-Path $venvRoot 'Scripts\python.exe'
$pythonMarkerPath = Join-Path $venvRoot '.mish-u8g-python.json'
$browserMarkerPath = Join-Path $browserRoot '.mish-u8g-browser.json'

foreach ($required in @($venvPython, $pythonMarkerPath, $browserMarkerPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        Fail 'TOOLCHAIN_MISSING' "Required LAB-owned Camoufox artifact is unavailable: $required"
    }
}

$lockSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $lockPath).Hash.ToLowerInvariant()
$pythonMarker = Get-Content -Raw -LiteralPath $pythonMarkerPath | ConvertFrom-Json
if ($pythonMarker.schema -ne 'mish.lab.u8g-camoufox-python/v1' -or
    [string]$pythonMarker.lock_sha256 -ne $lockSha -or
    [int]$pythonMarker.package_count -ne $expected.Count) {
    Fail 'PYTHON_MARKER' 'LAB-owned Camoufox Python marker does not match the accepted lock.'
}

$versionText = (& $venvPython --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionText -ne ('Python ' + [string]$manifest.python.version)) {
    Fail 'PYTHON_VERSION' 'LAB-owned Camoufox Python version mismatch.'
}
$packagesJson = (& $venvPython -m pip --disable-pip-version-check list --format=json 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Fail 'PACKAGE_LIST' 'Unable to inspect LAB-owned Camoufox packages.' }
$actual = [ordered]@{}
foreach ($item in @($packagesJson | ConvertFrom-Json)) {
    $name = Normalize-PackageName ([string]$item.name)
    if ($name -eq 'pip') { continue }
    $actual[$name] = [string]$item.version
}
if ($actual.Count -ne $expected.Count) {
    Fail 'PACKAGE_COUNT' "Expected $($expected.Count) packages, found $($actual.Count)."
}
foreach ($name in $expected.Keys) {
    if (-not $actual.Contains($name) -or [string]$actual[$name] -ne [string]$expected[$name].version) {
        Fail 'PACKAGE_DRIFT' "LAB-owned Camoufox package drift: $name"
    }
}

$browserMarker = Get-Content -Raw -LiteralPath $browserMarkerPath | ConvertFrom-Json
if ($browserMarker.schema -ne 'mish.lab.u8g-camoufox-browser/v1' -or
    [string]$browserMarker.version -ne [string]$manifest.browser.version -or
    [string]$browserMarker.archive_sha256 -ne [string]$manifest.browser.sha256) {
    Fail 'BROWSER_MARKER' 'LAB-owned Camoufox browser marker does not match the pin.'
}
$browserExe = Join-Path $browserRoot ([string]$browserMarker.executable_relative_path)
if (-not (Test-Path -LiteralPath $browserExe -PathType Leaf)) {
    Fail 'BROWSER_EXE' 'LAB-owned Camoufox executable is unavailable to NetworkService.'
}
$exeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $browserExe).Hash.ToLowerInvariant()
if ($exeSha -ne [string]$browserMarker.executable_sha256) {
    Fail 'BROWSER_EXE_DIGEST' 'LAB-owned Camoufox executable digest drifted.'
}
$browserVersionText = (& $browserExe --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $browserVersionText -notmatch [regex]::Escape([string]$manifest.browser.version)) {
    Fail 'BROWSER_VERSION' 'LAB-owned Camoufox browser version mismatch.'
}

$runtimeRoot = Join-Path $env:RUNNER_TEMP ('mish-u8g-camoufox-runtime-' + [guid]::NewGuid().ToString('N'))
$profileRoot = Join-Path $runtimeRoot 'profile'
$localAppData = Join-Path $runtimeRoot 'localappdata'
$appData = Join-Path $runtimeRoot 'appdata'
$userProfile = Join-Path $runtimeRoot 'userprofile'
New-Item -ItemType Directory -Force -Path $profileRoot, $localAppData, $appData, $userProfile | Out-Null

$previous = @{
    HOME = $env:HOME
    USERPROFILE = $env:USERPROFILE
    LOCALAPPDATA = $env:LOCALAPPDATA
    APPDATA = $env:APPDATA
}
$smokePath = Join-Path $runtimeRoot 'smoke.py'
$smoke = @'
import sys
from camoufox.sync_api import Camoufox

exe = sys.argv[1]
with Camoufox(
    headless=True,
    executable_path=exe,
    ff_version=152,
    geoip=False,
    i_know_what_im_doing=True,
) as browser:
    page = browser.new_page()
    page.goto("data:text/plain,U8G", wait_until="load")
    body = page.locator("body").inner_text()
    if body != "U8G":
        raise RuntimeError("unexpected local smoke body")
print("CAMOUFOX_LOCAL_SMOKE=PASS")
'@
[IO.File]::WriteAllText($smokePath, $smoke, [Text.UTF8Encoding]::new($false))

try {
    $env:HOME = $userProfile
    $env:USERPROFILE = $userProfile
    $env:LOCALAPPDATA = $localAppData
    $env:APPDATA = $appData

    $smokeOutput = (& $venvPython $smokePath $browserExe 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $smokeOutput -notmatch 'CAMOUFOX_LOCAL_SMOKE=PASS') {
        Fail 'LOCAL_SMOKE' 'Camoufox local data-URL smoke failed under NetworkService.'
    }

    $evidence = [ordered]@{
        schema = 'mish.lab.u8g-camoufox-toolchain-verify/v1'
        repository = 'iamaman11/mobile-proxy-mish'
        git_commit = $env:GITHUB_SHA
        runner_identity = 'NT AUTHORITY\NETWORK SERVICE'
        python = [ordered]@{
            version = [string]$manifest.python.version
            camoufox = [string]$manifest.camoufox_python.version
            playwright = [string]$manifest.playwright.version
            package_count = $expected.Count
            lock_sha256 = $lockSha
        }
        browser = [ordered]@{
            version = [string]$manifest.browser.version
            archive_sha256 = [string]$manifest.browser.sha256
            executable_sha256 = $exeSha
            executable_path_class = 'LAB_OWNED'
        }
        smoke = [ordered]@{
            launch = 'PASS'
            target = 'data_url'
            external_network = $false
            isolated_runtime_state = $true
            user_cache_used = $false
            camoufox_fetch_used = $false
        }
        mutations = [ordered]@{
            packages_installed = $false
            browser_downloaded = $false
            persistent_files = $false
            product = $false
            device = $false
            network = $false
            services = $false
        }
        secrets_read = $false
    }

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($EvidencePath),
        (($evidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host 'MISH_U8G_CAMOUFOX_TOOLCHAIN_VERIFY=PASS'
    Write-Host ('MISH_U8G_CAMOUFOX_PACKAGE_COUNT=' + $expected.Count)
    Write-Host ('MISH_U8G_CAMOUFOX_LOCK_SHA256=' + $lockSha)
    Write-Host ('MISH_U8G_CAMOUFOX_BROWSER_EXE_SHA256=' + $exeSha)
    Write-Host 'MISH_U8G_CAMOUFOX_USER_CACHE_USED=NO'
    Write-Host 'MISH_U8G_CAMOUFOX_FETCH_USED=NO'
    Write-Host 'MISH_U8G_CAMOUFOX_EXTERNAL_NETWORK=NO'
}
finally {
    foreach ($name in @('HOME','USERPROFILE','LOCALAPPDATA','APPDATA')) {
        $value = $previous[$name]
        if ($null -eq $value) {
            Remove-Item ("Env:" + $name) -ErrorAction SilentlyContinue
        }
        else {
            Set-Item ("Env:" + $name) -Value $value
        }
    }
    if (Test-Path -LiteralPath $runtimeRoot) {
        Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
