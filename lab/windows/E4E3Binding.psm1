Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

$script:Repository='iamaman11/mobile-proxy-mish'
$script:SessionSchema='mish.lab.e4-session/v1'
$script:E3AcceptanceSchema='mish.lab.e3-acceptance/v1'
$script:E4EvidenceSchema='mish.lab.e4-evidence/v1'
$script:Hex40Pattern='^[0-9a-f]{40}$'
$script:Hex64Pattern='^[0-9a-f]{64}$'

function Stop-E4Binding {
    param([Parameter(Mandatory)][string]$Category,[Parameter(Mandatory)][string]$Message)
    throw "MISH_LABCTL_FAILURE|$Category|$Message"
}

function Read-E4BindingJson {
    param([Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    if(-not(Test-Path -LiteralPath $full -PathType Leaf)){ Stop-E4Binding 'ARTIFACT_MISSING' 'Required E3/E4 binding input is missing.' }
    try{return Get-Content -Raw -LiteralPath $full|ConvertFrom-Json}catch{Stop-E4Binding 'ARTIFACT_INVALID' 'Required E3/E4 binding input is invalid JSON.'}
}

function Write-E4BindingJson {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Path)
    $full=[IO.Path]::GetFullPath($Path)
    [IO.File]::WriteAllText($full,(($Value|ConvertTo-Json -Depth 14)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    return $full
}

function Get-E4BindingSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path -PathType Leaf)){Stop-E4Binding 'ARTIFACT_MISSING' 'Required E3/E4 binding artifact is missing.'}
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}
function Assert-Hex40{param([string]$Value,[string]$Name)if($Value -notmatch $script:Hex40Pattern){Stop-E4Binding 'IDENTITY_MISMATCH' "$Name must be lowercase 40-hex."}}
function Assert-Hex64{param([string]$Value,[string]$Name)if($Value -notmatch $script:Hex64Pattern){Stop-E4Binding 'IDENTITY_MISMATCH' "$Name must be lowercase 64-hex."}}

function Assert-E3AcceptanceMatchesSession {
    param([Parameter(Mandatory)]$Session,[Parameter(Mandatory)]$Acceptance)
    if([string]$Acceptance.schema -ne $script:E3AcceptanceSchema -or [string]$Acceptance.result -ne 'PASS' -or $Acceptance.e3_pass -ne $true -or
       [string]$Acceptance.repository -ne $script:Repository -or [string]$Acceptance.scenario -ne 'full-root-toggle'){
        Stop-E4Binding 'E3_ACCEPTANCE_REQUIRED' 'A typed E3 physical PASS receipt is required before E4.'
    }
    $commit=[string]$Acceptance.execution_adapter.git_commit
    Assert-Hex40 $commit 'E3ExecutionAdapterCommit'
    if([string]$Acceptance.execution_adapter.git_ref -ne 'refs/heads/main' -or [string]::IsNullOrWhiteSpace([string]$Acceptance.execution_adapter.run_id)){
        Stop-E4Binding 'E3_ACCEPTANCE_REQUIRED' 'E3 acceptance must originate from a protected-main physical ceremony.'
    }
    $testSha=[string]$Acceptance.harness.test_apk_sha256
    Assert-Hex64 $testSha 'E3AcceptedTestApkSha256'
    if([string]$Acceptance.release.tag -ne [string]$Session.release.tag -or
       [string]$Acceptance.release.source_commit -ne [string]$Session.release.source_commit -or
       [string]$Acceptance.release.abi -ne [string]$Session.release.abi -or
       [string]$Acceptance.release.apk_sha256 -ne [string]$Session.release.apk_sha256 -or
       [string]$Acceptance.release.signing_certificate_sha256 -ne [string]$Session.release.signing_certificate_sha256 -or
       [string]$Acceptance.harness.signing_certificate_sha256 -ne [string]$Session.release.signing_certificate_sha256){
        Stop-E4Binding 'IDENTITY_MISMATCH' 'E3 acceptance and E4 session are not the exact same PRODUCT RC bytes.'
    }
    return [pscustomobject]@{ commit=$commit; run_id=[string]$Acceptance.execution_adapter.run_id; test_apk_sha256=$testSha }
}

