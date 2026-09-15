$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path $env:TEMP ('mish-device-cycle-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    foreach ($path in @(
        'start-device-app.ps1',
        'collect-device-diagnostic.ps1',
        'select-device-cycle-probe.ps1',
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

    $selector = Join-Path $PSScriptRoot 'select-device-cycle-probe.ps1'
    $cases = @(
        [pscustomobject]@{
            Name = 'ownership failure wins over transport classification'
            Classification = 'PRODUCT_LOOPBACK_E2E_TRANSPORT_FAILED'
            ProxyFailure = 'STALE_PROCESS_IDENTITY_MISMATCH'
            Expected = 'runtime_identity'
        },
        [pscustomobject]@{
            Name = 'loopback failure selects raw CONNECT probe'
            Classification = 'PRODUCT_LOOPBACK_E2E_AUTHENTICATION_FAILED'
            ProxyFailure = $null
            Expected = 'loopback_connect'
        },
        [pscustomobject]@{
            Name = 'clean baseline selects no extra probe'
            Classification = 'PASS'
            ProxyFailure = $null
            Expected = 'none'
        }
    )

    foreach ($case in $cases) {
        $evidencePath = Join-Path $root (($case.Name -replace '[^A-Za-z0-9]+', '-') + '.json')
        $selectionPath = "$evidencePath.selection.json"
        [ordered]@{
            classification = $case.Classification
            android = [ordered]@{
                proxy = [ordered]@{ failure = $case.ProxyFailure }
            }
        } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $evidencePath
        $projection = & $selector `
            -DiagnosticEvidencePath $evidencePath `
            -RequestedProbe auto `
            -OutputPath $selectionPath | ConvertFrom-Json
        if ([string]$projection.selected -cne [string]$case.Expected) {
            throw "Probe selection failed for '$($case.Name)': expected $($case.Expected), observed $($projection.selected)."
        }
    }

    $manualEvidence = Join-Path $root 'manual.json'
    [ordered]@{
        classification = 'PASS'
        android = [ordered]@{ proxy = [ordered]@{ failure = $null } }
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $manualEvidence
    $manualSelectionPath = Join-Path $root 'manual-selection.json'
    $manualProjection = & $selector `
        -DiagnosticEvidencePath $manualEvidence `
        -RequestedProbe runtime_identity `
        -OutputPath $manualSelectionPath | ConvertFrom-Json
    if ([string]$manualProjection.selected -cne 'runtime_identity') {
        throw 'Explicit manual probe override was not preserved.'
    }

    $reportScript = Join-Path $PSScriptRoot 'new-device-cycle-report.ps1'
    $passDiagnostic = Join-Path $root 'pass-diagnostic.json'
    [ordered]@{ classification = 'PASS'; collection_result = 'PASS' } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $passDiagnostic
    $noneSelection = Join-Path $root 'none-selection.json'
    [ordered]@{
        schema = 'mish.device-cycle-probe-selection/v1'
        requested = 'auto'
        selected = 'none'
        classification = 'PASS'
        proxy_failure = ''
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $noneSelection
    $reportPath = Join-Path $root 'report.json'
    $report = & $reportScript `
        -Mode full `
        -PrNumber 169 `
        -SourceSha ('a' * 40) `
        -DiagnosticEvidencePath $passDiagnostic `
        -ProbeSelectionPath $noneSelection `
        -OutputPath $reportPath | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$report.cycle_result -cne 'PASS' -or [string]$report.acceptance_scope -cne 'FULL_BASELINE') {
        throw 'Full PASS report projection is invalid.'
    }

    $productDiagnostic = Join-Path $root 'product-diagnostic.json'
    [ordered]@{ classification = 'PRODUCT_LOOPBACK_E2E_TRANSPORT_FAILED'; collection_result = 'PASS' } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $productDiagnostic
    $productSelection = Join-Path $root 'product-selection.json'
    [ordered]@{
        schema = 'mish.device-cycle-probe-selection/v1'
        requested = 'auto'
        selected = 'loopback_connect'
        classification = 'PRODUCT_LOOPBACK_E2E_TRANSPORT_FAILED'
        proxy_failure = ''
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $productSelection
    $productReport = & $reportScript `
        -Mode full `
        -PrNumber 169 `
        -SourceSha ('b' * 40) `
        -DiagnosticEvidencePath $productDiagnostic `
        -ProbeSelectionPath $productSelection `
        -OutputPath (Join-Path $root 'product-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$productReport.cycle_result -cne 'PRODUCT_FAIL' -or
        [string]$productReport.classification -cne 'PRODUCT_LOOPBACK_E2E_TRANSPORT_FAILED'
    ) {
        throw 'Product failure was not preserved while optional targeted evidence was missing.'
    }

    $launchFailure = Join-Path $root 'launch-failure.json'
    [ordered]@{
        schema = 'mish.device-start/v1'
        result = 'FAIL'
        package = 'com.mobileproxymish.app.debug'
        component = 'com.mobileproxymish.app.debug/com.mobileproxymish.app.MainActivity'
        failure_category = 'PROCESS_NOT_STABLE'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $launchFailure
    $launchFailureReport = & $reportScript `
        -Mode full `
        -PrNumber 169 `
        -SourceSha ('c' * 40) `
        -LaunchReceiptPath $launchFailure `
        -OutputPath (Join-Path $root 'launch-failure-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$launchFailureReport.cycle_result -cne 'LAB_FAIL' -or
        [string]$launchFailureReport.classification -cne 'LAB_LAUNCH_PROCESS_NOT_STABLE'
    ) {
        throw 'Typed launcher failure was not preserved as a LAB failure.'
    }

    $missingProbeReport = & $reportScript `
        -Mode probe_only `
        -PrNumber 169 `
        -SourceSha ('d' * 40) `
        -ProbeSelectionPath $manualSelectionPath `
        -OutputPath (Join-Path $root 'missing-probe-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$missingProbeReport.cycle_result -cne 'LAB_FAIL' -or
        [string]$missingProbeReport.classification -cne 'LAB_TARGETED_PROBE_COLLECTION_FAILED'
    ) {
        throw 'Missing probe-only evidence must fail closed instead of reporting PASS.'
    }

    $missingManualProbeReport = & $reportScript `
        -Mode diagnose_only `
        -PrNumber 169 `
        -SourceSha ('e' * 40) `
        -DiagnosticEvidencePath $passDiagnostic `
        -ProbeSelectionPath $manualSelectionPath `
        -OutputPath (Join-Path $root 'missing-manual-probe-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$missingManualProbeReport.cycle_result -cne 'LAB_FAIL' -or
        [string]$missingManualProbeReport.classification -cne 'LAB_TARGETED_PROBE_COLLECTION_FAILED'
    ) {
        throw 'Missing requested diagnose-only probe evidence must fail closed.'
    }

    $targetedEvidence = Join-Path $root 'targeted-evidence.json'
    [ordered]@{
        schema = 'mish.lab.runtime-identity/v1'
        classification = 'NO_RUNTIME_IDENTITY_CONFLICT'
    } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $targetedEvidence
    $probeOnlyPassReport = & $reportScript `
        -Mode probe_only `
        -PrNumber 169 `
        -SourceSha ('f' * 40) `
        -ProbeSelectionPath $manualSelectionPath `
        -TargetedEvidencePath $targetedEvidence `
        -OutputPath (Join-Path $root 'probe-only-pass-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$probeOnlyPassReport.cycle_result -cne 'PASS' -or
        [string]$probeOnlyPassReport.classification -cne 'MANUAL_PROBE_COMPLETED'
    ) {
        throw 'Probe-only PASS requires actual targeted evidence.'
    }

    Write-Host 'DEVICE_CYCLE_CONTRACT=PASS'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

exit 0
