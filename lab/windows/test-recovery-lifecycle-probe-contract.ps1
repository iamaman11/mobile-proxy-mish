$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$probePath = Join-Path $PSScriptRoot 'diagnose-recovery-lifecycle.ps1'
$startPath = Join-Path $PSScriptRoot 'start-device-app.ps1'
$reportPath = Join-Path $PSScriptRoot 'new-device-cycle-report.ps1'

foreach ($path in @($probePath, $startPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) {
        $errors | ForEach-Object { Write-Error $_.Message }
        throw "Recovery/lifecycle control must parse under PowerShell: $path"
    }
    if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
        throw "Recovery/lifecycle control must not shadow the PowerShell automatic PID variable: $path"
    }
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    "`$script:Schema = 'mish.lab.recovery-lifecycle/v1'",
    "schema -cne `$script:CandidateSchema",
    'candidate.android_test_apk.sha256',
    "'install', '-r', '-t', `$testApkPath",
    "'shell', 'pm', 'path', `$script:TestPackage",
    'exact_test_apk_digest_verified = $true',
    'install_command_confirmed = $true',
    'installed_package_path_verified = $true',
    "external_owner_fault_injection = 'NOT_REQUIRED'",
    "reason = 'NO_SUPPORTED_DETERMINISTIC_UNATTENDED_TRIGGER_ON_DEVICE_1'",
    "external_mesh_owner_fault_injection = 'NOT_PERFORMED'",
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
    'start-device-app.ps1',
    'collect-device-diagnostic.ps1',
    'U2_RESTART_ACTIVE_SESSION_LEAK',
    'U2_RESTART_RECOVERY_INCOMPLETE',
    'U2_RECOVERY_LIFECYCLE_PASS',
    'cloudflare_app_mutated = $false',
    'product_routes_or_iptables_mutated_by_lab = $false'
)) {
    if (-not $source.Contains($required)) {
        throw "Recovery/lifecycle probe lost required exact-candidate/recovery evidence: $required"
    }
}

foreach ($forbidden in @(
    'LAB_TEST_APK_INSTALLED_DIGEST_MISMATCH',
    '$pulledTestApk',
    'installed_exact_bytes_verified = $true',
    "'cmd', 'connectivity', 'airplane-mode'",
    'CredentialProvisioning.psm1',
    'Open-MishApplicationSession',
    'Set-MishAirplane',
    'LAB_MESH_LOSS_EFFECT_NOT_OBSERVED',
    'U2_MESH_LOSS_NOT_REVOKED',
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
        throw "Recovery/lifecycle probe contains forbidden external-owner, false-provenance or PRODUCT mutation path: $forbidden"
    }
}

$startSource = Get-Content -Raw -LiteralPath $startPath
foreach ($required in @(
    '[ValidateRange(0, 60)][int] $ReadinessGraceSeconds = 10',
    '$proxyRunningSince = $null',
    '$proxyRunningElapsed -ge $ReadinessGraceSeconds',
    'readiness_grace_seconds = $ReadinessGraceSeconds',
    "if (`$readinessState -ceq 'READY')"
)) {
    if (-not $startSource.Contains($required)) {
        throw "Canonical launcher lost bounded READY grace semantics: $required"
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
        classification = 'U2_CELLULAR_E3_FAILED'
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
        [string]$product.classification -cne 'U2_CELLULAR_E3_FAILED' -or
        [string]$product.exact_candidate_acceptance -cne 'FAIL'
    ) {
        throw 'Observed Cellular E3 PRODUCT failure must reject the exact candidate.'
    }

    $labEvidence = Join-Path $root 'recovery-lab-fail.json'
    [ordered]@{
        schema = 'mish.lab.recovery-lifecycle/v1'
        acceptance_result = 'FAIL'
        classification = 'LAB_E3_DEVICE_CONTROL_FAILED'
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
        [string]$lab.classification -cne 'LAB_E3_DEVICE_CONTROL_FAILED' -or
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
