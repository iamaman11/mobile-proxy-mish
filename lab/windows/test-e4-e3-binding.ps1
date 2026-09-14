[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'E4E3Binding.psm1') -Force

$temp=Join-Path ([IO.Path]::GetTempPath()) ('mish-e4-e3-binding-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null
function Assert-True{param([bool]$Condition,[string]$Message)if(-not $Condition){throw $Message}}
function Write-JsonFile{param($Value,[string]$Path)[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}
try{
    $source='0123456789abcdef0123456789abcdef01234567'; $cert='abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'; $apkSha='1'*64; $testSha='2'*64
    $sessionPath=Join-Path $temp 'session.json'
    $session=[ordered]@{schema='mish.lab.e4-session/v1';result='READY';e4_pass=$false;release=[ordered]@{tag='v0.1.0-rc.999';source_commit=$source;abi='armeabi-v7a';apk_sha256=$apkSha;signing_certificate_sha256=$cert}}
    Write-JsonFile $session $sessionPath
    $e3Path=Join-Path $temp 'e3.json'
    $e3=[ordered]@{schema='mish.lab.e3-acceptance/v1';result='PASS';e3_pass=$true;repository='iamaman11/mobile-proxy-mish';scenario='full-root-toggle';execution_adapter=[ordered]@{git_ref='refs/heads/main';git_commit='89abcdef0123456789abcdef0123456789abcdef';run_id='777'};release=[ordered]@{tag='v0.1.0-rc.999';source_commit=$source;abi='armeabi-v7a';apk_sha256=$apkSha;signing_certificate_sha256=$cert};harness=[ordered]@{test_apk_sha256=$testSha;signing_certificate_sha256=$cert}}
    Write-JsonFile $e3 $e3Path

    $created=Add-E4E3Binding -SessionReceipt $sessionPath -E3AcceptancePath $e3Path
    $binding=Assert-E4E3Binding -SessionReceipt $sessionPath
    Assert-True ($binding.e3_acceptance_sha256 -eq $created.e3_acceptance_sha256) 'E3 binding digest changed unexpectedly.'

    $evidencePath=Join-Path $temp 'e4-evidence.json'
    Write-JsonFile ([ordered]@{schema='mish.lab.e4-evidence/v1';result='PASS';e4_pass=$true;release=[ordered]@{tag='v0.1.0-rc.999'}}) $evidencePath
    [void](Add-E4E3EvidenceProjection -EvidencePath $evidencePath -Binding $binding)
    $text=Get-Content -Raw -LiteralPath $evidencePath; $evidence=$text|ConvertFrom-Json
    Assert-True ($evidence.e3_acceptance.schema -eq 'mish.lab.e3-acceptance/v1') 'E4 durable evidence lost E3 acceptance schema.'
    Assert-True ($evidence.e3_acceptance.sha256 -eq $binding.e3_acceptance_sha256) 'E4 durable evidence lost E3 acceptance digest.'
    Assert-True ($evidence.e3_acceptance.execution_adapter_commit -eq $binding.execution_adapter_commit -and $evidence.e3_acceptance.execution_run_id -eq '777') 'E4 durable evidence lost bounded E3 execution identity.'
    Assert-True ($evidence.e3_acceptance.test_apk_sha256 -eq $testSha) 'E4 durable evidence lost exact E3 test APK digest.'
    Assert-True (-not $text.Contains($temp)) 'E4 durable evidence must not persist E3 receipt local path.'

    $wrong=($e3|ConvertTo-Json -Depth 12|ConvertFrom-Json); $wrong.harness.signing_certificate_sha256='3'*64
    $wrongPath=Join-Path $temp 'wrong-cert.json'; Write-JsonFile $wrong $wrongPath
    $freshSession=Join-Path $temp 'fresh-session.json'; Write-JsonFile $session $freshSession
    $failed=$false
    try{[void](Add-E4E3Binding -SessionReceipt $freshSession -E3AcceptancePath $wrongPath)}catch{$failed=$true}
    Assert-True $failed 'E4 must reject E3 acceptance whose harness signing identity differs from PRODUCT.'

    Write-Host 'E4_E3_BINDING_DETERMINISTIC_TESTS=PASS'
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
$global:LASTEXITCODE=0
exit 0