function Add-E4E3Binding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SessionReceipt,
        [Parameter(Mandatory)][string]$E3AcceptancePath
    )
    $session=Read-E4BindingJson $SessionReceipt
    if([string]$session.schema -ne $script:SessionSchema -or [string]$session.result -ne 'READY' -or $session.e4_pass -ne $false){
        Stop-E4Binding 'VERIFICATION_REQUIRED' 'A READY non-PASS E4 session is required for E3 binding.'
    }
    $acceptancePath=[IO.Path]::GetFullPath($E3AcceptancePath)
    $acceptance=Read-E4BindingJson $acceptancePath
    $identity=Assert-E3AcceptanceMatchesSession $session $acceptance
    $sha=Get-E4BindingSha256 $acceptancePath
    Assert-Hex64 $sha 'E3AcceptanceSha256'

    $binding=[ordered]@{
        schema=$script:E3AcceptanceSchema
        path=$acceptancePath
        sha256=$sha
        execution_adapter_commit=$identity.commit
        execution_run_id=$identity.run_id
        test_apk_sha256=$identity.test_apk_sha256
    }
    if($session.PSObject.Properties['e3_acceptance']){$session.e3_acceptance=$binding}else{$session|Add-Member -NotePropertyName e3_acceptance -NotePropertyValue $binding}
    [void](Write-E4BindingJson $session $SessionReceipt)
    return [pscustomobject]@{result='READY';e4_pass=$false;e3_acceptance_sha256=$sha;receipt=[IO.Path]::GetFullPath($SessionReceipt)}
}

function Assert-E4E3Binding {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SessionReceipt)
    $session=Read-E4BindingJson $SessionReceipt
    if([string]$session.schema -ne $script:SessionSchema -or -not $session.PSObject.Properties['e3_acceptance']){
        Stop-E4Binding 'E3_ACCEPTANCE_REQUIRED' 'E4 session is missing exact E3 acceptance binding.'
    }
    $binding=$session.e3_acceptance
    if([string]$binding.schema -ne $script:E3AcceptanceSchema){Stop-E4Binding 'E3_ACCEPTANCE_REQUIRED' 'E4 session E3 acceptance schema mismatch.'}
    $path=[string]$binding.path; $expected=[string]$binding.sha256
    Assert-Hex64 $expected 'BoundE3AcceptanceSha256'
    if(-not [IO.Path]::IsPathFullyQualified($path) -or (Get-E4BindingSha256 $path) -ne $expected){
        Stop-E4Binding 'DIGEST_MISMATCH' 'Bound E3 acceptance receipt bytes are absent or changed.'
    }
    $acceptance=Read-E4BindingJson $path
    $identity=Assert-E3AcceptanceMatchesSession $session $acceptance
    if($identity.commit -ne [string]$binding.execution_adapter_commit -or $identity.run_id -ne [string]$binding.execution_run_id -or $identity.test_apk_sha256 -ne [string]$binding.test_apk_sha256){
        Stop-E4Binding 'IDENTITY_MISMATCH' 'Bound E3 acceptance identity changed.'
    }
    return [pscustomobject]@{result='PASS';e3_acceptance_sha256=$expected;execution_adapter_commit=$identity.commit;execution_run_id=$identity.run_id;test_apk_sha256=$identity.test_apk_sha256}
}

function Add-E4E3EvidenceProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$EvidencePath,
        [Parameter(Mandatory)]$Binding
    )
    $evidence=Read-E4BindingJson $EvidencePath
    if([string]$evidence.schema -ne $script:E4EvidenceSchema){Stop-E4Binding 'ARTIFACT_INVALID' 'E4 evidence schema mismatch during E3 projection.'}
    Assert-Hex64 ([string]$Binding.e3_acceptance_sha256) 'ProjectedE3AcceptanceSha256'
    Assert-Hex40 ([string]$Binding.execution_adapter_commit) 'ProjectedE3ExecutionAdapterCommit'
    Assert-Hex64 ([string]$Binding.test_apk_sha256) 'ProjectedE3TestApkSha256'
    $projection=[ordered]@{
        schema=$script:E3AcceptanceSchema
        sha256=[string]$Binding.e3_acceptance_sha256
        execution_adapter_commit=[string]$Binding.execution_adapter_commit
        execution_run_id=[string]$Binding.execution_run_id
        test_apk_sha256=[string]$Binding.test_apk_sha256
    }
    if($evidence.PSObject.Properties['e3_acceptance']){$evidence.e3_acceptance=$projection}else{$evidence|Add-Member -NotePropertyName e3_acceptance -NotePropertyValue $projection}
    [void](Write-E4BindingJson $evidence $EvidencePath)
    return [pscustomobject]@{result=[string]$evidence.result;e4_pass=[bool]$evidence.e4_pass;e3_acceptance_sha256=[string]$Binding.e3_acceptance_sha256;evidence=[IO.Path]::GetFullPath($EvidencePath)}
}

Export-ModuleMember -Function Add-E4E3Binding,Assert-E4E3Binding,Add-E4E3EvidenceProjection
