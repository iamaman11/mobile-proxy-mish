[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{40}$')]
    [string]$RepositoryCommit,
    [string]$RepositoryRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Fail([string]$Category, [string]$Message) {
    throw "MISH_U8G_CAMOUFOX_MATERIALIZE|$Category|$Message"
}

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Fail 'ADMIN_REQUIRED' 'Camoufox LAB materialization requires an elevated administrator console.'
    }
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
        if ($expected.Contains($name)) {
            Fail 'LOCK_DUPLICATE' "Duplicate locked package: $name"
        }
        $expected[$name] = [ordered]@{
            version = $Matches.version
            sha256 = $Matches.sha
        }
    }
    return $expected
}

function Assert-PythonEnvironment(
    [string]$VenvPython,
    [System.Collections.IDictionary]$Expected,
    [string]$ExpectedPythonVersion
) {
    if (-not (Test-Path -LiteralPath $VenvPython -PathType Leaf)) {
        Fail 'VENV_PYTHON_MISSING' 'LAB-owned Camoufox venv Python is missing.'
    }
    $versionText = (& $VenvPython --version 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $versionText -ne ('Python ' + $ExpectedPythonVersion)) {
        Fail 'VENV_PYTHON_VERSION' 'LAB-owned Camoufox venv Python version mismatch.'
    }

    $json = (& $VenvPython -m pip --disable-pip-version-check list --format=json 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) {
        Fail 'VENV_PACKAGE_LIST' 'Unable to inspect LAB-owned Camoufox Python packages.'
    }
    $actual = [ordered]@{}
    foreach ($item in @($json | ConvertFrom-Json)) {
        $name = Normalize-PackageName ([string]$item.name)
        if ($name -eq 'pip') { continue }
        $actual[$name] = [string]$item.version
    }

    if ($actual.Count -ne $Expected.Count) {
        Fail 'VENV_PACKAGE_COUNT' "Expected $($Expected.Count) locked packages, found $($actual.Count)."
    }
    foreach ($name in $Expected.Keys) {
        if (-not $actual.Contains($name)) {
            Fail 'VENV_PACKAGE_MISSING' "Locked package missing: $name"
        }
        if ([string]$actual[$name] -ne [string]$Expected[$name].version) {
            Fail 'VENV_PACKAGE_VERSION' "Locked package version mismatch: $name"
        }
    }
}

function Assert-Browser(
    [string]$BrowserRoot,
    [string]$ExpectedVersion,
    [string]$ExpectedArchiveSha
) {
    $markerPath = Join-Path $BrowserRoot '.mish-u8g-browser.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Fail 'BROWSER_MARKER_MISSING' 'LAB-owned Camoufox browser marker is missing.'
    }
    $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
    if ([string]$marker.version -ne $ExpectedVersion -or [string]$marker.archive_sha256 -ne $ExpectedArchiveSha) {
        Fail 'BROWSER_MARKER_MISMATCH' 'LAB-owned Camoufox browser marker does not match the pin.'
    }
    $exe = Join-Path $BrowserRoot ([string]$marker.executable_relative_path)
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
        Fail 'BROWSER_EXE_MISSING' 'LAB-owned Camoufox executable is missing.'
    }
    if ([string]$marker.identity_source -ne 'official_archive_sha256') {
        Fail 'BROWSER_IDENTITY_SOURCE' 'LAB-owned Camoufox browser marker has an unexpected identity source.'
    }
    $propertiesPath = Join-Path $BrowserRoot 'properties.json'
    if (-not (Test-Path -LiteralPath $propertiesPath -PathType Leaf)) {
        Fail 'BROWSER_PROPERTIES_MISSING' 'LAB-owned Camoufox bundle is missing properties.json beside the executable.'
    }
    $exeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
    if ($exeSha -ne [string]$marker.executable_sha256) {
        Fail 'BROWSER_EXE_DIGEST' 'LAB-owned Camoufox executable digest does not match its materialization marker.'
    }
    return $exe
}

Assert-Administrator

if (-not $RepositoryRoot) {
    $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

$git = (Get-Command git.exe -ErrorAction Stop).Source
Push-Location $RepositoryRoot
try {
    $head = (& $git rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -ne $RepositoryCommit) {
        Fail 'REPOSITORY_IDENTITY' 'Repository HEAD does not match the explicitly accepted commit.'
    }
    $dirty = @(& $git status --porcelain=v1)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
        Fail 'REPOSITORY_DIRTY' 'Repository must be clean before LAB toolchain materialization.'
    }
}
finally {
    Pop-Location
}

$manifestPath = Join-Path $RepositoryRoot 'lab\windows\u8g-camoufox-toolchain.json'
$lockPath = Join-Path $RepositoryRoot 'lab\windows\u8g-camoufox-requirements.lock'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
    Fail 'INPUT_MISSING' 'Camoufox toolchain manifest or exact requirements lock is missing.'
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schema -ne 'mish.lab.u8g-camoufox-toolchain/v1') {
    Fail 'MANIFEST_SCHEMA' 'Unexpected Camoufox toolchain manifest schema.'
}

