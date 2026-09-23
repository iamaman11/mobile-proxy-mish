[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probe = Join-Path $PSScriptRoot 'diagnose-u8-camoufox-python-runtime.ps1'
if (-not (Test-Path -LiteralPath $probe -PathType Leaf)) { throw 'Python preflight probe missing.' }

$tokens=$null; $errors=$null
[void][System.Management.Automation.Language.Parser]::ParseFile($probe,[ref]$tokens,[ref]$errors)
if (@($errors).Count -ne 0) { throw 'Python preflight probe does not parse.' }

$source = Get-Content -Raw -LiteralPath $probe
foreach($required in @(
  'mish.lab.u8g-python-runtime-preflight/v1',
  'C:\Python314\python.exe',
  'Python 3.14.4',
  'pip 26.0.1',
  'NT AUTHORITY\NETWORK SERVICE',
  '-m venv',
  'packages_installed = $false',
  'persistent_files = $false',
  'secrets_read = $false'
)) {
  if(-not $source.Contains($required)) { throw "Python preflight lost marker: $required" }
}
foreach($forbidden in @(
  'pip install',
  'camoufox fetch',
  'winget',
  'Stop-Service',
  'Restart-Service',
  'Set-Net',
  'New-Net',
  'Remove-Net',
  'adb shell',
  'MISH_MANAGER_TOKEN'
)) {
  if($source.Contains($forbidden)) { throw "Python preflight must remain read-only: $forbidden" }
}
Write-Host 'U8_G_PYTHON_PREFLIGHT_CONTRACT=PASS'
