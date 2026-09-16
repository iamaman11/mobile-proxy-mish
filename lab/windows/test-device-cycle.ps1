$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path $env:TEMP ('mish-device-cycle-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    foreach ($path in @(
        'start-device-app.ps1',
        'collect-device-diagnostic.ps1',
        'DeviceDiagnosticClassification.psm1',
        'collect-runtime-identity.ps1',
        'diagnose-loopback-connect.ps1',
        'new-device-cycle-report.ps1'
    )) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot $path),
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -ne 0) {
            $errors | ForEach-Object { Write-Error "${path}: $($_.Message)" }
            throw "PowerShell parse failed for $path."
        }
        if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
            throw "PowerShell automatic variable `$PID must not be reused by device-cycle script $path."
        }
    }

    Import-Module (Join-Path $PSScriptRoot 'DeviceDiagnosticClassification.psm1') -Force
    $base = @{
        PidStable = $true
        AndroidConsistent = $true
        RuntimeRunning = $true
        CellularState = 'ADMITTED'
        CellularReason = 'NONE'
        CellularAdmitted = $true
        CellularBoundaryFailure = ''
        RootAuthorityObservation = 'READY_AT_POLICY_AUTHORIZATION'
        RootPolicyAuthorized = $true
        ProxyState = 'RUNNING'
        ProxyHealthy = $true
        ProxyFailure = ''
        CredentialActive = $true
        CredentialLeaseStatus = 'AVAILABLE'
        MeshState = 'ADMITTED'
        MeshAdmitted = $true
        MeshEpochPresent = $true
        MeshIngressRunning = $true
        MeshIngressFailure = 'NONE'
        ReadinessState = 'READY'
        ReadinessBindingEligible = $true
        ReadinessProbeState = 'SUCCEEDED'
        LoopbackResult = 'PASS'
        LoopbackReason = 'NONE'
        MeshEndpointCount = 1
        RoutePresent = $true
        Tcp3128 = $true
        MeshProbeResult = 'PASS'
        MeshProbeReason = 'NONE'
    }

    # Current L8 causal rule: a terminal Proxy Serving owner failure must not be masked by the
    # downstream Cellular/root/readiness facts that were never reached during startup.
    $case = $base.Clone()
    $case.ProxyState = 'FAILED'
    $case.ProxyHealthy = $false
    $case.ProxyFailure = 'LEGACY_MIGRATION_BLOCKED'
    $case.CellularState = 'BOUNDARY_UNAVAILABLE'
    $case.CellularAdmitted = $false
    $case.RootAuthorityObservation = 'NOT_OBSERVED'
    $case.RootPolicyAuthorized = $false
    $case.CredentialActive = $false
    $case.CredentialLeaseStatus = 'NOT_ATTEMPTED'
    $case.MeshState = 'ABSENT'
    $case.MeshAdmitted = $false
    $case.MeshEpochPresent = $false
    $case.MeshIngressRunning = $false
    $case.ReadinessState = 'NOT_READY'
    $case.ReadinessBindingEligible = $false
    $case.ReadinessProbeState = 'BLOCKED'
    $observed = Get-MishDeviceDiagnosticClassification @case
    if ($observed -cne 'PRODUCT_PROXY_LEGACY_CUTOVER_CLEANUP_BLOCKED') {
        throw "Terminal L8 Proxy Serving failure was masked by a downstream non-observation: $observed"
    }

    $case = $base.Clone()
    $case.RuntimeRunning = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_RUNTIME_NOT_RUNNING') {
        throw 'Stopped current native runtime was not attributed to the runtime owner.'
    }

    $case = $base.Clone()
    $case.RootAuthorityObservation = 'UNAVAILABLE'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_ROOT_AUTHORITY_UNAVAILABLE') {
        throw 'Root authority failure was not attributed to the root authority boundary.'
    }

    $case = $base.Clone()
    $case.CellularBoundaryFailure = 'NetworkHandleUnavailable'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_CELLULAR_BOUNDARY_NetworkHandleUnavailable') {
        throw 'Typed Cellular boundary failure was not preserved.'
    }

    $case = $base.Clone()
    $case.CellularAdmitted = $false
    $case.CellularState = 'REJECTED'
    $case.CellularReason = 'NO_VALIDATED_CELLULAR'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_CELLULAR_REJECTED_NO_VALIDATED_CELLULAR') {
        throw 'Current Cellular admission failure was not attributed to Cellular Egress.'
    }

    $case = $base.Clone()
    $case.RootPolicyAuthorized = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_ROOT_POLICY_NOT_AUTHORIZED') {
        throw 'Root policy authorization failure was not distinguished from root authority.'
    }

    $case = $base.Clone()
    $case.ProxyHealthy = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_PROXY_SERVING_UNHEALTHY') {
        throw 'Native Proxy Serving health failure was not attributed to Proxy Serving.'
    }

    $case = $base.Clone()
    $case.CredentialActive = $false
    $case.CredentialLeaseStatus = 'NOT_ATTEMPTED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_CREDENTIAL_INACTIVE') {
        throw 'Inactive PRODUCT credential was not distinguished from a LAB lease failure.'
    }

    $case = $base.Clone()
    $case.CredentialLeaseStatus = 'PROVISIONING_FAILED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'LAB_CREDENTIAL_PROVISIONING_FAILED') {
        throw 'LAB credential provisioning failure was not attributed to LAB.'
    }

    $case = $base.Clone()
    $case.MeshAdmitted = $false
    $case.MeshState = 'NOT_ADMITTED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_MESH_NOT_ADMITTED_NOT_ADMITTED') {
        throw 'Current Mesh admission failure was not attributed to Mesh.'
    }

    $case = $base.Clone()
    $case.MeshEpochPresent = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_MESH_ADMISSION_EPOCH_MISSING') {
        throw 'Missing Mesh admission epoch was not distinguished from external Mesh reachability.'
    }

    $case = $base.Clone()
    $case.MeshIngressRunning = $false
    $case.MeshIngressFailure = 'LISTENER_UNAVAILABLE'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_MESH_INGRESS_LISTENER_UNAVAILABLE') {
        throw 'Mesh ingress owner failure was not preserved.'
    }

    $case = $base.Clone()
    $case.ReadinessBindingEligible = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'READINESS_BINDING_INELIGIBLE') {
        throw 'Readiness structural binding failure was not distinguished from the probe result.'
    }

    $case = $base.Clone()
    $case.ReadinessProbeState = 'FAILED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'READINESS_PROBE_FAILED') {
        throw 'Current readiness probe state was not preserved.'
    }

    $case = $base.Clone()
    $case.LoopbackResult = 'FAIL'
    $case.LoopbackReason = 'AUTHENTICATION_FAILED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_LOOPBACK_E2E_AUTHENTICATION_FAILED') {
        throw 'External loopback E2E failure was not preserved.'
    }

    if ((Get-MishDeviceDiagnosticClassification @base) -cne 'PASS') {
        throw 'Healthy current L8 fact set did not classify PASS.'
    }

    $reportScript = Join-Path $PSScriptRoot 'new-device-cycle-report.ps1'
    $controlSha = '1' * 40

    $passDiagnostic = Join-Path $root 'pass-diagnostic.json'
    [ordered]@{ classification = 'PASS'; collection_result = 'PASS'; schema = 'mish.lab.diagnostic/v2' } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $passDiagnostic
    $report = & $reportScript `
        -Mode full `
        -PrNumber 195 `
        -SourceSha ('a' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $passDiagnostic `
        -RequestedProbe none `
        -OutputPath (Join-Path $root 'pass-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$report.cycle_result -cne 'PASS' -or
        [string]$report.acceptance_scope -cne 'FULL_BASELINE' -or
        [string]$report.exact_candidate_acceptance -cne 'PASS' -or
        [bool]$report.targeted_probe.automatic -ne $false
    ) {
        throw 'Full PASS report must accept the exact current candidate and contain no automatic probe decision.'
    }

    $productDiagnostic = Join-Path $root 'product-diagnostic.json'
    [ordered]@{
        schema = 'mish.lab.diagnostic/v2'
        classification = 'PRODUCT_PROXY_LEGACY_CUTOVER_CLEANUP_BLOCKED'
        collection_result = 'PASS'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $productDiagnostic
    $productReport = & $reportScript `
        -Mode full `
        -PrNumber 195 `
        -SourceSha ('b' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $productDiagnostic `
        -RequestedProbe none `
        -OutputPath (Join-Path $root 'product-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$productReport.cycle_result -cne 'PRODUCT_FAIL' -or
        [string]$productReport.classification -cne 'PRODUCT_PROXY_LEGACY_CUTOVER_CLEANUP_BLOCKED' -or
        [string]$productReport.exact_candidate_acceptance -cne 'FAIL'
    ) {
        throw 'Current L8 PRODUCT diagnostic classification and exact candidate rejection were not preserved.'
    }

    $launchFailure = Join-Path $root 'launch-failure.json'
    [ordered]@{
        schema = 'mish.device-start/v1'
        result = 'FAIL'
        failure_category = 'PROCESS_NOT_STABLE'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $launchFailure
    $launchFailureReport = & $reportScript `
        -Mode full `
        -PrNumber 195 `
        -SourceSha ('c' * 40) `
        -ControlSha $controlSha `
        -LaunchReceiptPath $launchFailure `
        -RequestedProbe none `
        -OutputPath (Join-Path $root 'launch-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$launchFailureReport.cycle_result -cne 'LAB_FAIL' -or
        [string]$launchFailureReport.classification -cne 'LAB_LAUNCH_PROCESS_NOT_STABLE' -or
        [string]$launchFailureReport.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'Typed launcher failure must remain a LAB failure and cannot reject the PRODUCT candidate.'
    }

    $missingProbe = & $reportScript `
        -Mode probe_only `
        -PrNumber 195 `
        -SourceSha ('d' * 40) `
        -ControlSha $controlSha `
        -RequestedProbe runtime_identity `
        -OutputPath (Join-Path $root 'missing-probe-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$missingProbe.cycle_result -cne 'LAB_FAIL' -or
        [string]$missingProbe.classification -cne 'LAB_TARGETED_PROBE_COLLECTION_FAILED' -or
        [string]$missingProbe.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'Explicit probe without evidence must fail closed without evaluating the PRODUCT candidate.'
    }

    # Historical runtime-identity is intentionally isolated as a manual read-only cutover probe.
    # It may observe a pre-L8 orphan, but its evidence can never become steady-state PRODUCT PASS.
    $targetedEvidence = Join-Path $root 'targeted-evidence.json'
    [ordered]@{
        schema = 'mish.lab.runtime-identity/v1'
        classification = 'VISIBLE_PROCESS_WITHOUT_RECORDED_IDENTITY'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $targetedEvidence
    $probeReport = & $reportScript `
        -Mode probe_only `
        -PrNumber 195 `
        -SourceSha ('e' * 40) `
        -ControlSha $controlSha `
        -RequestedProbe runtime_identity `
        -TargetedEvidencePath $targetedEvidence `
        -OutputPath (Join-Path $root 'probe-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$probeReport.cycle_result -cne 'PASS' -or
        [string]$probeReport.classification -cne 'MANUAL_PROBE_COMPLETED' -or
        [string]$probeReport.exact_candidate_acceptance -cne 'NOT_EVALUATED' -or
        [bool]$probeReport.targeted_probe.automatic -ne $false
    ) {
        throw 'Explicit probe-only evidence may pass collection but must never claim exact PRODUCT candidate acceptance.'
    }

    Write-Host 'DEVICE_CYCLE_CONTRACT=PASS'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

exit 0
