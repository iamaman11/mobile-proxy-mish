$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$bootstrap = Join-Path $PSScriptRoot 'bootstrap-windows.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($bootstrap, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'BOOTSTRAP_RECOVERY_TEST|PARSER_ERROR' }

$parameters = @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
foreach ($name in @('RepositoryCommit', 'ToolsOnly', 'RepairOrphanedRunnerService', 'SelfTest')) {
    if ($parameters -cnotcontains $name) { throw "BOOTSTRAP_RECOVERY_TEST|MISSING_PARAMETER|$name" }
}

$text = Get-Content -Raw -LiteralPath $bootstrap
foreach ($required in @(
    'if ($ToolsOnly -and $RepairOrphanedRunnerService)',
    'if ($ToolsOnly) {',
    "Write-Host 'MISH_LAB_TOOLS=PASS'",
    'Repair-ExactOrphanedRunnerService -RunnerRoot $runnerRoot',
    'if ($RepairOrphanedRunnerService) {',
    'Get-CimInstance Win32_Process -Filter',
    'Get-CimInstance Win32_Service',
    "if ($service.State -ne 'Stopped'",
    'sc.exe delete $expectedName',
    'Orphan repair refuses to remove a service while either registration marker exists.',
    'Windows service deletion is pending'
)) {
    if (-not $text.Contains($required)) { throw "BOOTSTRAP_RECOVERY_TEST|MISSING_GUARD|$required" }
}

$toolsOnly = $text.IndexOf("if ($" + "ToolsOnly) {")
$repair = $text.IndexOf("if ($" + "RepairOrphanedRunnerService) {", $toolsOnly)
$token = $text.IndexOf('Get-RunnerRegistrationSecureToken `', $toolsOnly)
if ($toolsOnly -lt 0 -or $repair -le $toolsOnly -or $token -le $repair) {
    throw 'BOOTSTRAP_RECOVERY_TEST|TOOLS_MUST_BE_RECOVERABLE_WITHOUT_RUNNER_TOKEN'
}
if ($text -match 'Start-Service.*-Name.*\\$expectedName' -or $text -match 'sc\\.exe delete \\*') {
    throw 'BOOTSTRAP_RECOVERY_TEST|UNBOUNDED_SERVICE_ACTION'
}

& $bootstrap -RepositoryCommit ('0' * 40) -SelfTest
if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
    throw 'BOOTSTRAP_RECOVERY_TEST|DEPENDENCY_SELFTEST_FAILED'
}
Write-Host 'BOOTSTRAP_DISASTER_RECOVERY_CONTRACT=PASS'
