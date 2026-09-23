[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'u8g-camoufox-toolchain.json'),
    [string]$EvidencePath = (Join-Path $env:RUNNER_TEMP 'mish-u8g-camoufox-resolution-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Category, [string]$Message) {
    throw "MISH_U8G_CAMOUFOX_RESOLUTION|$Category|$Message"
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    Fail 'MANIFEST_MISSING' 'Camoufox toolchain manifest is missing.'
}

$manifest = Get-Content -Raw -LiteralPath $ManifestPath | ConvertFrom-Json
if ($manifest.schema -ne 'mish.lab.u8g-camoufox-toolchain/v1') {
    Fail 'MANIFEST_SCHEMA' 'Unexpected Camoufox toolchain manifest schema.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($identity -ine 'NT AUTHORITY\NETWORK SERVICE') {
    Fail 'RUNNER_IDENTITY' 'Resolution must execute as NetworkService.'
}

$python = [string]$manifest.python.executable
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    Fail 'PYTHON_MISSING' 'Pinned Python executable is unavailable.'
}

$versionText = (& $python --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionText -ne ('Python ' + [string]$manifest.python.version)) {
    Fail 'PYTHON_VERSION' 'Pinned Python version mismatch.'
}

$pipText = (& $python -m pip --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $pipText -notmatch ('^pip\s+' + [regex]::Escape([string]$manifest.python.pip_version) + '\b')) {
    Fail 'PIP_VERSION' 'Pinned pip version mismatch.'
}

$tempRoot = Join-Path $env:RUNNER_TEMP ('mish-u8g-camoufox-resolution-' + [guid]::NewGuid().ToString('N'))
$reportPath = Join-Path $tempRoot 'pip-report.json'
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
    $requirements = @(
        ('camoufox==' + [string]$manifest.camoufox_python.version),
        ('playwright==' + [string]$manifest.playwright.version)
    )

    $args = @(
        '-m', 'pip', 'install',
        '--dry-run',
        '--ignore-installed',
        '--only-binary=:all:',
        '--no-cache-dir',
        '--disable-pip-version-check',
        '--report', $reportPath
    ) + $requirements

    & $python @args
    if ($LASTEXITCODE -ne 0) {
        Fail 'DEPENDENCY_RESOLUTION_FAILED' 'Windows/Python dependency resolution failed.'
    }
    if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) {
        Fail 'REPORT_MISSING' 'pip did not produce a resolution report.'
    }

    $report = Get-Content -Raw -LiteralPath $reportPath | ConvertFrom-Json
    $packages = @()
    foreach ($item in @($report.install)) {
        $name = [string]$item.metadata.name
        $version = [string]$item.metadata.version
        $url = [string]$item.download_info.url
        $sha = $null
        if ($item.download_info.archive_info.hashes.sha256) {
            $sha = [string]$item.download_info.archive_info.hashes.sha256
        }
        elseif ($item.download_info.archive_info.hash -match '^sha256=(.+)$') {
            $sha = $Matches[1]
        }
        if (-not $name -or -not $version -or -not $url -or -not $sha) {
            Fail 'REPORT_INCOMPLETE' 'Resolved package lacks name/version/url/sha256.'
        }
        $packages += [ordered]@{
            name = $name.ToLowerInvariant()
            version = $version
            filename = [IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
            sha256 = $sha.ToLowerInvariant()
        }
    }

    $camoufox = @($packages | Where-Object name -eq 'camoufox')
    $playwright = @($packages | Where-Object name -eq 'playwright')
    if ($camoufox.Count -ne 1 -or $camoufox[0].version -ne [string]$manifest.camoufox_python.version) {
        Fail 'CAMOUFOX_RESOLUTION' 'Resolved Camoufox version mismatch.'
    }
    if ($camoufox[0].sha256 -ne [string]$manifest.camoufox_python.sha256) {
        Fail 'CAMOUFOX_WHEEL_DIGEST' 'Resolved Camoufox wheel digest mismatch.'
    }
    if ($playwright.Count -ne 1 -or $playwright[0].version -ne [string]$manifest.playwright.version) {
        Fail 'PLAYWRIGHT_RESOLUTION' 'Resolved Playwright version mismatch.'
    }

    $packages = @($packages | Sort-Object name, version)

    $evidence = [ordered]@{
        schema = 'mish.lab.u8g-camoufox-resolution/v1'
        runner_identity = 'NT AUTHORITY\NETWORK SERVICE'
        python = [ordered]@{
            executable = [string]$manifest.python.executable
            version = [string]$manifest.python.version
            architecture = [string]$manifest.python.architecture
            pip = [string]$manifest.python.pip_version
        }
        requested = [ordered]@{
            camoufox = [string]$manifest.camoufox_python.version
            playwright = [string]$manifest.playwright.version
            browser = [string]$manifest.browser.version
        }
        browser = [ordered]@{
            asset = [string]$manifest.browser.asset
            sha256 = [string]$manifest.browser.sha256
            install_root = [string]$manifest.browser.install_root
            downloaded = $false
        }
        resolution = [ordered]@{
            package_count = $packages.Count
            only_binary = $true
            dry_run = $true
            packages = $packages
        }
        mutations = [ordered]@{
            packages_installed = $false
            browser_downloaded = $false
            product = $false
            device = $false
            network = $false
            services = $false
            persistent_files = $false
        }
        secrets_read = $false
    }

    $parent = Split-Path -Parent ([IO.Path]::GetFullPath($EvidencePath))
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($EvidencePath),
        (($evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    Write-Host 'MISH_U8G_CAMOUFOX_RESOLUTION=PASS'
    Write-Host ('MISH_U8G_CAMOUFOX_PACKAGE_COUNT=' + $packages.Count)
    Write-Host ('MISH_U8G_CAMOUFOX_VERSION=' + [string]$manifest.camoufox_python.version)
    Write-Host ('MISH_U8G_PLAYWRIGHT_VERSION=' + [string]$manifest.playwright.version)
    Write-Host ('MISH_U8G_BROWSER_VERSION=' + [string]$manifest.browser.version)
    Write-Host 'MISH_U8G_PACKAGES_INSTALLED=NO'
    Write-Host 'MISH_U8G_BROWSER_DOWNLOADED=NO'
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
