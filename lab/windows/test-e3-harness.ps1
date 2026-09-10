[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$labctl = Join-Path $PSScriptRoot 'labctl.ps1'
$pwsh = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('mish-e3-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if(-not $Condition){ throw $Message }
}

function Invoke-LabctlChild {
    param([Parameter(Mandatory)][string[]]$Arguments,[Parameter(Mandatory)][int]$ExpectedExitCode)
    $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $labctl @Arguments 2>&1
    $actual = $LASTEXITCODE
    if($actual -ne $ExpectedExitCode){ throw "labctl exit code $actual did not match expected $ExpectedExitCode. Output: $($output -join ' ')" }
    return @($output)
}

$originalEnv = @{}
foreach($name in @('GITHUB_REPOSITORY','GITHUB_REF','GITHUB_REF_PROTECTED','GITHUB_SHA','GITHUB_RUN_ID','RUNNER_OS','RUNNER_ARCH')){
    $originalEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    $tag='v0.1.0-rc.3'
    $source='d057f267ffac5cbeca40839778783d462a51b7a0'
    $cert='1958d474069ce0f8b8e5390c9c4ebecd6e306fb4e0f0f6e12d35c9b91cc67803'
    $runId=34498778808L
    $artifactId=10161372180L
    $zipSha='1c1758a5ce3672db76952627e4b1a61ac4e2e73744957f8c8b1f80b5efc01d36'

    $productName="mobile-proxy-mish-$tag.apk"
    $productPath=Join-Path $temp $productName
    [IO.File]::WriteAllBytes($productPath,[Text.Encoding]::UTF8.GetBytes('deterministic-product-fixture'))
    $productSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $productPath).Hash.ToLowerInvariant()
    $releaseReceipt=Join-Path $temp 'release-verification.json'
    [IO.File]::WriteAllText($releaseReceipt,([ordered]@{
        schema='mish.lab.release-verification/v1'; result='PASS'; repository='iamaman11/mobile-proxy-mish'; tag=$tag; source_commit=$source
        apk=[ordered]@{ name=$productName; sha256=$productSha; signing_certificate_sha256=$cert; path=$productPath }
    } | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

    $harnessDir=Join-Path $temp 'harness'; [IO.Directory]::CreateDirectory($harnessDir)|Out-Null
    $testName="mobile-proxy-mish-$tag-e3-androidTest.apk"
    $testPath=Join-Path $harnessDir $testName
    [IO.File]::WriteAllBytes($testPath,[Text.Encoding]::UTF8.GetBytes('deterministic-test-fixture'))
    $testSha=(Get-FileHash -Algorithm SHA256 -LiteralPath $testPath).Hash.ToLowerInvariant()
    $manifestPath=Join-Path $harnessDir "mobile-proxy-mish-$tag-e3-harness.json"
    [IO.File]::WriteAllText($manifestPath,([ordered]@{
        schema='mish.lab.e3-harness/v1'; repository='iamaman11/mobile-proxy-mish'; rc_tag=$tag; source_commit=$source; signing_certificate_sha256=$cert
        product_apk=[ordered]@{ name=$productName; sha256=$productSha }
        test_apk=[ordered]@{ name=$testName; sha256=$testSha }
        instrumentation=[ordered]@{ class='com.mobileproxymish.app.cellular.CellularE3InstrumentedTest'; component='com.mobileproxymish.app.test/androidx.test.runner.AndroidJUnitRunner' }
    } | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))

    $runMetadata=Join-Path $temp 'run.json'
    [IO.File]::WriteAllText($runMetadata,([ordered]@{
        id=$runId; name='Android Release Candidate'; path='.github/workflows/android-release.yml'; event='workflow_dispatch'; status='completed'; conclusion='success'; head_branch=$tag; head_sha=$source; actor=[ordered]@{login='github-actions[bot]'}
    } | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    $artifactMetadata=Join-Path $temp 'artifact.json'
    [IO.File]::WriteAllText($artifactMetadata,([ordered]@{
        id=$artifactId; name="e3-harness-$tag"; expired=$false; digest="sha256:$zipSha"; workflow_run=[ordered]@{id=$runId;head_branch=$tag;head_sha=$source}
    } | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))

    $harnessReceipt=Join-Path $temp 'harness-verification.json'
    Invoke-LabctlChild @('e3','verify','-VerificationReceipt',$releaseReceipt,'-HarnessRunId',[string]$runId,'-HarnessArtifactId',[string]$artifactId,'-ExpectedHarnessZipSha256',$zipSha,'-ExpectedTestApkSha256',$testSha,'-HarnessDirectory',$harnessDir,'-RunMetadataPath',$runMetadata,'-ArtifactMetadataPath',$artifactMetadata,'-ReceiptPath',$harnessReceipt) 0 | Out-Null
    $verified=Get-Content -Raw -LiteralPath $harnessReceipt | ConvertFrom-Json
    Assert-True ($verified.schema -eq 'mish.lab.e3-harness-verification/v1') 'Harness verification schema mismatch.'
    Assert-True ($verified.result -eq 'PASS') 'Harness verification did not PASS.'
    Assert-True ($verified.test_apk.sha256 -eq $testSha) 'Harness test digest mismatch.'
    Assert-True ([long]$verified.run.id -eq $runId) 'Harness run identity mismatch.'

    Remove-Item -LiteralPath $harnessReceipt -Force
    $wrongTestSha='0' * 64
    Invoke-LabctlChild @('e3','verify','-VerificationReceipt',$releaseReceipt,'-HarnessRunId',[string]$runId,'-HarnessArtifactId',[string]$artifactId,'-ExpectedHarnessZipSha256',$zipSha,'-ExpectedTestApkSha256',$wrongTestSha,'-HarnessDirectory',$harnessDir,'-RunMetadataPath',$runMetadata,'-ArtifactMetadataPath',$artifactMetadata,'-ReceiptPath',$harnessReceipt) 2 | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $harnessReceipt)) 'Mismatched accepted test digest must not emit PASS receipt.'

    [IO.File]::AppendAllText($testPath,'tamper')
    Invoke-LabctlChild @('e3','verify','-VerificationReceipt',$releaseReceipt,'-HarnessRunId',[string]$runId,'-HarnessArtifactId',[string]$artifactId,'-ExpectedHarnessZipSha256',$zipSha,'-ExpectedTestApkSha256',$testSha,'-HarnessDirectory',$harnessDir,'-RunMetadataPath',$runMetadata,'-ArtifactMetadataPath',$artifactMetadata,'-ReceiptPath',$harnessReceipt) 2 | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $harnessReceipt)) 'Tampered harness must not emit PASS receipt.'
    [IO.File]::WriteAllBytes($testPath,[Text.Encoding]::UTF8.GetBytes('deterministic-test-fixture'))

    Invoke-LabctlChild @('e3','verify','-VerificationReceipt',$releaseReceipt,'-HarnessRunId',[string]$runId,'-HarnessArtifactId',[string]$artifactId,'-ExpectedHarnessZipSha256',$zipSha,'-ExpectedTestApkSha256',$testSha,'-HarnessDirectory',$harnessDir,'-RunMetadataPath',$runMetadata,'-ArtifactMetadataPath',$artifactMetadata,'-ReceiptPath',$harnessReceipt) 0 | Out-Null

    [Environment]::SetEnvironmentVariable('GITHUB_REPOSITORY','iamaman11/mobile-proxy-mish')
    [Environment]::SetEnvironmentVariable('GITHUB_REF','refs/heads/main')
    [Environment]::SetEnvironmentVariable('GITHUB_REF_PROTECTED','true')
    [Environment]::SetEnvironmentVariable('GITHUB_SHA','a' * 40)
    [Environment]::SetEnvironmentVariable('GITHUB_RUN_ID','12345')
    [Environment]::SetEnvironmentVariable('RUNNER_OS','Windows')
    [Environment]::SetEnvironmentVariable('RUNNER_ARCH','X64')
    $androidObservation=Join-Path $temp 'android.json'
    [IO.File]::WriteAllText($androidObservation,(@{result='PASS';device_count=0;states=@()}|ConvertTo-Json -Depth 3),[Text.UTF8Encoding]::new($false))
    $readiness=Join-Path $temp 'readiness.json'
    Invoke-LabctlChild @('e3','ready','-VerificationReceipt',$releaseReceipt,'-HarnessVerificationReceipt',$harnessReceipt,'-AndroidObservationPath',$androidObservation,'-EvidencePath',$readiness) 0 | Out-Null
    $ready=Get-Content -Raw -LiteralPath $readiness | ConvertFrom-Json
    Assert-True ($ready.schema -eq 'mish.lab.e3-readiness/v1') 'E3 readiness schema mismatch.'
    Assert-True ($ready.boundary -eq 'PHONE-ON READY') 'PHONE-ON boundary mismatch.'
    Assert-True ($ready.phone_on_ready -eq $true -and $ready.e3_pass -eq $false) 'Readiness receipt escalated to E3.'
    Assert-True ($ready.android.device_count -eq 0) 'Readiness receipt must prove zero devices.'

    $evidence=Join-Path $temp 'evidence.json'
    Invoke-LabctlChild @('evidence','collect','-InputPath',$readiness,'-EvidencePath',$evidence) 0 | Out-Null
    $durable=Get-Content -Raw -LiteralPath $evidence | ConvertFrom-Json
    Assert-True ($durable.schema -eq 'mish.lab.evidence/v1') 'Durable E3 readiness evidence must use the accepted LAB evidence schema.'
    Assert-True ($durable.run_kind -eq 'e3-pre-device-dry' -and $durable.result -eq 'PASS' -and $null -eq $durable.failure) 'Durable E3 readiness evidence envelope mismatch.'
    Assert-True ($durable.git_ref -eq 'refs/heads/main' -and $durable.git_commit -eq ('a' * 40) -and $durable.run_id -eq '12345') 'Durable evidence git/run identity mismatch.'
    Assert-True ($durable.observations.release.tag -eq $tag -and $durable.observations.release.source_commit -eq $source -and $durable.observations.release.apk_sha256 -eq $productSha -and $durable.observations.release.signing_certificate_sha256 -eq $cert) 'Durable release projection mismatch.'
    Assert-True ([long]$durable.observations.harness.run_id -eq $runId -and [long]$durable.observations.harness.artifact_id -eq $artifactId -and $durable.observations.harness.artifact_name -eq "e3-harness-$tag") 'Durable harness run/artifact projection mismatch.'
    Assert-True ($durable.observations.harness.source_commit -eq $source -and $durable.observations.harness.artifact_zip_sha256 -eq $zipSha -and $durable.observations.harness.test_apk_sha256 -eq $testSha -and $durable.observations.harness.signing_certificate_sha256 -eq $cert) 'Durable harness digest/signing projection mismatch.'
    Assert-True ($durable.observations.harness.instrumentation_class -eq 'com.mobileproxymish.app.cellular.CellularE3InstrumentedTest' -and $durable.observations.harness.instrumentation_component -eq 'com.mobileproxymish.app.test/androidx.test.runner.AndroidJUnitRunner') 'Durable instrumentation identity mismatch.'
    Assert-True ($durable.observations.android.device_count -eq 0 -and $durable.observations.android.device_absent -eq $true) 'Durable evidence must preserve the zero-device boundary.'
    Assert-True ($durable.observations.boundary.name -eq 'PHONE-ON READY' -and $durable.observations.boundary.phone_on_ready -eq $true -and $durable.observations.boundary.e3_pass -eq $false -and $durable.observations.boundary.no_evidence_escalation -eq 'PASS') 'Durable evidence escalated beyond PHONE-ON readiness.'
    $durableJson=Get-Content -Raw -LiteralPath $evidence
    Assert-True (-not $durableJson.Contains($temp)) 'Durable evidence must not persist local working paths.'
    foreach($privateField in @('imei','imsi','iccid','phone_number','public_ip','device_serial')){
        Assert-True ($durableJson -notmatch ('(?i)"' + [regex]::Escape($privateField) + '"')) "Durable evidence leaked forbidden field $privateField."
    }

    $tamperedReadiness=Join-Path $temp 'tampered-readiness.json'
    $ready.e3_pass=$true
    [IO.File]::WriteAllText($tamperedReadiness,($ready|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
    Remove-Item -LiteralPath $evidence -Force
    Invoke-LabctlChild @('evidence','collect','-InputPath',$tamperedReadiness,'-EvidencePath',$evidence) 2 | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $evidence)) 'Escalating readiness receipt must not emit durable PASS evidence.'

    $workflowPath=Join-Path (Split-Path $PSScriptRoot -Parent | Split-Path -Parent) '.github/workflows/e3-physical-cellular.yml'
    $workflow=Get-Content -Raw -LiteralPath $workflowPath
    Assert-True ($workflow -match '(?m)^\s{8}shell:\s*pwsh\s*$') 'Hosted Windows contract should retain its legitimate pwsh shell.'
    $physicalMatch=[regex]::Match($workflow,'(?ms)^  physical-cellular:\s*\r?\n(?<body>.*)\z')
    Assert-True $physicalMatch.Success 'Physical-cellular job block could not be isolated for trust-boundary checking.'
    $physicalJob=$physicalMatch.Value

    foreach($forbidden in @(
        '(?i)\bgradle\b',
        '(?i)\bcargo\b',
        '(?i)\brustup\b',
        '(?i)\brustc\b',
        '(?i)\bsdkmanager\b',
        '(?i)\bndk-build\b',
        '(?m)^\s*shell:\s*(pwsh|powershell)\s*$',
        '(?i)\s-Command\s',
        '(?i)MISH_ANDROID_RELEASE_(KEYSTORE|STORE_PASSWORD|KEY_ALIAS|KEY_PASSWORD)',
        '(?i)CLOUDFLARE_API_TOKEN|R2_ACCESS_KEY|R2_SECRET|terraform\s+apply',
        '(?i)\blatest\b'
    )){
        if($physicalJob -match $forbidden){ throw "E3 physical job violates build/secret/trust boundary: $forbidden" }
    }

    foreach($required in @(
        'runs-on: [self-hosted, windows, x64, mobile-proxy-mish-lab]',
        "github.event_name == 'workflow_dispatch'",
        "github.ref == 'refs/heads/main'",
        'github.ref_protected == true',
        'LAB_POWERSHELL_EXE: C:\mish-lab\tools\powershell-7.6.6\pwsh.exe',
        'shell: cmd',
        'RC_TAG: v0.1.0-rc.3',
        'RC_SOURCE: d057f267ffac5cbeca40839778783d462a51b7a0',
        'RC_APK_SHA256: 84d8a53857a20a5d55093604324770d00fdbd8a187a69c524e88920d00b323f0',
        'RC_SIGNING_CERT_SHA256: 1958d474069ce0f8b8e5390c9c4ebecd6e306fb4e0f0f6e12d35c9b91cc67803',
        'HARNESS_RUN_ID: 34498778808',
        'HARNESS_ARTIFACT_ID: 10161372180',
        'HARNESS_ZIP_SHA256: 1c1758a5ce3672db76952627e4b1a61ac4e2e73744957f8c8b1f80b5efc01d36',
        'HARNESS_TEST_APK_SHA256: 2d377cfce3f0827d6bc4efda313d6ebaeb6dac148303bb1eaff9a0b60c860c9c',
        'actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093',
        'artifact-ids: ${{ env.HARNESS_ARTIFACT_ID }}',
        '-ExpectedTestApkSha256 "%HARNESS_TEST_APK_SHA256%"',
        '-HarnessDirectory "%RUNNER_TEMP%\mish-e3\harness\%HARNESS_ARTIFACT_NAME%"',
        'labctl.ps1" release resolve',
        'labctl.ps1" release verify',
        'labctl.ps1" e3 verify',
        'labctl.ps1" android inspect',
        '-RequireNoDevice',
        'labctl.ps1" e3 ready',
        'labctl.ps1" evidence collect',
        'mish-e3\evidence.json',
        'mish.lab.evidence/v1',
        'PHONE-ON READY',
        'E3_PASS=NO',
        'NO_EVIDENCE_ESCALATION=PASS'
    )){ if(-not $physicalJob.Contains($required)){ throw "E3 physical job missing required trust text: $required" } }

    Write-Host 'E3_HARNESS_DETERMINISTIC_TESTS=PASS'
}
finally {
    foreach($name in $originalEnv.Keys){ [Environment]::SetEnvironmentVariable($name,$originalEnv[$name]) }
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
$global:LASTEXITCODE=0
exit 0