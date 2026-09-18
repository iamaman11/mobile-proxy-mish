$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path $env:TEMP ('mish-device-candidate-store-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    $source = 'a' * 40
    $pr = 138
    $artifactId = 424242
    $artifactName = "device-candidate-pr-$pr-$source"
    $artifactDigest = 'sha256:' + ('c' * 64)
    $hostedRunId = 31337
    $download = Join-Path $root 'download'
    $store = Join-Path $root 'store'
    New-Item -ItemType Directory -Force -Path $download | Out-Null

    $product = Join-Path $download 'mobile-proxy-mish-debug.apk'
    $testApk = Join-Path $download 'mobile-proxy-mish-debug-androidTest.apk'
    [IO.File]::WriteAllBytes($product, [Text.Encoding]::UTF8.GetBytes('hosted-product'))
    [IO.File]::WriteAllBytes($testApk, [Text.Encoding]::UTF8.GetBytes('hosted-test'))
    $productSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $product).Hash.ToLowerInvariant()
    $testSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $testApk).Hash.ToLowerInvariant()
    [ordered]@{
        schema = 'mish-device-candidate-v1'
        pr_number = $pr
        source_sha = $source
        base_sha = ('b' * 40)
        application_id = 'com.mobileproxymish.app.debug'
        target_abi = 'armeabi-v7a'
        product_apk = [ordered]@{ name = 'mobile-proxy-mish-debug.apk'; sha256 = $productSha }
        android_test_apk = [ordered]@{ name = 'mobile-proxy-mish-debug-androidTest.apk'; sha256 = $testSha }
    } | ConvertTo-Json -Depth 6 -Compress | Set-Content -Encoding UTF8 -LiteralPath (Join-Path $download 'candidate.json')

    $script = Join-Path $PSScriptRoot 'materialize-device-candidate.ps1'
    $projectionJson = & $script `
        -CandidateDirectory $download `
        -ExpectedPrNumber $pr `
        -ExpectedSourceSha $source `
        -ArtifactId $artifactId `
        -ArtifactName $artifactName `
        -ArtifactDigest $artifactDigest `
        -HostedRunId $hostedRunId `
        -StoreRoot $store
    $projection = $projectionJson | ConvertFrom-Json

    $expectedRoot = Join-Path (Join-Path $store $source) ([string]$artifactId)
    if ([IO.Path]::GetFullPath([string]$projection.version_root) -cne [IO.Path]::GetFullPath($expectedRoot)) {
        throw 'Canonical candidate version root is not <StoreRoot>\<source_sha>\<artifact_id>.'
    }
    foreach ($required in @(
        (Join-Path $expectedRoot 'provenance.json'),
        (Join-Path $expectedRoot 'hosted\candidate.json'),
        (Join-Path $expectedRoot 'hosted\mobile-proxy-mish-debug.apk'),
        (Join-Path $expectedRoot 'hosted\mobile-proxy-mish-debug-androidTest.apk')
    )) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Canonical candidate store is missing: $required"
        }
    }
    foreach ($directory in @(
        (Join-Path $expectedRoot 'signed'),
        (Join-Path $expectedRoot 'receipts')
    )) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            throw "Canonical candidate store directory is missing: $directory"
        }
    }

    $repeat = (& $script `
        -CandidateDirectory $download `
        -ExpectedPrNumber $pr `
        -ExpectedSourceSha $source `
        -ArtifactId $artifactId `
        -ArtifactName $artifactName `
        -ArtifactDigest $artifactDigest `
        -HostedRunId $hostedRunId `
        -StoreRoot $store) | ConvertFrom-Json
    if ([string]$repeat.version_root -cne [string]$projection.version_root) {
        throw 'Idempotent materialization returned a different version root.'
    }

    $storedProduct = Join-Path $expectedRoot 'hosted\mobile-proxy-mish-debug.apk'
    Add-Content -Encoding UTF8 -LiteralPath $storedProduct -Value 'tampered'
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $script,
        '-CandidateDirectory', $download,
        '-ExpectedPrNumber', [string]$pr,
        '-ExpectedSourceSha', $source,
        '-ArtifactId', [string]$artifactId,
        '-ArtifactName', $artifactName,
        '-ArtifactDigest', $artifactDigest,
        '-HostedRunId', [string]$hostedRunId,
        '-StoreRoot', $store
    )
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $negative = @(& $pwsh @arguments 2>&1)
        $negativeExit = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    if ($negativeExit -eq 0 -or ($negative -join ' ') -notmatch 'MISH_DEVICE_CANDIDATE_STORE_FAILURE\|STORE_DIGEST_CONFLICT\|') {
        throw "Tampered durable candidate did not fail closed: $($negative -join ' ')"
    }

    if (Test-Path -LiteralPath (Join-Path $store 'latest')) {
        throw 'Mutable latest candidate pointer is forbidden.'
    }
    if (Test-Path -LiteralPath (Join-Path $store 'current')) {
        throw 'Mutable current candidate pointer is forbidden.'
    }

    Write-Host 'DEVICE_CANDIDATE_STORE_CONTRACT=PASS'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

exit 0
