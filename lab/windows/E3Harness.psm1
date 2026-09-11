Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Repository = 'iamaman11/mobile-proxy-mish'
$script:ReleaseVerificationSchema = 'mish.lab.release-verification/v1'
$script:HarnessSchema = 'mish.lab.e3-harness/v1'
$script:HarnessVerificationSchema = 'mish.lab.e3-harness-verification/v1'
$script:ReadinessSchema = 'mish.lab.e3-readiness/v1'
$script:TestClass = 'com.mobileproxymish.app.cellular.CellularE3InstrumentedTest'
$script:TestComponent = 'com.mobileproxymish.app.test/androidx.test.runner.AndroidJUnitRunner'
$script:Hex40Pattern = '^[0-9a-f]{40}$'
$script:Hex64Pattern = '^[0-9a-f]{64}$'
$script:SupportedAndroidAbis = @('armeabi-v7a', 'arm64-v8a')

function Stop-E3 {
    param([Parameter(Mandatory)][string]$Category, [Parameter(Mandatory)][string]$Message)
    throw "MISH_LABCTL_FAILURE|$Category|$Message"
}

function Read-E3Json {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Stop-E3 'ARTIFACT_MISSING' "Required E3 JSON is missing: $full"
    }
    try { return Get-Content -Raw -LiteralPath $full | ConvertFrom-Json }
    catch { Stop-E3 'ARTIFACT_INVALID' "Required E3 JSON is invalid: $full" }
}

