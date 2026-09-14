$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path $env:TEMP ('mish-device-candidate-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    $source = 'a' * 40
    $product = Join-Path $root 'mobile-proxy-mish-debug.apk'
    $testApk = Join-Path $root 'mobile-proxy-mish-debug-androidTest.apk'
    [IO.File]::WriteAllBytes($product, [Text.Encoding]::UTF8.GetBytes('product-candidate'))
    [IO.File]::WriteAllBytes($testApk, [Text.Encoding]::UTF8.GetBytes('test-candidate'))
    $productSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $product).Hash.ToLowerInvariant()
    $testSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $testApk).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        schema = 'mish-device-candidate-v1'
        pr_number = 138
        source_sha = $source
        base_sha = ('b' * 40)
        application_id = 'com.mobileproxymish.app.debug'
        target_abi = 'armeabi-v7a'
        product_apk = [ordered]@{ name = 'mobile-proxy-mish-debug.apk'; sha256 = $productSha }
        android_test_apk = [ordered]@{ name = 'mobile-proxy-mish-debug-androidTest.apk'; sha256 = $testSha }
    }
    $manifest | ConvertTo-Json -Depth 6 -Compress | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $root 'candidate.json')

    $consumer = Join-Path $PSScriptRoot 'install-device-candidate.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $consumer,
        '-CandidateDirectory', $root,
        '-ExpectedPrNumber', '138',
        '-ExpectedSourceSha', $source,
        '-VerifyOnly'
    )

    $output = @(& $pwsh @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Verify-only candidate consumer failed unexpectedly: $($output -join ' ')"
    }
    $projection = ($output -join [Environment]::NewLine) | ConvertFrom-Json
    if ($projection.result -ne 'PASS' -or $projection.mode -ne 'verify-only' -or $projection.source_sha -ne $source -or $projection.local_build -ne $false) {
        throw 'Verify-only candidate projection is invalid.'
    }

    Add-Content -Encoding UTF8 -LiteralPath $product -Value 'tampered'
    $output = @(& $pwsh @arguments 2>&1)
    if ($LASTEXITCODE -eq 0) {
        throw 'Tampered candidate unexpectedly passed verification.'
    }
    if (($output -join ' ') -notmatch 'MISH_DEVICE_CANDIDATE_FAILURE\|DIGEST_MISMATCH\|') {
        throw "Tampered candidate failed for the wrong reason: $($output -join ' ')"
    }

    Write-Host 'Device candidate verification contract passed.'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}
