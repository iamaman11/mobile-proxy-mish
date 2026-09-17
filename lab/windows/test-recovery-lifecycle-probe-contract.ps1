$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$probePath = Join-Path $PSScriptRoot 'diagnose-recovery-lifecycle.ps1'
$reportPath = Join-Path $PSScriptRoot 'new-device-cycle-report.ps1'

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'Recovery/lifecycle probe must parse under PowerShell.'
}
if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
    throw 'Recovery/lifecycle probe must not shadow the PowerShell automatic PID variable.'
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    "`$script:Schema = 'mish.lab.recovery-lifecycle/v1'",
    "schema -cne `$script:CandidateSchema",
    'candidate.android_test_apk.sha256',
    "'install', '-r', '-t', `$testApkPath",
    "'shell', 'pm', 'path', `$script:TestPackage",
    "Get-MishSha256 -Path `$pulledTestApk",
    "'cmd', 'connectivity', 'airplane-mode', `$State",
    'U2_MESH_LOSS_NOT_REVOKED',
    'U2_MESH_SESSION_SURVIVED_REVOKE',
    'epoch_reestablished_after_absence = $true',
    "`$script:TestClass = 'com.mobileproxymish.app.cellular.CellularE3InstrumentedTest'",
    "`$script:TestComponent = 'com.mobileproxymish.app.test/androidx.test.runner.AndroidJUnitRunner'",
    "'e3Mode', 'lifecycle'",
    "'E3_EVIDENCE phase=positive '",
    "'E3_EVIDENCE phase=negative '",
    "'E3_EVIDENCE phase=recovery '",
    'established_flow_blocked=true',
    'dns_blocked=true',
    'public_socket_blocked=true',
    'no_default_fallback=true',
    'fresh_generation=true',
    'cleanup_verified=true',
    "start-device-app.ps1",
    "collect-device-diagnostic.ps1",
    "U2_RESTART_ACTIVE_SESSION_LEAK",
    "U2_RECOVERY_LIFECYCLE_PASS",
    'cloudflare_app_mutated = $false',
    'product_routes_or_iptables_mutated_by_lab = $false'
)) {
    if (-not $source.Contains($required)) {
        throw "Recovery/lifecycle probe lost required exact-candidate/owner evidence: $required"
    }
}

foreach ($forbidden in @(
    "'shell', 'su'",
    "'shell', 'iptables'",
    "'shell', 'ip6tables'",
    'settings put',
    'svc data',
    'com.cloudflare',
    'warp-cli',
    'sing-box',
    'gradle ',
    'cargo build',
    'assembleDebug'
)) {
    if ($source.Contains($forbidden)) {
        throw "Recovery/lifecycle probe must remain CONTROL-only and must not mutate PRODUCT/network policy directly: $forbidden"
    }
}

$root = Join-Path $env:TEMP ('mish-recovery-report-contract-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    $controlSha = '1' * 40
    $diagnostic = Join-Path $root 'diagnostic.json'
    [ordered]@{
        schema = 'mish.lab.diagnostic/v2'
        classification = 'PASS'
        collection_result = 'PASS'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $diagnostic

    $passEvidence = Join-Path $root 'recovery-pass.json'
    [ordered]@{
        schema = 'mish.lab.recovery-lifecycle/v1'
        acceptance_result = 'PASS'
        classification = 'U2_RECOVERY_LIFECYCLE_PASS'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $passEvidence
    $pass = & $reportPath `
        -Mode full `
        -PrNumber 213 `
        -SourceSha ('a' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $diagnostic `
        -RequestedProbe recovery_lifecycle `
        -TargetedEvidencePath $passEvidence `
        -OutputPath (Join-Path $root 'pass-report.json') |
        Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$pass.cycle_result -cne 'PASS' -or
        [string]$pass.acceptance_scope -cne 'FULL_BASELINE_PLUS_RECOVERY_LIFECYCLE' -or
        [string]$pass.exact_candidate_acceptance -cne 'PASS' -or
        [string]$pass.targeted_probe.acceptance_result -cne 'PASS'
    ) {
        throw 'Recovery/lifecycle PASS must accept the exact candidate only with baseline + targeted evidence.'
    }

    $productEvidence = Join-Path $root 'recovery-product-fail.json'
    [ordered]@{
        schema = 'mish.lab.recovery-lifecycle/v1'
        acceptance_result = 'FAIL'
        classification = 'U2_MESH_LOSS_NOT_REVOKED'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $productEvidence
    $product = & $reportPath `
        -Mode full `
        -PrNumber 213 `
        -SourceSha ('b' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $diagnostic `
        -RequestedProbe recovery_lifecycle `
        -TargetedEvidencePath $productEvidence `
        -OutputPath (Join-Path $root 'product-report.json') |
        Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$product.cycle_result -cne 'PRODUCT_FAIL' -or
        [string]$product.classification -cne 'U2_MESH_LOSS_NOT_REVOKED' -or
        [string]$product.exact_candidate_acceptance -cne 'FAIL'
    ) {
        throw 'Observed recovery PRODUCT failure must reject the exact candidate.'
    }

    $labEvidence = Join-Path $root 'recovery-lab-fail.json'
    [ordered]@{
        schema = 'mish.lab.recovery-lifecycle/v1'
        acceptance_result = 'FAIL'
        classification = 'LAB_MESH_LOSS_EFFECT_NOT_OBSERVED'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $labEvidence
    $lab = & $reportPath `
        -Mode full `
        -PrNumber 213 `
        -SourceSha ('c' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $diagnostic `
        -RequestedProbe recovery_lifecycle `
        -TargetedEvidencePath $labEvidence `
        -OutputPath (Join-Path $root 'lab-report.json') |
        Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$lab.cycle_result -cne 'LAB_FAIL' -or
        [string]$lab.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'LAB recovery-control failure must not reject the PRODUCT candidate.'
    }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Write-Host 'RECOVERY_LIFECYCLE_PROBE_CONTRACT=PASS'
exit 0