function Write-E3Json {
    param([Parameter(Mandatory)]$Value,[Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($full, (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    return $full
}

function Get-E3Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-E3 'ARTIFACT_MISSING' 'Required E3 artifact is missing.' }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-E3Hex40 { param([string]$Value,[string]$Name) if ($Value -notmatch $script:Hex40Pattern) { Stop-E3 'IDENTITY_MISMATCH' "$Name must be lowercase 40-hex." } }
function Assert-E3Hex64 { param([string]$Value,[string]$Name) if ($Value -notmatch $script:Hex64Pattern) { Stop-E3 'IDENTITY_MISMATCH' "$Name must be lowercase 64-hex." } }

function Assert-PhysicalMain {
    if ($env:GITHUB_REPOSITORY -ne $script:Repository -or $env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_REF_PROTECTED -ne 'true') {
        Stop-E3 'UNTRUSTED_REF' 'E3 physical execution requires protected main.'
    }
    if ($env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64') {
        Stop-E3 'IDENTITY_MISMATCH' 'E3 physical execution requires the accepted Windows x64 LAB.'
    }
}

function Assert-ReleaseReceipt {
    param([Parameter(Mandatory)]$Receipt)
    if ([string]$Receipt.schema -ne $script:ReleaseVerificationSchema -or [string]$Receipt.result -ne 'PASS' -or [string]$Receipt.repository -ne $script:Repository) {
        Stop-E3 'VERIFICATION_REQUIRED' 'A PASS exact release verification receipt is required.'
    }
    $tag = [string]$Receipt.tag
    $source = [string]$Receipt.source_commit
    $abi = [string]$Receipt.abi
    $productSha = [string]$Receipt.apk.sha256
    $cert = [string]$Receipt.apk.signing_certificate_sha256
    Assert-E3Hex40 $source 'ReleaseSource'
    if (-not ($script:SupportedAndroidAbis -contains $abi)) { Stop-E3 'IDENTITY_MISMATCH' 'Verified release Android ABI is unsupported.' }
    Assert-E3Hex64 $productSha 'ProductSha256'
    Assert-E3Hex64 $cert 'SigningCertificateSha256'
    if ((Get-E3Sha256 ([string]$Receipt.apk.path)) -ne $productSha) {
        Stop-E3 'DIGEST_MISMATCH' 'Verified product APK bytes changed after release verification.'
    }
    return [pscustomobject]@{ tag=$tag; source=$source; abi=$abi; product_sha256=$productSha; cert=$cert; product_path=[IO.Path]::GetFullPath([string]$Receipt.apk.path); product_name=[string]$Receipt.apk.name }
}

function Invoke-E3GitHubJson {
    param([Parameter(Mandatory)][string]$Uri)
    $headers = @{ 'Accept'='application/vnd.github+json'; 'User-Agent'='mobile-proxy-mish-labctl'; 'X-GitHub-Api-Version'='2022-11-28' }
    try { return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -MaximumRedirection 5 }
    catch { Stop-E3 'EVIDENCE_UNAVAILABLE' 'Required GitHub E3 evidence metadata could not be read.' }
}

function Get-E3Metadata {
    param([string]$Path, [string]$Uri)
    if ($Path) { return Read-E3Json $Path }
    return Invoke-E3GitHubJson $Uri
}

function Invoke-E3HarnessVerify {
    param(
        [Parameter(Mandatory)][string]$ReleaseVerificationReceipt,
        [Parameter(Mandatory)][long]$HarnessRunId,
        [Parameter(Mandatory)][long]$HarnessArtifactId,
        [Parameter(Mandatory)][string]$ExpectedHarnessZipSha256,
        [Parameter(Mandatory)][string]$ExpectedTestApkSha256,
        [Parameter(Mandatory)][string]$HarnessDirectory,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [string]$RunMetadataPath,
        [string]$ArtifactMetadataPath
    )
    if ($HarnessRunId -le 0 -or $HarnessArtifactId -le 0) { Stop-E3 'INPUT_INVALID' 'Harness run/artifact IDs must be positive.' }
    Assert-E3Hex64 $ExpectedHarnessZipSha256 'HarnessZipSha256'
    Assert-E3Hex64 $ExpectedTestApkSha256 'ExpectedTestApkSha256'
    $release = Read-E3Json $ReleaseVerificationReceipt
    $r = Assert-ReleaseReceipt $release

    $run = Get-E3Metadata $RunMetadataPath "https://api.github.com/repos/$script:Repository/actions/runs/$HarnessRunId"
    if ([long]$run.id -ne $HarnessRunId -or [string]$run.name -ne 'Android Release Candidate' -or
        [string]$run.path -ne '.github/workflows/android-release.yml' -or [string]$run.event -ne 'workflow_dispatch' -or
        [string]$run.status -ne 'completed' -or [string]$run.conclusion -ne 'success' -or
        [string]$run.head_branch -ne $r.tag -or [string]$run.head_sha -ne $r.source -or [string]$run.actor.login -ne 'github-actions[bot]') {
        Stop-E3 'IDENTITY_MISMATCH' 'Harness workflow run metadata does not match the exact accepted RC identity.'
    }

    $artifact = Get-E3Metadata $ArtifactMetadataPath "https://api.github.com/repos/$script:Repository/actions/artifacts/$HarnessArtifactId"
    $artifactName = "e3-harness-$($r.tag)"
    if ([long]$artifact.id -ne $HarnessArtifactId -or [string]$artifact.name -ne $artifactName -or $artifact.expired -ne $false -or
        [string]$artifact.digest -ne "sha256:$ExpectedHarnessZipSha256" -or [long]$artifact.workflow_run.id -ne $HarnessRunId -or
        [string]$artifact.workflow_run.head_branch -ne $r.tag -or [string]$artifact.workflow_run.head_sha -ne $r.source) {
        Stop-E3 'IDENTITY_MISMATCH' 'Harness artifact metadata does not match the exact accepted artifact identity.'
    }

    $root = [IO.Path]::GetFullPath($HarnessDirectory)
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { Stop-E3 'ARTIFACT_MISSING' 'Harness directory is missing.' }
    $manifestName = "mobile-proxy-mish-$($r.tag)-e3-harness.json"
    $testName = "mobile-proxy-mish-$($r.tag)-e3-androidTest.apk"
    $manifestPath = Join-Path $root $manifestName
    $testPath = Join-Path $root $testName
    $files = @(Get-ChildItem -LiteralPath $root -File -Recurse)
    if ($files.Count -ne 2 -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or -not (Test-Path -LiteralPath $testPath -PathType Leaf)) {
        Stop-E3 'ARTIFACT_INVALID' 'E3 harness must contain exactly the expected test APK and manifest.'
    }

    $manifest = Read-E3Json $manifestPath
    if ([string]$manifest.schema -ne $script:HarnessSchema -or [string]$manifest.repository -ne $script:Repository -or
        [string]$manifest.rc_tag -ne $r.tag -or [string]$manifest.source_commit -ne $r.source -or
        [string]$manifest.signing_certificate_sha256 -ne $r.cert -or [string]$manifest.product_apk.name -ne $r.product_name -or
        [string]$manifest.product_apk.sha256 -ne $r.product_sha256 -or [string]$manifest.test_apk.name -ne $testName -or
        [string]$manifest.instrumentation.class -ne $script:TestClass -or [string]$manifest.instrumentation.component -ne $script:TestComponent) {
        Stop-E3 'IDENTITY_MISMATCH' 'E3 harness manifest identity does not match the verified product RC.'
    }
    $testSha = [string]$manifest.test_apk.sha256
    Assert-E3Hex64 $testSha 'TestApkSha256'
    if ($testSha -ne $ExpectedTestApkSha256 -or (Get-E3Sha256 $testPath) -ne $ExpectedTestApkSha256) {
        Stop-E3 'DIGEST_MISMATCH' 'E3 test APK digest does not match the exact accepted test digest.'
    }

    $receipt = [ordered]@{
        schema=$script:HarnessVerificationSchema; result='PASS'; repository=$script:Repository
        rc_tag=$r.tag; source_commit=$r.source; product_abi=$r.abi; signing_certificate_sha256=$r.cert
        run=[ordered]@{ id=$HarnessRunId; workflow='Android Release Candidate'; event='workflow_dispatch'; actor='github-actions[bot]' }
        artifact=[ordered]@{ id=$HarnessArtifactId; name=$artifactName; zip_sha256=$ExpectedHarnessZipSha256 }
        product_apk=[ordered]@{ name=$r.product_name; sha256=$r.product_sha256; path=$r.product_path }
        test_apk=[ordered]@{ name=$testName; sha256=$testSha; path=[IO.Path]::GetFullPath($testPath) }
        instrumentation=[ordered]@{ class=$script:TestClass; component=$script:TestComponent }
        verified_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
    }
    $written = Write-E3Json $receipt $ReceiptPath
    return [pscustomobject]@{ result='PASS'; rc_tag=$r.tag; product_abi=$r.abi; run_id=$HarnessRunId; artifact_id=$HarnessArtifactId; test_apk_sha256=$testSha; receipt=$written }
}

function Invoke-E3Readiness {
    param(
        [Parameter(Mandatory)][string]$ReleaseVerificationReceipt,
        [Parameter(Mandatory)][string]$HarnessVerificationReceipt,
        [Parameter(Mandatory)][string]$AndroidObservationPath,
        [Parameter(Mandatory)][string]$EvidencePath
    )
    Assert-PhysicalMain
    $release = Read-E3Json $ReleaseVerificationReceipt
    $r = Assert-ReleaseReceipt $release
    $h = Read-E3Json $HarnessVerificationReceipt
    if ([string]$h.schema -ne $script:HarnessVerificationSchema -or [string]$h.result -ne 'PASS' -or
        [string]$h.rc_tag -ne $r.tag -or [string]$h.source_commit -ne $r.source -or [string]$h.product_abi -ne $r.abi -or
        [string]$h.signing_certificate_sha256 -ne $r.cert -or [string]$h.product_apk.sha256 -ne $r.product_sha256 -or
        (Get-E3Sha256 ([string]$h.test_apk.path)) -ne [string]$h.test_apk.sha256) {
        Stop-E3 'VERIFICATION_REQUIRED' 'A matching PASS E3 harness verification receipt is required.'
    }
    $android = Read-E3Json $AndroidObservationPath
    if ([string]$android.result -ne 'PASS' -or [int]$android.device_count -ne 0 -or @($android.states).Count -ne 0) {
        Stop-E3 'DEVICE_PRESENT' 'PHONE-ON readiness requires an explicit zero-device Android observation.'
    }
    $evidence = [ordered]@{
        schema=$script:ReadinessSchema; result='PASS'; repository=$script:Repository
        git_ref=[string]$env:GITHUB_REF; git_commit=[string]$env:GITHUB_SHA; run_id=[string]$env:GITHUB_RUN_ID
        boundary='PHONE-ON READY'; phone_on_ready=$true; e3_pass=$false
        release=[ordered]@{ tag=$r.tag; source_commit=$r.source; abi=$r.abi; apk_sha256=$r.product_sha256; signing_certificate_sha256=$r.cert }
        harness=[ordered]@{ run_id=[long]$h.run.id; artifact_id=[long]$h.artifact.id; artifact_name=[string]$h.artifact.name; artifact_zip_sha256=[string]$h.artifact.zip_sha256; test_apk_sha256=[string]$h.test_apk.sha256; signing_certificate_sha256=[string]$h.signing_certificate_sha256; instrumentation_class=[string]$h.instrumentation.class; instrumentation_component=[string]$h.instrumentation.component }
        android=[ordered]@{ device_count=0; device_absent=$true }
        completed_at_utc=[DateTimeOffset]::UtcNow.ToString('o')
    }
    $written = Write-E3Json $evidence $EvidencePath
    return [pscustomobject]@{ result='PASS'; boundary='PHONE-ON READY'; e3_pass=$false; evidence=$written }
}

function Resolve-E3Executable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-E3 'HOST_PREREQUISITE_MISSING' 'Exact ADB executable path is unavailable.'
    }
    return [IO.Path]::GetFullPath($Path)
}

function Invoke-E3Process {
    param([string]$FilePath,[string[]]$Arguments,[int]$TimeoutSeconds)
    $psi=[Diagnostics.ProcessStartInfo]::new(); $psi.FileName=$FilePath; $psi.UseShellExecute=$false; $psi.CreateNoWindow=$true; $psi.RedirectStandardOutput=$true; $psi.RedirectStandardError=$true
    foreach($arg in $Arguments){ [void]$psi.ArgumentList.Add($arg) }
    $p=[Diagnostics.Process]::new(); $p.StartInfo=$psi
    if(-not $p.Start()){ Stop-E3 'PROCESS_FAILED' 'ADB process could not be started.' }
    try {
        $out=$p.StandardOutput.ReadToEndAsync(); $err=$p.StandardError.ReadToEndAsync()
        if(-not $p.WaitForExit($TimeoutSeconds*1000)){ try{$p.Kill($true)}catch{}; Stop-E3 'PROCESS_TIMEOUT' 'ADB operation exceeded bounded timeout.' }
        return [pscustomobject]@{ ExitCode=$p.ExitCode; StdOut=$out.GetAwaiter().GetResult(); StdErr=$err.GetAwaiter().GetResult() }
    } finally { $p.Dispose() }
}

function Resolve-E3BoundProbeSubstage {
    param(
        [Parameter(Mandatory)][string]$StdOut,
        [Parameter(Mandatory)][ValidateSet('positive','recovery')][string]$Phase
    )

    if ($StdOut -match 'Android explicit-network DNS lookup failed') { return "${Phase}_dns_lookup_failed" }
    if ($StdOut -match 'Android explicit-network DNS lookup returned no addresses|network-scoped DNS returned no addresses') { return "${Phase}_dns_empty" }
    if ($StdOut -match 'Android explicit-network DNS address conversion failed|lease must return numeric IP strings') { return "${Phase}_address_conversion_failed" }
    if ($StdOut -match 'Android explicit-network socket binding failed') { return "${Phase}_socket_bind_failed" }
    if ($StdOut -match '(?i)\bconnect failed:') { return "${Phase}_connect_failed" }
    if ($StdOut -match 'E3 echo endpoint must return HTTP 200') { return "${Phase}_http_status_failed" }
    if ($StdOut -match 'socket write made no progress|E3 HTTP response exceeded 64 KiB|(?i)\b(?:read|write) failed:') { return "${Phase}_response_io_failed" }
    if ($StdOut -match 'HTTP response must contain header/body separator') { return "${Phase}_response_parse_failed" }
    if ($StdOut -match 'echo response must be a bare IPv4/IPv6 literal|recovery echo must be a bare IPv4/IPv6 literal') { return "${Phase}_public_ip_parse_failed" }
    if ($StdOut -match 'all lease-resolved addresses failed') { return "${Phase}_bound_probe_unknown" }
    return $null
}

function Resolve-E3InstrumentationFailure {
    param(
        [Parameter(Mandatory)][string]$StdOut,
        [Parameter(Mandatory)][int]$ExitCode
    )

    if ($ExitCode -eq 0 -and $StdOut -match 'OK \(1 test\)') {
        return 'none'
    }

    $positive = $StdOut -match 'E3_EVIDENCE phase=positive '
    $negative = $StdOut -match 'E3_EVIDENCE phase=negative '
    $recovery = $StdOut -match 'E3_EVIDENCE phase=recovery '

    if (-not $positive) {
        if ($StdOut -match 'expected:<ADMITTED> but was:<NOT_ADMITTED>') { return 'positive_admission_timeout' }
        if ($StdOut -match 'expected direct cellular Internet presence=true validated_required=true') { return 'positive_direct_cellular_missing' }
        if ($StdOut -match 'root mobile-data transition failed') { return 'positive_device_control_failed' }
        $probe = Resolve-E3BoundProbeSubstage -StdOut $StdOut -Phase 'positive'
        if ($null -ne $probe) { return $probe }
        return 'positive_unknown'
    }

    if (-not $negative) {
        if ($StdOut -match 'expected direct cellular Internet presence=false') { return 'negative_loss_timeout' }
        if ($StdOut -match 'expected:<NOT_ADMITTED> but was:<ADMITTED>') { return 'negative_owner_timeout' }
        if ($StdOut -match 'no cellular authority lease may be issued|pre-loss cellular lease must be revoked') { return 'negative_lease_revocation_failed' }
        if ($StdOut -match 'root mobile-data transition failed') { return 'negative_device_control_failed' }
        return 'negative_unknown'
    }

    if (-not $recovery) {
        if ($StdOut -match 'expected:<ADMITTED> but was:<NOT_ADMITTED>') { return 'recovery_admission_timeout' }
        if ($StdOut -match 'expected direct cellular Internet presence=true validated_required=true') { return 'recovery_direct_cellular_missing' }
        if ($StdOut -match 'root mobile-data transition failed') { return 'recovery_device_control_failed' }
        $probe = Resolve-E3BoundProbeSubstage -StdOut $StdOut -Phase 'recovery'
        if ($null -ne $probe) { return $probe }
        return 'recovery_unknown'
    }

    return 'instrumentation_unknown'
}

function Invoke-E3FullRootToggle {
    param(
        [Parameter(Mandatory)][string]$ReleaseVerificationReceipt,
        [Parameter(Mandatory)][string]$HarnessVerificationReceipt,
        [Parameter(Mandatory)][string]$AdbPath,
        [Parameter(Mandatory)][string]$E3Host,
        [ValidateRange(1,65535)][int]$E3Port,
        [Parameter(Mandatory)][string]$E3Path,
        [ValidateRange(1,3600)][int]$TimeoutSeconds
    )
    Assert-PhysicalMain
    if ($E3Host -notmatch '^[A-Za-z0-9.-]+$' -or $E3Path -notmatch '^/[A-Za-z0-9._~/%-]*$') { Stop-E3 'INPUT_INVALID' 'E3 endpoint identity is invalid.' }
    $release=Read-E3Json $ReleaseVerificationReceipt; $r=Assert-ReleaseReceipt $release
    $h=Read-E3Json $HarnessVerificationReceipt
    if ([string]$h.schema -ne $script:HarnessVerificationSchema -or [string]$h.result -ne 'PASS' -or [string]$h.rc_tag -ne $r.tag -or [string]$h.source_commit -ne $r.source -or [string]$h.product_abi -ne $r.abi -or [string]$h.signing_certificate_sha256 -ne $r.cert) { Stop-E3 'VERIFICATION_REQUIRED' 'Matching E3 harness verification is required.' }
    if ((Get-E3Sha256 ([string]$h.test_apk.path)) -ne [string]$h.test_apk.sha256) { Stop-E3 'DIGEST_MISMATCH' 'Verified E3 test APK bytes changed before execution.' }
    $adb=Resolve-E3Executable $AdbPath
    $devices=Invoke-E3Process $adb @('devices') $TimeoutSeconds
    if($devices.ExitCode -ne 0){ Stop-E3 'PROCESS_FAILED' 'adb devices failed.' }
    $rows=@($devices.StdOut -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\s*$' })
    if($rows.Count -ne 1){ Stop-E3 'DEVICE_COUNT_INVALID' 'Full E3 requires exactly one authorized Android device.' }
    $serial=($rows[0] -split '\s+')[0]
    $abi=Invoke-E3Process $adb @('-s',$serial,'shell','getprop','ro.product.cpu.abi') $TimeoutSeconds
    if($abi.ExitCode -ne 0 -or $abi.StdOut.Trim() -ne $r.abi){ Stop-E3 'DEVICE_INVALID' 'E3 device ABI must match the exact verified RC ABI.' }
    $root=Invoke-E3Process $adb @('-s',$serial,'shell','su','-c','id') $TimeoutSeconds
    if($root.ExitCode -ne 0 -or $root.StdOut -notmatch 'uid=0'){ Stop-E3 'ROOT_REQUIRED' 'E3 full-root-toggle requires root.' }

    foreach($install in @(@('install','-r',$r.product_path), @('install','-r','-t',[string]$h.test_apk.path))){
        $res=Invoke-E3Process $adb (@('-s',$serial)+$install) $TimeoutSeconds
        if($res.ExitCode -ne 0 -or $res.StdOut -notmatch '(?m)^Success\s*$'){ Stop-E3 'INSTALL_FAILED' 'Exact verified E3 APK installation failed.' }
    }
    function Set-MobileData([string]$State){ $x=Invoke-E3Process $adb @('-s',$serial,'shell','su','-c',"svc data $State") $TimeoutSeconds; if($x.ExitCode -ne 0){ Stop-E3 'DEVICE_CONTROL_FAILED' 'Root mobile-data transition failed.' } }
    function Run-E3Case([string]$Mode){
        $args=@('-s',$serial,'shell','am','instrument','-w','-r','-e','class',$script:TestClass,'-e','e3Mode',$Mode,'-e','e3Host',$E3Host,'-e','e3Port',[string]$E3Port,'-e','e3Path',$E3Path,$script:TestComponent)
        $x=Invoke-E3Process $adb $args $TimeoutSeconds
        if($x.ExitCode -ne 0 -or $x.StdOut -notmatch 'OK \(1 test\)'){
            $reason=Resolve-E3InstrumentationFailure -StdOut $x.StdOut -ExitCode $x.ExitCode
            Stop-E3 'E3_FAILED' "E3 $Mode instrumentation failed; reason=$reason; raw device output is intentionally not persisted."
        }
    }
    try { Set-MobileData 'enable'; Run-E3Case 'lifecycle' }
    finally { try { [void](Invoke-E3Process $adb @('-s',$serial,'shell','su','-c','svc data enable') $TimeoutSeconds) } catch {} }
    return [pscustomobject]@{ result='PASS'; scenario='full-root-toggle'; e3_pass=$true; rc_tag=$r.tag; source_commit=$r.source; product_abi=$r.abi; test_apk_sha256=[string]$h.test_apk.sha256 }
}

function Invoke-E3Domain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('verify','ready','execute')][string]$Action,
        [string]$ReleaseVerificationReceipt,
        [string]$HarnessVerificationReceipt,
        [long]$HarnessRunId,
        [long]$HarnessArtifactId,
        [string]$ExpectedHarnessZipSha256,
        [string]$ExpectedTestApkSha256,
        [string]$HarnessDirectory,
        [string]$ReceiptPath,
        [string]$RunMetadataPath,
        [string]$ArtifactMetadataPath,
        [string]$AndroidObservationPath,
        [string]$EvidencePath,
        [string]$AdbPath='adb',
        [string]$E3Host='checkip.amazonaws.com',
        [ValidateRange(1,65535)][int]$E3Port=80,
        [string]$E3Path='/',
        [ValidateRange(1,3600)][int]$TimeoutSeconds=180
    )
    switch($Action){
        'verify' {
            return Invoke-E3HarnessVerify `
                -ReleaseVerificationReceipt $ReleaseVerificationReceipt `
                -HarnessRunId $HarnessRunId `
                -HarnessArtifactId $HarnessArtifactId `
                -ExpectedHarnessZipSha256 $ExpectedHarnessZipSha256 `
                -ExpectedTestApkSha256 $ExpectedTestApkSha256 `
                -HarnessDirectory $HarnessDirectory `
                -ReceiptPath $ReceiptPath `
                -RunMetadataPath $RunMetadataPath `
                -ArtifactMetadataPath $ArtifactMetadataPath
        }
        'ready' { return Invoke-E3Readiness $ReleaseVerificationReceipt $HarnessVerificationReceipt $AndroidObservationPath $EvidencePath }
        'execute' { return Invoke-E3FullRootToggle $ReleaseVerificationReceipt $HarnessVerificationReceipt $AdbPath $E3Host $E3Port $E3Path $TimeoutSeconds }
    }
}

Export-ModuleMember -Function Invoke-E3Domain