$python = [string]$manifest.python.executable
$pythonVersion = [string]$manifest.python.version
$pipVersion = [string]$manifest.python.pip_version
$venvRoot = [IO.Path]::GetFullPath([string]$manifest.python_env.install_root)
$browserRoot = [IO.Path]::GetFullPath([string]$manifest.browser.install_root)
$toolsRoot = [IO.Path]::GetFullPath('C:\mish-lab\tools').TrimEnd('\')
foreach ($path in @($venvRoot, $browserRoot)) {
    if (-not $path.StartsWith($toolsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Fail 'INSTALL_BOUNDARY' 'Camoufox toolchain must remain under C:\mish-lab\tools.'
    }
}

$expected = Read-Lock $lockPath
if ($expected.Count -ne [int]$manifest.python_env.package_count) {
    Fail 'LOCK_COUNT' 'Requirements lock package count disagrees with the manifest.'
}
if (-not $expected.Contains('camoufox') -or $expected['camoufox'].version -ne [string]$manifest.camoufox_python.version) {
    Fail 'LOCK_CAMOUFOX' 'Camoufox direct pin disagrees with the exact lock.'
}
if (-not $expected.Contains('playwright') -or $expected['playwright'].version -ne [string]$manifest.playwright.version) {
    Fail 'LOCK_PLAYWRIGHT' 'Playwright direct pin disagrees with the exact lock.'
}

if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    Fail 'PYTHON_MISSING' 'Pinned machine Python is unavailable.'
}
$pythonText = (& $python --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $pythonText -ne ('Python ' + $pythonVersion)) {
    Fail 'PYTHON_VERSION' 'Pinned machine Python version mismatch.'
}
$pipText = (& $python -m pip --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $pipText -notmatch ('^pip\s+' + [regex]::Escape($pipVersion) + '\b')) {
    Fail 'PIP_VERSION' 'Pinned machine pip version mismatch.'
}

$lockSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $lockPath).Hash.ToLowerInvariant()
$tempRoot = Join-Path $env:TEMP ('mish-u8g-camoufox-materialize-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

$createdVenv = $false
$createdBrowser = $false

try {
    if (Test-Path -LiteralPath $venvRoot) {
        $markerPath = Join-Path $venvRoot '.mish-u8g-python.json'
        if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
            Fail 'VENV_PREEXISTING_UNTRUSTED' 'Existing Camoufox Python environment has no materialization marker.'
        }
        $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
        if ([string]$marker.lock_sha256 -ne $lockSha -or [string]$marker.python_version -ne $pythonVersion) {
            Fail 'VENV_PREEXISTING_MISMATCH' 'Existing Camoufox Python environment disagrees with the accepted lock.'
        }
        Assert-PythonEnvironment -VenvPython (Join-Path $venvRoot 'Scripts\python.exe') -Expected $expected -ExpectedPythonVersion $pythonVersion
        Write-Host 'Existing LAB-owned Camoufox Python environment satisfies the exact lock; install skipped.'
    }
    else {
        & $python -m venv $venvRoot
        if ($LASTEXITCODE -ne 0) {
            Fail 'VENV_CREATE' 'Failed to create LAB-owned Camoufox Python environment.'
        }
        $createdVenv = $true
        $venvPython = Join-Path $venvRoot 'Scripts\python.exe'
        $venvPipText = (& $venvPython -m pip --version 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $venvPipText -notmatch ('^pip\s+' + [regex]::Escape($pipVersion) + '\b')) {
            Fail 'VENV_PIP_VERSION' 'New Camoufox venv did not inherit the pinned pip version.'
        }

        $previousPlaywrightBrowsersPath = $env:PLAYWRIGHT_BROWSERS_PATH
        try {
            $env:PLAYWRIGHT_BROWSERS_PATH = '0'
            $pipArgs = @(
                '-m', 'pip', '--isolated', 'install',
                '--disable-pip-version-check',
                '--no-input',
                '--no-cache-dir',
                '--only-binary=:all:',
                '--require-hashes',
                '--index-url', 'https://pypi.org/simple',
                '-r', $lockPath
            )
            & $venvPython @pipArgs
            if ($LASTEXITCODE -ne 0) {
                Fail 'VENV_INSTALL' 'Exact hashed Camoufox wheel installation failed.'
            }
        }
        finally {
            if ($null -eq $previousPlaywrightBrowsersPath) {
                Remove-Item Env:PLAYWRIGHT_BROWSERS_PATH -ErrorAction SilentlyContinue
            }
            else {
                $env:PLAYWRIGHT_BROWSERS_PATH = $previousPlaywrightBrowsersPath
            }
        }

        Assert-PythonEnvironment -VenvPython $venvPython -Expected $expected -ExpectedPythonVersion $pythonVersion

        $marker = [ordered]@{
            schema = 'mish.lab.u8g-camoufox-python/v1'
            python_version = $pythonVersion
            pip_version = $pipVersion
            camoufox_version = [string]$manifest.camoufox_python.version
            playwright_version = [string]$manifest.playwright.version
            package_count = $expected.Count
            lock_sha256 = $lockSha
        }
        [IO.File]::WriteAllText(
            (Join-Path $venvRoot '.mish-u8g-python.json'),
            (($marker | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
    }

    if (Test-Path -LiteralPath $browserRoot) {
        [void](Assert-Browser -BrowserRoot $browserRoot -ExpectedVersion ([string]$manifest.browser.version) -ExpectedArchiveSha ([string]$manifest.browser.sha256))
        Write-Host 'Existing LAB-owned Camoufox browser satisfies the exact archive pin; download skipped.'
    }
    else {
        $archive = Join-Path $tempRoot ([string]$manifest.browser.asset)
        $curl = (Get-Command curl.exe -ErrorAction Stop).Source
        $curlArgs = @(
            '--fail', '--location', '--retry', '3', '--retry-delay', '2',
            '--output', $archive,
            [string]$manifest.browser.url
        )
        & $curl @curlArgs
        if ($LASTEXITCODE -ne 0) {
            Fail 'BROWSER_DOWNLOAD' 'Pinned Camoufox browser archive download failed.'
        }
        $archiveSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $archive).Hash.ToLowerInvariant()
        if ($archiveSha -ne [string]$manifest.browser.sha256) {
            Fail 'BROWSER_ARCHIVE_DIGEST' 'Pinned Camoufox browser archive digest mismatch.'
        }

        $extractRoot = Join-Path $tempRoot 'browser-extract'
        New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
        Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force

        $executables = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter 'camoufox.exe')
        if ($executables.Count -ne 1) {
            Fail 'BROWSER_ARCHIVE_LAYOUT' 'Pinned Camoufox archive must contain exactly one camoufox.exe.'
        }
        $bundleRoot = $executables[0].Directory.FullName
        $relativeExe = [IO.Path]::GetRelativePath($bundleRoot, $executables[0].FullName)
        if ($relativeExe -match '^\.\.') {
            Fail 'BROWSER_ARCHIVE_LAYOUT' 'Camoufox executable escaped the selected bundle root.'
        }

        Move-Item -LiteralPath $bundleRoot -Destination $browserRoot
        $createdBrowser = $true

        $finalExe = Join-Path $browserRoot $relativeExe
        if (-not (Test-Path -LiteralPath $finalExe -PathType Leaf)) {
            Fail 'BROWSER_EXE_MISSING' 'Materialized Camoufox executable is missing.'
        }
        $propertiesPath = Join-Path $browserRoot 'properties.json'
        if (-not (Test-Path -LiteralPath $propertiesPath -PathType Leaf)) {
            Fail 'BROWSER_PROPERTIES_MISSING' 'Pinned Camoufox archive is missing properties.json beside the executable.'
        }
        $exeSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $finalExe).Hash.ToLowerInvariant()

        $browserMarker = [ordered]@{
            schema = 'mish.lab.u8g-camoufox-browser/v1'
            identity_source = 'official_archive_sha256'
            version = [string]$manifest.browser.version
            archive_asset = [string]$manifest.browser.asset
            archive_sha256 = [string]$manifest.browser.sha256
            executable_relative_path = $relativeExe
            executable_sha256 = $exeSha
        }
        [IO.File]::WriteAllText(
            (Join-Path $browserRoot '.mish-u8g-browser.json'),
            (($browserMarker | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )

        [void](Assert-Browser -BrowserRoot $browserRoot -ExpectedVersion ([string]$manifest.browser.version) -ExpectedArchiveSha ([string]$manifest.browser.sha256))
    }

    $venvAcl = Get-Acl -LiteralPath $venvRoot
    $browserAcl = Get-Acl -LiteralPath $browserRoot
    if ($venvAcl.AreAccessRulesProtected -or $browserAcl.AreAccessRulesProtected) {
        Fail 'ACL_INHERITANCE' 'LAB-owned Camoufox roots must inherit the existing C:\mish-lab\tools ACL boundary.'
    }

    Write-Host 'MISH_U8G_CAMOUFOX_MATERIALIZATION=PASS'
    Write-Host ('MISH_U8G_CAMOUFOX_VENV=' + $venvRoot)
    Write-Host ('MISH_U8G_CAMOUFOX_BROWSER=' + $browserRoot)
    Write-Host ('MISH_U8G_CAMOUFOX_PACKAGE_COUNT=' + $expected.Count)
    Write-Host ('MISH_U8G_CAMOUFOX_LOCK_SHA256=' + $lockSha)
    Write-Host ('MISH_U8G_CAMOUFOX_BROWSER_ARCHIVE_SHA256=' + [string]$manifest.browser.sha256)
    Write-Host 'MISH_U8G_CAMOUFOX_BROWSER_IDENTITY=OFFICIAL_ARCHIVE_SHA256'
    Write-Host 'MISH_U8G_CAMOUFOX_FETCH_USED=NO'
}
catch {
    if ($createdVenv -and (Test-Path -LiteralPath $venvRoot)) {
        Remove-Item -LiteralPath $venvRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($createdBrowser -and (Test-Path -LiteralPath $browserRoot)) {
        Remove-Item -LiteralPath $browserRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
