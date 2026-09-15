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
        ProxyState = 'RUNNING'
        ProxyFailure = ''
        CredentialActive = $true
        CredentialLeaseStatus = 'AVAILABLE'
        LoopbackResult = 'PASS'
        LoopbackReason = 'NONE'
        ReadinessState = 'READY'
        MeshIngressRunning = $true
        MeshIngressFailure = 'NONE'
        MeshEndpointCount = 1
        RoutePresent = $true
        Tcp3128 = $true
        MeshProbeResult = 'PASS'
        MeshProbeReason = 'NONE'
    }

    $case = $base.Clone()
    $case.ProxyState = 'FAILED'
    $case.ProxyFailure = 'STALE_PROCESS_IDENTITY_MISMATCH'
    $case.CredentialLeaseStatus = 'NOT_ATTEMPTED'
    $observed = Get-MishDeviceDiagnosticClassification @case
    if ($observed -cne 'PRODUCT_PROXY_STALE_PROCESS_IDENTITY_MISMATCH') {
        throw "Primary PRODUCT proxy failure was masked: $observed"
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

    if ((Get-MishDeviceDiagnosticClassification @base) -cne 'PASS') {
        throw 'Healthy fact set did not classify PASS.'
    }

    $reportScript = Join-Path $PSScriptRoot 'new-device-cycle-report.ps1'
    $controlSha = '1' * 40

    $passDiagnostic = Join-Path $root 'pass-diagnostic.json'
    [ordered]@{ classification = 'PASS'; collection_result = 'PASS' } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $passDiagnostic
    $report = & $reportScript `
        -Mode full `
        -PrNumber 169 `
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
        throw 'Full PASS report must accept the exact candidate and contain no automatic probe decision.'
    }

    $productDiagnostic = Join-Path $root 'product-diagnostic.json'
    [ordered]@{
        classification = 'PRODUCT_PROXY_STALE_PROCESS_IDENTITY_MISMATCH'
        collection_result = 'PASS'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $productDiagnostic
    $productReport = & $reportScript `
        -Mode full `
        -PrNumber 169 `
        -SourceSha ('b' * 40) `
        -ControlSha $controlSha `
        -DiagnosticEvidencePath $productDiagnostic `
        -RequestedProbe none `
        -OutputPath (Join-Path $root 'product-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$productReport.cycle_result -cne 'PRODUCT_FAIL' -or
        [string]$productReport.classification -cne 'PRODUCT_PROXY_STALE_PROCESS_IDENTITY_MISMATCH' -or
        [string]$productReport.exact_candidate_acceptance -cne 'FAIL'
    ) {
        throw 'Primary PRODUCT diagnostic classification and exact candidate rejection were not preserved.'
    }

    $launchFailure = Join-Path $root 'launch-failure.json'
    [ordered]@{
        schema = 'mish.device-start/v1'
        result = 'FAIL'
        failure_category = 'PROCESS_NOT_STABLE'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $launchFailure
    $launchFailureReport = & $reportScript `
        -Mode full `
        -PrNumber 169 `
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
        -PrNumber 169 `
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

    $targetedEvidence = Join-Path $root 'targeted-evidence.json'
    [ordered]@{
        schema = 'mish.lab.runtime-identity/v1'
        classification = 'VISIBLE_PROCESS_WITHOUT_RECORDED_IDENTITY'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $targetedEvidence
    $probeReport = & $reportScript `
        -Mode probe_only `
        -PrNumber 169 `
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
