[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest

$labctl=Join-Path $PSScriptRoot 'labctl.ps1'
$pwsh=(Get-Process -Id $PID).Path
$temp=Join-Path ([IO.Path]::GetTempPath()) ('mish-e3-acceptance-test-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp)|Out-Null

function Assert-True{param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)if(-not $Condition){throw $Message}}
function Invoke-Child{
    param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][int]$ExpectedExitCode)
    $output=& $pwsh -NoLogo -NoProfile -NonInteractive -File $labctl @Arguments 2>&1
    if($LASTEXITCODE -ne $ExpectedExitCode){throw "labctl exit code $LASTEXITCODE did not match expected $ExpectedExitCode. Output: $($output -join ' ')"}
    return @($output)
}
function Write-JsonFile{param($Value,[string]$Path)[IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))}

$names=@('GITHUB_REPOSITORY','GITHUB_REF','GITHUB_REF_PROTECTED','GITHUB_SHA','GITHUB_RUN_ID','RUNNER_OS','RUNNER_ARCH')
$saved=@{}; foreach($name in $names){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try{
    $tag='v0.1.0-rc.999'; $source='0123456789abcdef0123456789abcdef01234567'; $abi='armeabi-v7a'
    $cert='abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'
    $apk=Join-Path $temp 'candidate.apk'; [IO.File]::WriteAllBytes($apk,[Text.Encoding]::UTF8.GetBytes('e3-accepted-product'))
    $apkSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $apk).Hash.ToLowerInvariant()
    $testApk=Join-Path $temp 'candidate-test.apk'; [IO.File]::WriteAllBytes($testApk,[Text.Encoding]::UTF8.GetBytes('e3-accepted-test'))
    $testSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $testApk).Hash.ToLowerInvariant()

    $releasePath=Join-Path $temp 'release.json'
    $release=[ordered]@{schema='mish.lab.release-verification/v1';result='PASS';repository='iamaman11/mobile-proxy-mish';tag=$tag;source_commit=$source;abi=$abi;apk=[ordered]@{name='candidate.apk';path=[IO.Path]::GetFullPath($apk);sha256=$apkSha;signing_certificate_sha256=$cert}}
    Write-JsonFile $release $releasePath

    $harnessPath=Join-Path $temp 'harness.json'
    $harness=[ordered]@{schema='mish.lab.e3-harness-verification/v1';result='PASS';repository='iamaman11/mobile-proxy-mish';rc_tag=$tag;source_commit=$source;product_abi=$abi;signing_certificate_sha256=$cert;run=[ordered]@{id=123;workflow='Android Release Candidate';event='workflow_dispatch';actor='github-actions[bot]'};artifact=[ordered]@{id=456;name="e3-harness-$tag";zip_sha256=('1'*64)};product_apk=[ordered]@{name='candidate.apk';sha256=$apkSha;path=[IO.Path]::GetFullPath($apk)};test_apk=[ordered]@{name='candidate-test.apk';sha256=$testSha;path=[IO.Path]::GetFullPath($testApk)};instrumentation=[ordered]@{class='com.mobileproxymish.app.cellular.CellularE3InstrumentedTest';component='com.mobileproxymish.app.test/androidx.test.runner.AndroidJUnitRunner'}}
    Write-JsonFile $harness $harnessPath

    $executionPath=Join-Path $temp 'execution.json'
    $execution=[ordered]@{result='PASS';scenario='full-root-toggle';e3_pass=$true;rc_tag=$tag;source_commit=$source;product_abi=$abi;test_apk_sha256=$testSha}
    Write-JsonFile $execution $executionPath

    $env:GITHUB_REPOSITORY='iamaman11/mobile-proxy-mish'; $env:GITHUB_REF='refs/heads/main'; $env:GITHUB_REF_PROTECTED='true'
    $env:GITHUB_SHA='89abcdef0123456789abcdef0123456789abcdef'; $env:GITHUB_RUN_ID='987654'; $env:RUNNER_OS='Windows'; $env:RUNNER_ARCH='X64'

    $evidencePath=Join-Path $temp 'e3-acceptance.json'
    Invoke-Child @('e3','accept','-VerificationReceipt',$releasePath,'-HarnessVerificationReceipt',$harnessPath,'-InputPath',$executionPath,'-EvidencePath',$evidencePath) 0|Out-Null
    $evidenceText=Get-Content -Raw -LiteralPath $evidencePath; $evidence=$evidenceText|ConvertFrom-Json
    Assert-True ($evidence.schema -eq 'mish.lab.e3-acceptance/v1') 'E3 acceptance schema mismatch.'
    Assert-True ($evidence.result -eq 'PASS' -and $evidence.e3_pass -eq $true -and $evidence.scenario -eq 'full-root-toggle') 'E3 acceptance did not preserve physical PASS.'
    Assert-True ($evidence.release.tag -eq $tag -and $evidence.release.source_commit -eq $source -and $evidence.release.apk_sha256 -eq $apkSha -and $evidence.release.signing_certificate_sha256 -eq $cert) 'E3 acceptance release identity mismatch.'
    Assert-True ($evidence.harness.test_apk_sha256 -eq $testSha -and [long]$evidence.harness.run_id -eq 123 -and [long]$evidence.harness.artifact_id -eq 456) 'E3 acceptance harness identity mismatch.'
    Assert-True (-not $evidenceText.Contains($temp)) 'E3 durable acceptance must not persist local paths.'

    $wrong=(Get-Content -Raw -LiteralPath $executionPath|ConvertFrom-Json); $wrong.source_commit='f'*40
    $wrongPath=Join-Path $temp 'wrong-execution.json'; Write-JsonFile $wrong $wrongPath
    Invoke-Child @('e3','accept','-VerificationReceipt',$releasePath,'-HarnessVerificationReceipt',$harnessPath,'-InputPath',$wrongPath,'-EvidencePath',(Join-Path $temp 'must-not-accept-wrong.json')) 2|Out-Null

    [IO.File]::AppendAllText($apk,'tampered')
    Invoke-Child @('e3','accept','-VerificationReceipt',$releasePath,'-HarnessVerificationReceipt',$harnessPath,'-InputPath',$executionPath,'-EvidencePath',(Join-Path $temp 'must-not-accept-tampered.json')) 2|Out-Null
    [IO.File]::WriteAllBytes($apk,[Text.Encoding]::UTF8.GetBytes('e3-accepted-product'))

    $env:GITHUB_REF='refs/heads/not-main'
    Invoke-Child @('e3','accept','-VerificationReceipt',$releasePath,'-HarnessVerificationReceipt',$harnessPath,'-InputPath',$executionPath,'-EvidencePath',(Join-Path $temp 'must-not-accept-untrusted.json')) 2|Out-Null
    $env:GITHUB_REF='refs/heads/main'

    Write-Host 'E3_ACCEPTANCE_DETERMINISTIC_TESTS=PASS'
}finally{
    foreach($name in $names){[Environment]::SetEnvironmentVariable($name,$saved[$name])}
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
$global:LASTEXITCODE=0
exit 0
