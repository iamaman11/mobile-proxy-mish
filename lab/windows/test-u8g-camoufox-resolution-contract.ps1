[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $PSScriptRoot 'u8g-camoufox-toolchain.json'
$resolverPath = Join-Path $PSScriptRoot 'resolve-u8g-camoufox-dependencies.ps1'

foreach ($path in @($manifestPath, $resolverPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required U8-G Camoufox file is missing: $path"
    }
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schema -ne 'mish.lab.u8g-camoufox-toolchain/v1') { throw 'Unexpected Camoufox manifest schema.' }
if ([string]$manifest.python.executable -ne 'C:\Python314\python.exe') { throw 'Camoufox fixture must reuse the proven machine Python.' }
if ([string]$manifest.python.version -ne '3.14.4') { throw 'Camoufox fixture Python pin drifted.' }
if ([string]$manifest.python.pip_version -ne '26.0.1') { throw 'Camoufox fixture pip pin drifted.' }
if ([string]$manifest.camoufox_python.version -ne '0.5.6') { throw 'Camoufox Python interface pin drifted.' }
if ([string]$manifest.camoufox_python.sha256 -ne 'b906836cd952376a466f0e55445f139b8a65adfb9f18ab55cb2cd0c727b11561') { throw 'Camoufox Python wheel digest drifted.' }
if ([string]$manifest.playwright.version -ne '1.61.0') { throw 'Playwright compatibility pin drifted.' }
if ([string]$manifest.browser.version -ne '152.0.4-beta.30') { throw 'Camoufox browser pin drifted.' }
if ([string]$manifest.browser.asset -ne 'camoufox-152.0.4-beta.30-win.x86_64.zip') { throw 'Camoufox browser asset drifted.' }
if ([string]$manifest.browser.sha256 -ne 'ea52a02fb1cfb1813ef6a326bea03fb2b650c9774143d953a94a27bfc8f10072') { throw 'Camoufox browser digest drifted.' }
if ([string]$manifest.browser.install_root -notlike 'C:\mish-lab\tools\*') { throw 'Camoufox browser must be LAB-owned.' }

$tokens=$null; $errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($resolverPath,[ref]$tokens,[ref]$errors)
if (@($errors).Count -ne 0) { throw 'Camoufox dependency resolver does not parse.' }

$source = Get-Content -Raw -LiteralPath $resolverPath
foreach ($required in @(
    '--dry-run',
    '--ignore-installed',
    '--only-binary=:all:',
    '--no-cache-dir',
    '--disable-pip-version-check',
    '--report',
    'packages_installed = $false',
    'browser_downloaded = $false',
    'persistent_files = $false',
    'secrets_read = $false',
    'NT AUTHORITY\NETWORK SERVICE'
)) {
    if (-not $source.Contains($required)) { throw "Camoufox resolver lost safety marker: $required" }
}

foreach ($forbidden in @(
    'camoufox fetch',
    'Start-Service',
    'Stop-Service',
    'Restart-Service',
    'Set-Net',
    'New-Net',
    'Remove-Net',
    'adb shell',
    'winget install',
    'MISH_MANAGER_TOKEN'
)) {
    if ($source.Contains($forbidden)) { throw "Camoufox resolver violated read-only boundary: $forbidden" }
}

Write-Host 'U8_G_CAMOUFOX_RESOLUTION_CONTRACT=PASS'
