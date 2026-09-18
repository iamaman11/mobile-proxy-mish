[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CandidateDirectory,
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int] $ExpectedPrNumber,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedSourceSha,
    [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $ArtifactId,
    [Parameter(Mandatory)][string] $ArtifactName,
    [Parameter(Mandatory)][ValidatePattern('^sha256:[0-9a-f]{64}$')][string] $ArtifactDigest,
    [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $HostedRunId,
    [string] $StoreRoot = 'C:\mish-lab\runner\.state\device-candidate\versions'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$schema = 'mish.device-candidate-local/v1'
$candidateSchema = 'mish-device-candidate-v1'
$productName = 'mobile-proxy-mish-debug.apk'
$testName = 'mobile-proxy-mish-debug-androidTest.apk'
$manifestName = 'candidate.json'
$expectedArtifactName = "device-candidate-pr-$ExpectedPrNumber-$ExpectedSourceSha"

function Stop-Materialization {
    param([Parameter(Mandatory)][string] $Category, [Parameter(Mandatory)][string] $Message)
    throw "MISH_DEVICE_CANDIDATE_STORE_FAILURE|$Category|$Message"
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Materialization 'SOURCE_MISSING' "Required hosted candidate file is missing: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-Json {
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Category)
    try {
        return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    }
    catch {
        Stop-Materialization $Category "Invalid JSON: $Path"
    }
}

if ($ArtifactName -cne $expectedArtifactName) {
    Stop-Materialization 'ARTIFACT_IDENTITY_MISMATCH' 'Resolved artifact name does not match PR/source identity.'
}

$sourceRoot = [IO.Path]::GetFullPath($CandidateDirectory)
$manifestPath = Join-Path $sourceRoot $manifestName
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Stop-Materialization 'SOURCE_MISSING' 'Downloaded candidate.json is missing.'
}
$manifest = Read-Json -Path $manifestPath -Category 'MANIFEST_INVALID'
if ([string]$manifest.schema -cne $candidateSchema) {
    Stop-Materialization 'MANIFEST_INVALID' 'Candidate schema mismatch.'
}
if ([int]$manifest.pr_number -ne $ExpectedPrNumber -or [string]$manifest.source_sha -cne $ExpectedSourceSha) {
    Stop-Materialization 'MANIFEST_IDENTITY_MISMATCH' 'Candidate manifest PR/source identity mismatch.'
}
if ([string]$manifest.product_apk.name -cne $productName -or [string]$manifest.android_test_apk.name -cne $testName) {
    Stop-Materialization 'MANIFEST_INVALID' 'Candidate manifest APK names are not canonical.'
}

$productPath = Join-Path $sourceRoot $productName
$testPath = Join-Path $sourceRoot $testName
$productSha = Get-Sha256 $productPath
$testSha = Get-Sha256 $testPath
if ($productSha -cne [string]$manifest.product_apk.sha256) {
    Stop-Materialization 'HOSTED_PRODUCT_DIGEST_MISMATCH' 'Downloaded PRODUCT APK does not match candidate.json.'
}
if ($testSha -cne [string]$manifest.android_test_apk.sha256) {
    Stop-Materialization 'HOSTED_TEST_DIGEST_MISMATCH' 'Downloaded AndroidTest APK does not match candidate.json.'
}

$store = [IO.Path]::GetFullPath($StoreRoot)
$versionRoot = Join-Path (Join-Path $store $ExpectedSourceSha) ([string]$ArtifactId)
$hostedDirectory = Join-Path $versionRoot 'hosted'
$signedDirectory = Join-Path $versionRoot 'signed'
$receiptsDirectory = Join-Path $versionRoot 'receipts'
$provenancePath = Join-Path $versionRoot 'provenance.json'

$provenance = [ordered]@{
    schema = $schema
    pr_number = $ExpectedPrNumber
    source_sha = $ExpectedSourceSha
    hosted_run_id = $HostedRunId
    artifact_id = $ArtifactId
    artifact_name = $ArtifactName
    artifact_digest = $ArtifactDigest
    hosted_product_apk_sha256 = $productSha
    hosted_android_test_apk_sha256 = $testSha
}

