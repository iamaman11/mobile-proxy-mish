[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$manifestPath = Join-Path $PSScriptRoot 'u8g-camoufox-toolchain.json'
$lockPath = Join-Path $PSScriptRoot 'u8g-camoufox-requirements.lock'
$materializePath = Join-Path $PSScriptRoot 'materialize-u8g-camoufox-toolchain.ps1'
$verifyPath = Join-Path $PSScriptRoot 'verify-u8g-camoufox-toolchain.ps1'

foreach ($path in @($manifestPath, $lockPath, $materializePath, $verifyPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required U8-G Camoufox materialization file missing: $path"
    }
}

$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
if ($manifest.schema -ne 'mish.lab.u8g-camoufox-toolchain/v1') { throw 'Unexpected Camoufox toolchain schema.' }
if ([string]$manifest.python.executable -ne 'C:\Python314\python.exe') { throw 'Camoufox materialization must reuse the proven machine Python.' }
if ([string]$manifest.python_env.install_root -ne 'C:\mish-lab\tools\camoufox-python-0.5.6') { throw 'Camoufox Python environment must be LAB-owned.' }
if ([int]$manifest.python_env.package_count -ne 38) { throw 'Camoufox lock package count drifted.' }
if ([string]$manifest.browser.install_root -ne 'C:\mish-lab\tools\camoufox-152.0.4-beta.30') { throw 'Camoufox browser must be LAB-owned.' }
if ([string]$manifest.browser.sha256 -ne 'ea52a02fb1cfb1813ef6a326bea03fb2b650c9774143d953a94a27bfc8f10072') { throw 'Camoufox browser archive digest drifted.' }

$lockLines = @(Get-Content -LiteralPath $lockPath | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') })
if ($lockLines.Count -ne 38) { throw 'Camoufox exact wheel lock must contain 38 packages.' }
foreach ($line in $lockLines) {
    if ($line -notmatch '^[A-Za-z0-9_.-]+==[^ ]+\s+--hash=sha256:[0-9a-f]{64}$') {
        throw "Invalid hashed wheel lock entry: $line"
    }
}

foreach ($scriptPath in @($materializePath, $verifyPath)) {
    $tokens=$null; $errors=$null
    [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -ne 0) { throw "PowerShell parse failed: $scriptPath" }
}

$materialize = Get-Content -Raw -LiteralPath $materializePath
foreach ($required in @(
    'Assert-Administrator',
    'RepositoryCommit',
    '--require-hashes',
    '--only-binary=:all:',
    '--isolated',
    'https://pypi.org/simple',
    'Get-FileHash -Algorithm SHA256',
    'MISH_U8G_CAMOUFOX_FETCH_USED=NO',
    'VENV_PREEXISTING_UNTRUSTED',
    'BROWSER_MARKER_MISSING',
    'AreAccessRulesProtected'
)) {
    if (-not $materialize.Contains($required)) { throw "Camoufox materializer lost safety marker: $required" }
}
foreach ($forbidden in @(
    'camoufox fetch',
    'icacls',
    'Set-Acl',
    'Start-Service',
    'Stop-Service',
    'Restart-Service',
    'Set-Net',
    'New-Net',
    'Remove-Net',
    'adb shell',
    'MISH_MANAGER_TOKEN'
)) {
    if ($materialize.Contains($forbidden)) { throw "Camoufox materializer violates bounded ownership: $forbidden" }
}

$verify = Get-Content -Raw -LiteralPath $verifyPath
foreach ($required in @(
    'NT AUTHORITY\NETWORK SERVICE',
    "GITHUB_REF -ne 'refs/heads/main'",
    "GITHUB_REF_PROTECTED -ne 'true'",
    'executable_path=exe',
    'ff_version=152',
    'geoip=False',
    'data:text/plain,U8G',
    'MISH_U8G_CAMOUFOX_USER_CACHE_USED=NO',
    'MISH_U8G_CAMOUFOX_EXTERNAL_NETWORK=NO'
)) {
    if (-not $verify.Contains($required)) { throw "Camoufox runner verify lost safety marker: $required" }
}
foreach ($forbidden in @(
    'pip install',
    'camoufox fetch',
    'Invoke-WebRequest',
    'curl.exe',
    'Start-Service',
    'Stop-Service',
    'Restart-Service',
    'Set-Net',
    'New-Net',
    'Remove-Net',
    'adb shell',
    'MISH_MANAGER_TOKEN'
)) {
    if ($verify.Contains($forbidden)) { throw "Camoufox runner verify must remain read-only: $forbidden" }
}

Write-Host 'U8_G_CAMOUFOX_MATERIALIZATION_CONTRACT=PASS'
