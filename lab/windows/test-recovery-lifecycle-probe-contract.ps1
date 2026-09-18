$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$probePath = Join-Path $PSScriptRoot 'diagnose-recovery-lifecycle.ps1'
$installerPath = Join-Path $PSScriptRoot 'install-device-candidate.ps1'
$startPath = Join-Path $PSScriptRoot 'start-device-app.ps1'
$reportPath = Join-Path $PSScriptRoot 'new-device-cycle-report.ps1'
$e3SourcePath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'android/app/src/androidTest/java/com/mobileproxymish/app/cellular/CellularE3InstrumentedTest.kt'

foreach ($path in @($probePath, $installerPath, $startPath)) {
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
    '$script:TestPackage = "$PackageName.test"',
    '$script:TestComponent = "$($script:TestPackage)/androidx.test.runner.AndroidJUnitRunner"',
    "'shell', 'pm', 'path', `$script:TestPackage",
    "@('uninstall', `$script:TestPackage)",
    'LAB_TEST_HARNESS_CLEANUP_FAILED',
    'test_harness = $harnessCleanup',
    'exact_test_apk_digest_verified = $true',
    'preinstalled_lab_signed_harness = $true',
    'test_package_id = $script:TestPackage',
    'installed_package_path_verified = $true',
    'instrumentation_exit_code = [int]$instrumentation.ExitCode',
    'Stop-MishProductProcessForInstrumentation',
    'LAB_INSTRUMENTATION_HANDOFF_FORCE_STOP_FAILED',
    'LAB_INSTRUMENTATION_HANDOFF_PROCESS_STILL_ALIVE',
    "mode = 'EXPLICIT_FORCE_STOP'",
    'instrumentation_handoff = $instrumentationHandoff',
    'LAB_TEST_HARNESS_SIGNATURE_MISMATCH',
    "external_owner_fault_injection = 'NOT_REQUIRED'",
    "reason = 'NO_SUPPORTED_DETERMINISTIC_UNATTENDED_TRIGGER_ON_DEVICE_1'",
    "external_mesh_owner_fault_injection = 'NOT_PERFORMED'",
    "`$script:TestClass = 'com.mobileproxymish.app.cellular.CellularE3InstrumentedTest'",
    "'e3Mode', 'lifecycle'",
    'e3_evidence=phase=positive ',
    'e3_evidence=phase=negative ',
    'e3_evidence=phase=recovery ',
    'established_flow_blocked=true',
    'dns_blocked=true',
    'public_socket_blocked=true',
    'no_default_fallback=true',
    'fresh_generation=true',
    'cleanup_verified=true',
    'Get-MishDnsLifetimeObservation',
    '$dnsLifetimeEvidence.before_e3 = $preDnsObservation',
    'Wait-MishDnsLifetimeObservation',
    '[ValidateRange(1, 30)][int] $TimeoutSeconds = 10',
    '[ValidateRange(50, 5000)][int] $PollMilliseconds = 250',
    '$postE3Read = Wait-MishDnsLifetimeObservation',
    '$dnsLifetimeEvidence.post_e3_snapshot_attempts = [int]$postE3Read.attempts',
    '$dnsLifetimeEvidence.post_e3_wait_elapsed_ms = [int64]$postE3Read.elapsed_ms',
    "measurement_status = 'NOT_EVALUATED'",
    "'POST_INSTRUMENTATION_UNAVAILABLE'",
    "'OBSERVED'",
    '$dnsLifetimeEvidence.after_e3_before_restart = $postE3Read.observation',
    '$dnsLifetimeEvidence.same_process =',
    "comparison_scope = 'NOT_OBSERVED'",
    "'SAME_PROCESS'",
    "'PROCESS_BOUNDARY'",
    'LAB_DNS_LIFETIME_BASELINE_INVALID',
    'active = [int64]$dns.active',
    'peak_active = [int64]$dns.peak_active',
    'max_native_elapsed_ms = [int64]$dns.max_native_elapsed_ms',
    'completed_after_owner_change = [int64]$dns.completed_after_owner_change',
    'discarded_after_deadline = [int64]$dns.discarded_after_deadline',
    'discarded_stale = [int64]$dns.discarded_stale',
    'dns_lifetime = $dnsLifetimeEvidence',
    'lifecycle_latency_budget = $lifecycleLatencyBudget',
    "measurement_status = 'NOT_OBSERVED'",
    "threshold_policy = 'NO_NEW_SLA'",
    "measurement_status = 'E3_OBSERVED'",
    "measurement_status = 'COMPLETE'",
    'initial_launch_elapsed_ms = [int64]$initialLaunch.elapsed_ms',
    'restart_launch_elapsed_ms = [int64]$postStart.elapsed_ms',
    'last_reconcile_elapsed_ms',
    'last_policy_effect_elapsed_ms',
    'loss_owner_elapsed_ms=(?<lossOwner>\d+)',
    'loss_fail_closed_elapsed_ms=(?<lossFailClosed>\d+)',
    'recovery_owner_elapsed_ms=(?<recoveryOwner>\d+)',
    'recovery_functional_elapsed_ms=(?<recoveryFunctional>\d+)',
    'stop_total_elapsed_ms=(?<stopTotal>\d+)',
    'start-device-app.ps1',
    'collect-device-diagnostic.ps1',
    "`$externalMeshBlocked = `$postClass -ceq 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED'",
    'external_mesh_acceptance_blocked = $externalMeshBlocked',
    '$externalMeshSatisfied = $externalMeshBlocked -or',
    "'LAB_EXTERNAL_MESH_ACCEPTANCE_BLOCKED'",
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

$handoffIndex = $source.IndexOf('$handoff = Stop-MishProductProcessForInstrumentation', [StringComparison]::Ordinal)
$instrumentIndex = $source.IndexOf("'shell', 'am', 'instrument'", [StringComparison]::Ordinal)
if ($handoffIndex -lt 0 -or $instrumentIndex -lt 0 -or $handoffIndex -ge $instrumentIndex) {
    throw 'Recovery/lifecycle control must prove the baseline PRODUCT process absent before starting instrumentation.'
}
if ($source.IndexOf("'shell', 'su'", [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw 'Instrumentation process handoff must remain non-root and must not mutate PRODUCT root policy from LAB.'
}

$postE3WaitIndex = $source.IndexOf('$postE3Read = Wait-MishDnsLifetimeObservation', [StringComparison]::Ordinal)
$explicitRestartIndex = $source.IndexOf('& (Join-Path $PSScriptRoot ''start-device-app.ps1'')', [StringComparison]::Ordinal)
if ($postE3WaitIndex -lt 0 -or $explicitRestartIndex -lt 0 -or $postE3WaitIndex -ge $explicitRestartIndex) {
    throw 'Recovery/lifecycle control must capture bounded DNS process-boundary evidence before the explicit PRODUCT restart.'
}

if ($source.Contains('LAB_DNS_LIFETIME_PROCESS_CHANGED')) {
    throw 'A PRODUCT PID change after instrumentation is DNS measurement scope evidence, not a recovery acceptance failure.'
}
if ($source.Contains("Stop-MishRecovery 'LAB_DNS_LIFETIME_POST_E3_INVALID'")) {
    throw 'Unavailable post-instrumentation DNS measurement must not block PRODUCT recovery acceptance.'
}

$preDnsIndex = $source.IndexOf('$dnsLifetimeEvidence.before_e3 = $preDnsObservation', [StringComparison]::Ordinal)
$postDnsIndex = $source.IndexOf('$dnsLifetimeEvidence.after_e3_before_restart = $postE3Read.observation', [StringComparison]::Ordinal)
if ($preDnsIndex -lt 0 -or $postDnsIndex -le $preDnsIndex) {
    throw 'Recovery/lifecycle control must preserve ordered before-E3 and after-E3 DNS observations without implying cross-PID counter continuity.'
}

$e3Source = Get-Content -Raw -LiteralPath $e3SourcePath
foreach ($required in @(
    'val lossStartedAt = SystemClock.elapsedRealtime()',
    'val lossOwnerElapsedMs = SystemClock.elapsedRealtime() - lossStartedAt',
    'val lossFailClosedElapsedMs = SystemClock.elapsedRealtime() - lossStartedAt',
    'val recoveryStartedAt = SystemClock.elapsedRealtime()',
    'val recoveryOwnerElapsedMs = SystemClock.elapsedRealtime() - recoveryStartedAt',
    'val recoveryFunctionalElapsedMs = SystemClock.elapsedRealtime() - recoveryStartedAt',
    'val proxyCloseElapsedMs = SystemClock.elapsedRealtime() - proxyCloseStartedAt',
    'val cellularCloseElapsedMs = SystemClock.elapsedRealtime() - cellularCloseStartedAt',
    'val cleanupVerifyElapsedMs = SystemClock.elapsedRealtime() - cleanupVerifyStartedAt',
    'val stopTotalElapsedMs = SystemClock.elapsedRealtime() - stopStartedAt',
    '"phase=latency "',
    '"loss_owner_elapsed_ms=$lossOwnerElapsedMs "',
    '"loss_fail_closed_elapsed_ms=$lossFailClosedElapsedMs "',
    '"recovery_owner_elapsed_ms=$recoveryOwnerElapsedMs "',
    '"recovery_functional_elapsed_ms=$recoveryFunctionalElapsedMs "',
    '"proxy_close_elapsed_ms=$proxyCloseElapsedMs "',
    '"cellular_close_elapsed_ms=$cellularCloseElapsedMs "',
    '"cleanup_verify_elapsed_ms=$cleanupVerifyElapsedMs "',
    '"stop_total_elapsed_ms=$stopTotalElapsedMs"'
)) {
    if (-not $e3Source.Contains($required)) {
        throw "Exact E3 harness lost observational lifecycle timing evidence: $required"
    }
}

foreach ($forbidden in @(
    'MAX_STARTUP_LATENCY',
    'MAX_RECOVERY_LATENCY',
    'MAX_STOP_LATENCY',
    'latency budget exceeded',
    'assertTrue("startup latency',
    'assertTrue("recovery latency',
    'assertTrue("stop latency'
)) {
    if ($e3Source.Contains($forbidden) -or $source.Contains($forbidden)) {
        throw "Lifecycle latency observation must not invent a PRODUCT SLA or acceptance threshold: $forbidden"
    }
}

$installerSource = Get-Content -Raw -LiteralPath $installerPath
foreach ($required in @(
    '$testApplicationId = "$applicationId.test"',
    "@('uninstall', `$testApplicationId)",
    'TEST_HARNESS_SIGNATURE_MIGRATION_REQUIRED',
    'TEST_HARNESS_INSTALL_FAILED',
    'test_harness_installed = $true'
)) {
    if (-not $installerSource.Contains($required)) {
        throw "Device candidate installer lost bounded LAB test-harness self-heal semantics: $required"
    }
}
if ($installerSource.Contains("`$testApplicationId = 'com.mobileproxymish.app.test'")) {
    throw 'Device candidate installer regressed to the wrong androidTest package identity.'
}

foreach ($forbidden in @(
    "'install', '-r', '-t', `$testApkPath",
    'LAB_TEST_APK_INSTALL_FAILED',
    'install_command_confirmed = $true',
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
        throw "Recovery/lifecycle probe contains forbidden duplicate harness install, external-owner, false-provenance or PRODUCT mutation path: $forbidden"
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

    $externalMeshEvidence = Join-Path $root 'recovery-external-mesh-blocked.json'
    [ordered]@{
        schema = 'mish.lab.recovery-lifecycle/v1'
        acceptance_result = 'FAIL'
        classification = 'LAB_EXTERNAL_MESH_ACCEPTANCE_BLOCKED'
        cellular_e3 = [ordered]@{ instrumentation_pass = $true }
        restart = [ordered]@{ external_mesh_acceptance_blocked = $true; loopback_e2e = 'PASS'; mesh_e2e = 'FAIL' }
    } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath $externalMeshEvidence
    $externalMesh = & $reportPath `
        -Mode full `
        -PrNumber 213 `
        -SourceSha ('d' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $diagnostic `
        -RequestedProbe recovery_lifecycle `
        -TargetedEvidencePath $externalMeshEvidence `
        -OutputPath (Join-Path $root 'external-mesh-report.json') |
        Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$externalMesh.cycle_result -cne 'LAB_FAIL' -or
        [string]$externalMesh.classification -cne 'LAB_EXTERNAL_MESH_ACCEPTANCE_BLOCKED' -or
        [string]$externalMesh.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'External Mesh sandbox block must preserve recovery evidence without accepting or rejecting the PRODUCT candidate.'
    }

    $sandboxDiagnostic = Join-Path $root 'diagnostic-sandbox-blocked.json'
    [ordered]@{
        schema = 'mish.lab.diagnostic/v2'
        classification = 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED'
        collection_result = 'PASS'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $sandboxDiagnostic

    $sandboxExternal = & $reportPath `
        -Mode full `
        -PrNumber 213 `
        -SourceSha ('e' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $sandboxDiagnostic `
        -RequestedProbe recovery_lifecycle `
        -TargetedEvidencePath $externalMeshEvidence `
        -OutputPath (Join-Path $root 'sandbox-external-report.json') |
        Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$sandboxExternal.cycle_result -cne 'LAB_FAIL' -or
        [string]$sandboxExternal.classification -cne 'LAB_EXTERNAL_MESH_ACCEPTANCE_BLOCKED' -or
        [string]$sandboxExternal.baseline_classification -cne 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED' -or
        [string]$sandboxExternal.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'Sandboxed baseline must not mask the targeted external-Mesh blocker or accept the candidate.'
    }

    $sandboxProduct = & $reportPath `
        -Mode full `
        -PrNumber 213 `
        -SourceSha ('f' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $sandboxDiagnostic `
        -RequestedProbe recovery_lifecycle `
        -TargetedEvidencePath $productEvidence `
        -OutputPath (Join-Path $root 'sandbox-product-report.json') |
        Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$sandboxProduct.cycle_result -cne 'PRODUCT_FAIL' -or
        [string]$sandboxProduct.classification -cne 'U2_CELLULAR_E3_FAILED' -or
        [string]$sandboxProduct.baseline_classification -cne 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED' -or
        [string]$sandboxProduct.exact_candidate_acceptance -cne 'FAIL'
    ) {
        throw 'Sandboxed external Mesh baseline must not mask an independently observed targeted PRODUCT failure.'
    }

    $sandboxPass = & $reportPath `
        -Mode full `
        -PrNumber 213 `
        -SourceSha ('0' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $sandboxDiagnostic `
        -RequestedProbe recovery_lifecycle `
        -TargetedEvidencePath $passEvidence `
        -OutputPath (Join-Path $root 'sandbox-pass-report.json') |
        Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$sandboxPass.cycle_result -cne 'LAB_FAIL' -or
        [string]$sandboxPass.classification -cne 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED' -or
        [string]$sandboxPass.baseline_classification -cne 'LAB_WINDOWS_SANDBOX_OUTBOUND_BLOCKED' -or
        [string]$sandboxPass.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'Targeted PASS must never override a sandbox-blocked external Mesh baseline.'
    }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

Write-Host 'RECOVERY_LIFECYCLE_PROBE_CONTRACT=PASS'
exit 0