function Test-ExistingVersion {
    if (-not (Test-Path -LiteralPath $provenancePath -PathType Leaf)) { return $false }
    $existing = Read-Json -Path $provenancePath -Category 'STORE_PROVENANCE_INVALID'
    foreach ($property in @(
        'schema', 'pr_number', 'source_sha', 'hosted_run_id', 'artifact_id',
        'artifact_name', 'artifact_digest', 'hosted_product_apk_sha256',
        'hosted_android_test_apk_sha256'
    )) {
        if ([string]$existing.$property -cne [string]$provenance.$property) {
            Stop-Materialization 'STORE_IDENTITY_CONFLICT' "Existing version provenance differs at $property."
        }
    }
    $storedManifest = Join-Path $hostedDirectory $manifestName
    $storedProduct = Join-Path $hostedDirectory $productName
    $storedTest = Join-Path $hostedDirectory $testName
    if (-not (Test-Path -LiteralPath $storedManifest -PathType Leaf) -or
        -not (Test-Path -LiteralPath $storedProduct -PathType Leaf) -or
        -not (Test-Path -LiteralPath $storedTest -PathType Leaf)) {
        Stop-Materialization 'STORE_INCOMPLETE' 'Existing version directory is incomplete.'
    }
    if ((Get-Sha256 $storedProduct) -cne $productSha -or (Get-Sha256 $storedTest) -cne $testSha) {
        Stop-Materialization 'STORE_DIGEST_CONFLICT' 'Existing hosted APK bytes differ from resolved GitHub artifact.'
    }
    $storedManifestSha = Get-Sha256 $storedManifest
    $sourceManifestSha = Get-Sha256 $manifestPath
    if ($storedManifestSha -cne $sourceManifestSha) {
        Stop-Materialization 'STORE_MANIFEST_CONFLICT' 'Existing candidate.json differs from resolved GitHub artifact.'
    }
    return $true
}

if (Test-Path -LiteralPath $versionRoot) {
    if (-not (Test-ExistingVersion)) {
        Stop-Materialization 'STORE_INCOMPLETE' 'Existing version root has no valid provenance.'
    }
}
else {
    $sourceParent = Split-Path -Parent $versionRoot
    [IO.Directory]::CreateDirectory($sourceParent) | Out-Null
    $staging = Join-Path $sourceParent ('.staging-' + $ArtifactId + '-' + [Guid]::NewGuid().ToString('N'))
    try {
        $stagingHosted = Join-Path $staging 'hosted'
        [IO.Directory]::CreateDirectory($stagingHosted) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $staging 'signed')) | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $staging 'receipts')) | Out-Null

        Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $stagingHosted $manifestName)
        Copy-Item -LiteralPath $productPath -Destination (Join-Path $stagingHosted $productName)
        Copy-Item -LiteralPath $testPath -Destination (Join-Path $stagingHosted $testName)
        [IO.File]::WriteAllText(
            (Join-Path $staging 'provenance.json'),
            (($provenance | ConvertTo-Json -Depth 6) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )

        if ((Get-Sha256 (Join-Path $stagingHosted $productName)) -cne $productSha -or
            (Get-Sha256 (Join-Path $stagingHosted $testName)) -cne $testSha) {
            Stop-Materialization 'STORE_COPY_DIGEST_MISMATCH' 'Durable copy changed hosted APK bytes.'
        }

        Move-Item -LiteralPath $staging -Destination $versionRoot
    }
    finally {
        Remove-Item -Recurse -Force -LiteralPath $staging -ErrorAction SilentlyContinue
    }
}

[pscustomobject]@{
    schema = $schema
    version_root = $versionRoot
    hosted_directory = $hostedDirectory
    signed_directory = $signedDirectory
    receipts_directory = $receiptsDirectory
    provenance_path = $provenancePath
    source_sha = $ExpectedSourceSha
    artifact_id = $ArtifactId
    artifact_digest = $ArtifactDigest
    hosted_product_apk_sha256 = $productSha
    hosted_android_test_apk_sha256 = $testSha
} | ConvertTo-Json -Compress
