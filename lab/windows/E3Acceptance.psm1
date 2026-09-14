Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Repository = 'iamaman11/mobile-proxy-mish'
$script:ReleaseSchema = 'mish.lab.release-verification/v1'
$script:HarnessSchema = 'mish.lab.e3-harness-verification/v1'
$script:AcceptanceSchema = 'mish.lab.e3-acceptance/v1'
$script:Hex40Pattern = '^[0-9a-f]{40}$'
$script:Hex64Pattern = '^[0-9a-f]{64}$'

function Stop-E3Acceptance {
    param([Parameter(Mandatory)][string]$Category,[Parameter(Mandatory)][string]$Message)
    throw "MISH_LABCTL_FAILURE|$Category|$Message"
}

function Read-E3AcceptanceJson {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){ Stop-E3Acceptance 'ARTIFACT_MISSING' 'Required E3 acceptance input is missing.' }
    try { return Get-Content -Raw -LiteralPath $full | ConvertFrom-Json }
    catch { Stop-E3Acceptance 'ARTIFACT_INVALID' 'Required E3 acceptance input is invalid JSON.' }
}

function Write-E3AcceptanceJson {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    $parent=Split-Path -Parent $full
    if($parent){ [IO.Directory]::CreateDirectory($parent)|Out-Null }
    [IO.File]::WriteAllText($full,(($Value|ConvertTo-Json -Depth 12)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    return $full
}

function Get-E3AcceptanceSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){ Stop-E3Acceptance 'ARTIFACT_MISSING' 'Required E3 acceptance artifact is missing.' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-Hex40 { param([string]$Value,[string]$Name) if($Value -notmatch $script:Hex40Pattern){ Stop-E3Acceptance 'IDENTITY_MISMATCH' "$Name must be lowercase 40-hex." } }
function Assert-Hex64 { param([string]$Value,[string]$Name) if($Value -notmatch $script:Hex64Pattern){ Stop-E3Acceptance 'IDENTITY_MISMATCH' "$Name must be lowercase 64-hex." } }

function Assert-PhysicalMain {
    if($env:GITHUB_REPOSITORY -ne $script:Repository -or $env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_REF_PROTECTED -ne 'true'){
        Stop-E3Acceptance 'UNTRUSTED_REF' 'E3 acceptance projection requires protected main.'
    }
    if($env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64'){
        Stop-E3Acceptance 'IDENTITY_MISMATCH' 'E3 acceptance projection requires the accepted Windows x64 LAB boundary.'
    }
    Assert-Hex40 ([string]$env:GITHUB_SHA) 'ExecutionAdapterCommit'
    if([string]::IsNullOrWhiteSpace([string]$env:GITHUB_RUN_ID)){ Stop-E3Acceptance 'IDENTITY_MISMATCH' 'E3 acceptance projection requires a workflow run identity.' }
}

function Invoke-E3AcceptanceProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReleaseVerificationReceipt,
        [Parameter(Mandatory)][string]$HarnessVerificationReceipt,
        [Parameter(Mandatory)][string]$ExecutionResultPath,
        [Parameter(Mandatory)][string]$EvidencePath
    )
    Assert-PhysicalMain

    $release=Read-E3AcceptanceJson $ReleaseVerificationReceipt
    if([string]$release.schema -ne $script:ReleaseSchema -or [string]$release.result -ne 'PASS' -or [string]$release.repository -ne $script:Repository){
        Stop-E3Acceptance 'VERIFICATION_REQUIRED' 'Matching PASS release verification is required.'
    }
    $tag=[string]$release.tag; $source=[string]$release.source_commit; $abi=[string]$release.abi
    $apkSha=[string]$release.apk.sha256; $cert=[string]$release.apk.signing_certificate_sha256; $apkPath=[string]$release.apk.path
    Assert-Hex40 $source 'ReleaseSource'; Assert-Hex64 $apkSha 'ProductApkSha256'; Assert-Hex64 $cert 'SigningCertificateSha256'
    if(-not [IO.Path]::IsPathFullyQualified($apkPath) -or (Get-E3AcceptanceSha256 $apkPath) -ne $apkSha){ Stop-E3Acceptance 'DIGEST_MISMATCH' 'Verified PRODUCT APK bytes changed before E3 acceptance projection.' }

    $h=Read-E3AcceptanceJson $HarnessVerificationReceipt
    if([string]$h.schema -ne $script:HarnessSchema -or [string]$h.result -ne 'PASS' -or [string]$h.repository -ne $script:Repository -or
       [string]$h.rc_tag -ne $tag -or [string]$h.source_commit -ne $source -or [string]$h.product_abi -ne $abi -or
       [string]$h.signing_certificate_sha256 -ne $cert -or [string]$h.product_apk.sha256 -ne $apkSha){
        Stop-E3Acceptance 'VERIFICATION_REQUIRED' 'Matching PASS E3 harness verification is required.'
    }
    $testSha=[string]$h.test_apk.sha256; $testPath=[string]$h.test_apk.path
    Assert-Hex64 $testSha 'TestApkSha256'
    if(-not [IO.Path]::IsPathFullyQualified($testPath) -or (Get-E3AcceptanceSha256 $testPath) -ne $testSha){ Stop-E3Acceptance 'DIGEST_MISMATCH' 'Verified E3 test APK bytes changed before acceptance projection.' }

    $execution=Read-E3AcceptanceJson $ExecutionResultPath
    if([string]$execution.result -ne 'PASS' -or [string]$execution.scenario -ne 'full-root-toggle' -or $execution.e3_pass -ne $true -or
       [string]$execution.rc_tag -ne $tag -or [string]$execution.source_commit -ne $source -or [string]$execution.product_abi -ne $abi -or
       [string]$execution.test_apk_sha256 -ne $testSha){
        Stop-E3Acceptance 'E3_NOT_ACCEPTED' 'Execution result is not an exact matching E3 physical PASS.'
    }

    $evidence=[ordered]@{
        schema=$script:AcceptanceSchema
        result='PASS'
        e3_pass=$true
        repository=$script:Repository
        scenario='full-root-toggle'
        execution_adapter=[ordered]@{
            git_ref=[string]$env:GITHUB_REF
            git_commit=[string]$env:GITHUB_SHA
            run_id=[string]$env:GITHUB_RUN_ID
        }
        release=[ordered]@{
            tag=$tag
            source_commit=$source
            abi=$abi
            apk_sha256=$apkSha
            signing_certificate_sha256=$cert
        }
        harness=[ordered]@{
            run_id=[long]$h.run.id
            artifact_id=[long]$h.artifact.id
            artifact_zip_sha256=[string]$h.artifact.zip_sha256
            test_apk_sha256=$testSha
            signing_certificate_sha256=[string]$h.signing_certificate_sha256
            instrumentation_class=[string]$h.instrumentation.class
            instrumentation_component=[string]$h.instrumentation.component
        }
        completed_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
    }
    $written=Write-E3AcceptanceJson $evidence $EvidencePath
    return [pscustomobject]@{ result='PASS'; e3_pass=$true; rc_tag=$tag; source_commit=$source; apk_sha256=$apkSha; evidence=$written }
}

Export-ModuleMember -Function Invoke-E3AcceptanceProjection
