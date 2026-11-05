$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
Import-Module (Join-Path $root 'AdbDiagnostic.psm1') -Force

$cases = @(
    @{ Lines=@('List of devices attached','serial-a device product:xyz'); Exit=0; Want='READY' },
    @{ Lines=@('List of devices attached','serial-a unauthorized'); Exit=0; Want='ADB_UNAUTHORIZED' },
    @{ Lines=@('List of devices attached','serial-a offline'); Exit=0; Want='ADB_OFFLINE' },
    @{ Lines=@('List of devices attached'); Exit=0; Want='ADB_DEVICE_MISSING' },
    @{ Lines=@('List of devices attached','serial-a device','serial-b device'); Exit=0; Want='ADB_MULTIPLE_DEVICES' },
    @{ Lines=@('List of devices attached','serial-a device','serial-b unauthorized'); Exit=0; Want='ADB_MULTIPLE_DEVICES' },
    @{ Lines=@('adb server failed'); Exit=1; Want='ADB_ENUMERATION_FAILED' }
)
foreach ($case in $cases) {
    $got = Get-MishAdbAvailability -Lines $case.Lines -ExitCode $case.Exit
    if ($got -cne $case.Want) { throw "ADB classifier mismatch: expected $($case.Want) observed $got" }
}
& (Join-Path $root 'collect-full-diagnostic.ps1') -SelfTest

$source = (Get-Content -LiteralPath (Join-Path $root 'collect-full-diagnostic.ps1') -Raw)
$workflow = Get-Content -LiteralPath (Join-Path $root '..\..\.github\workflows\mish-full-diagnostic.yml') -Raw
$cfWorkflow = Get-Content -LiteralPath (Join-Path $root '..\..\.github\workflows\cloudflare-live-preflight.yml') -Raw
foreach($required in @(
    "github.event.comment.body == '/mish-diag full'",
    "github.event.comment.user.login == 'iamaman11'",
    'uses: ./.github/workflows/cloudflare-live-preflight.yml',
    'secrets: inherit',
    'needs: [device, cloudflare]',
    "if: ${{ always() }}"
)) {
    if (-not $workflow.Contains($required)) { throw "Full diagnostic contract missing: $required" }
}
if (-not $cfWorkflow.Contains('workflow_call:') -or -not $cfWorkflow.Contains('inputs.full_diagnostic == true')) {
    throw 'Cloudflare preflight is not reused under the explicit protected full-diagnostic contract.'
}
if (-not $source.Contains("mish.lab.full-diagnostic/v1") -or
    -not $source.Contains("'COLLECTION_FAILED'") -or
    -not $source.Contains("mutation_performed = $false")) {
    throw 'Full diagnostic typed failure evidence contract is absent.'
}
foreach ($path in @('collect-control-diagnostic.ps1','collect-device-diagnostic.ps1')) {
    $s = Get-Content -LiteralPath (Join-Path $root $path) -Raw
    if (-not $s.Contains('Assert-MishAdbReady')) {
        throw "Collector does not share ADB readiness classification: $path"
    }
}

# Exercise the real orchestration's failure-evidence path with NO ADB and
# no device side effects. The expected failure is not a green diagnostic.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('mish-full-contract-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $missingAdb = Join-Path $testRoot 'nonexistent-adb.exe'
    $caught = $false
    try {
        & (Join-Path $root 'collect-full-diagnostic.ps1') -AdbPath $missingAdb -EvidenceRoot $testRoot | Out-Null
    }
    catch { $caught = $true }
    if (-not $caught) { throw 'Missing ADB was falsely accepted as success.' }
    $reportPath = Join-Path $testRoot 'full.json'
    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'No durable typed failure report.' }
    $report = Get-Content -Raw $reportPath | ConvertFrom-Json
    if ($report.schema -cne 'mish.lab.full-diagnostic/v1' -or $report.classification -cne 'FAIL' -or
        $report.stages.device.reason -cne 'ADB_MISSING' -or
        $report.stages.control.reason -cne 'ADB_MISSING' -or
        $report.stages.warp.result -cne 'FAIL' -or
        $report.mutation_performed -ne $false) {
        throw 'Fail-closed synthetic missing-ADB evidence contract FAILED.'
    }
}
finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host 'MISH_FULL_DIAGNOSTIC_CONTRACT=PASS'
