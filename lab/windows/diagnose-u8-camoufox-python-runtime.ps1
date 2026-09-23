[CmdletBinding()]
param(
  [string]$PythonPath = 'C:\Python314\python.exe',
  [string]$EvidencePath = (Join-Path $env:TEMP 'mish-u8g-python-runtime-preflight-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail([string]$Category,[string]$Message) {
  throw "MISH_U8G_PYTHON_PREFLIGHT|$Category|$Message"
}

if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
  Fail 'PYTHON_MISSING' 'Pinned machine Python executable is missing.'
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($identity -ine 'NT AUTHORITY\NETWORK SERVICE') {
  Fail 'RUNNER_IDENTITY_MISMATCH' 'Preflight must execute as NetworkService.'
}

$versionText = (& $PythonPath --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $versionText -notmatch '^Python 3\.14\.4$') {
  Fail 'PYTHON_VERSION_MISMATCH' 'Expected Python 3.14.4.'
}

$probe = (& $PythonPath -c "import sys,struct; print(sys.executable); print(struct.calcsize('P')*8)" 2>&1 | Out-String).Trim().Split([Environment]::NewLine)
if ($LASTEXITCODE -ne 0 -or @($probe).Count -lt 2) {
  Fail 'PYTHON_EXECUTION_FAILED' 'Python execution probe failed.'
}
$archBits = [int]$probe[-1]
if ($archBits -ne 64) {
  Fail 'PYTHON_ARCH_MISMATCH' 'Python must be x64.'
}

$pipText = (& $PythonPath -m pip --version 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $pipText -notmatch '^pip 26\.0\.1\b') {
  Fail 'PIP_VERSION_MISMATCH' 'Expected pip 26.0.1.'
}

$venvRoot = Join-Path $env:RUNNER_TEMP ('mish-u8g-python-venv-' + [guid]::NewGuid().ToString('N'))
$venvPython = Join-Path $venvRoot 'Scripts\python.exe'
$venvPip = Join-Path $venvRoot 'Scripts\pip.exe'
$created = $false
try {
  & $PythonPath -m venv $venvRoot
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython -PathType Leaf) -or -not (Test-Path -LiteralPath $venvPip -PathType Leaf)) {
    Fail 'VENV_CREATION_FAILED' 'Temporary venv could not be created by the runner service.'
  }
  $created = $true

  $venvVersion = (& $venvPython --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $venvVersion -ne 'Python 3.14.4') {
    Fail 'VENV_PYTHON_MISMATCH' 'Temporary venv Python does not match the pinned runtime.'
  }

  $venvPipText = (& $venvPython -m pip --version 2>&1 | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $venvPipText -notmatch '^pip 26\.0\.1\b') {
    Fail 'VENV_PIP_MISMATCH' 'Temporary venv pip is unavailable or drifted.'
  }

  $evidence = [ordered]@{
    schema = 'mish.lab.u8g-python-runtime-preflight/v1'
    identity = 'NT AUTHORITY\NETWORK SERVICE'
    python = [ordered]@{
      executable = 'C:\Python314\python.exe'
      version = '3.14.4'
      architecture = 'x64'
      pip = '26.0.1'
      service_execution = $true
    }
    temporary_venv = [ordered]@{
      created = $true
      python_ok = $true
      pip_ok = $true
      packages_installed = $false
    }
    mutations = [ordered]@{
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
    (($evidence | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
  )
}
finally {
  if (Test-Path -LiteralPath $venvRoot) {
    Remove-Item -LiteralPath $venvRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Host 'MISH_U8G_PYTHON_PREFLIGHT=PASS'
Write-Host 'MISH_U8G_PYTHON_VERSION=3.14.4'
Write-Host 'MISH_U8G_PYTHON_ARCH=X64'
Write-Host 'MISH_U8G_PIP_VERSION=26.0.1'
Write-Host 'MISH_U8G_RUNNER_IDENTITY=NETWORK_SERVICE'
Write-Host 'MISH_U8G_TEMP_VENV=PASS'
Write-Host 'MISH_U8G_PACKAGES_INSTALLED=NO'
