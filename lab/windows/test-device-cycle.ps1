$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path $env:TEMP ('mish-device-cycle-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    foreach ($path in @(
        'start-device-app.ps1',
        'select-device-cycle-probe.ps1',
        'collect-runtime-identity.ps1',
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
    $manualProjection = & $selector `
        -DiagnosticEvidencePath $manualEvidence `
        -RequestedProbe runtime_identity `
        -OutputPath (Join-Path $root 'manual-selection.json') | ConvertFrom-Json
    if ([string]$manualProjection.selected -cne 'runtime_identity') {
        throw 'Explicit manual probe override was not preserved.'
    }

    $reportScript = Join-Path $PSScriptRoot 'new-device-cycle-report.ps1'
    $passDiagnostic = Join-Path $root 'pass-diagnostic.json'
    [ordered]@{ classification = 'PASS'; collection_result = 'PASS' } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $passDiagnostic
    $reportPath = Join-Path $root 'report.json'
    $report = & $reportScript `
        -Mode full `
        -PrNumber 169 `
        -SourceSha ('a' * 40) `
        -DiagnosticEvidencePath $passDiagnostic `
        -OutputPath $reportPath | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$report.cycle_result -cne 'PASS' -or [string]$report.acceptance_scope -cne 'FULL_BASELINE') {
        throw 'Full PASS report projection is invalid.'
    }

    $productDiagnostic = Join-Path $root 'product-diagnostic.json'
    [ordered]@{ classification = 'PRODUCT_LOOPBACK_E2E_TRANSPORT_FAILED'; collection_result = 'PASS' } |
        ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $productDiagnostic
    $productReport = & $reportScript `
        -Mode full `
        -PrNumber 169 `
        -SourceSha ('b' * 40) `
        -DiagnosticEvidencePath $productDiagnostic `
        -OutputPath (Join-Path $root 'product-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$productReport.cycle_result -cne 'PRODUCT_FAIL') {
        throw 'Product failure was not classified as PRODUCT_FAIL.'
    }

    Write-Host 'DEVICE_CYCLE_CONTRACT=PASS'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

exit 0
