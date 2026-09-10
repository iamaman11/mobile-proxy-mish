[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$labctl = Join-Path $PSScriptRoot 'labctl.ps1'
$module = Join-Path $PSScriptRoot 'Labctl.psm1'
$pwsh = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('mish-labctl-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-LabctlChild {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][int]$ExpectedExitCode)
    $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $labctl @Arguments 2>&1
    $actual = $LASTEXITCODE
    if ($actual -ne $ExpectedExitCode) {
        throw "labctl exit code $actual did not match expected $ExpectedExitCode. Output: $($output -join ' ')"
    }
    return @($output)
}

try {
    $tag = 'v0.1.0-rc.1'
    $source = '4542c1e2a16f3ac93f52ecb2464c2cfc0cafb3c0'
    $cert = '1958d474069ce0f8b8e5390c9c4ebecd6e306fb4e0f0f6e12d35c9b91cc67803'
    $apkName = "mobile-proxy-mish-$tag.apk"
    $apkPath = Join-Path $temp $apkName
    [IO.File]::WriteAllBytes($apkPath, [Text.Encoding]::UTF8.GetBytes('deterministic-labctl-fixture'))
    $digest = (Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath).Hash.ToLowerInvariant()

    $manifestPath = Join-Path $temp "mobile-proxy-mish-$tag.release.json"
    $manifest = [ordered]@{
        schema = 'mish.android-release/v1'
        channel = 'rc'
        product = [ordered]@{
            version = '0.1.0'
            release_tag = $tag
            rc_number = 1
            source_commit = $source
            android_version_code = 1000001
            abi = 'arm64-v8a'
            build_mode = 'release'
        }
        artifact = [ordered]@{
            name = $apkName
            sha256 = $digest
            signing_certificate_sha256 = $cert
        }
    }
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

    $verification = Join-Path $temp 'verification.json'
    Invoke-LabctlChild @(
        'release','verify',
        '-Tag',$tag,
        '-ExpectedSourceCommit',$source,
        '-ExpectedApkSha256',$digest,
        '-ExpectedSigningCertificateSha256',$cert,
        '-Directory',$temp,
        '-ReceiptPath',$verification
    ) 0 | Out-Null

    $receipt = Get-Content -Raw -LiteralPath $verification | ConvertFrom-Json
    Assert-True ($receipt.schema -eq 'mish.lab.release-verification/v1') 'Verification schema mismatch.'
    Assert-True ($receipt.result -eq 'PASS') 'Verification receipt did not PASS.'
    Assert-True ($receipt.apk.sha256 -eq $digest) 'Verification digest mismatch.'

    $wrongDigest = '0' * 64
    $negativeReceipt = Join-Path $temp 'negative.json'
    Invoke-LabctlChild @(
        'release','verify',
        '-Tag',$tag,
        '-ExpectedSourceCommit',$source,
        '-ExpectedApkSha256',$wrongDigest,
        '-ExpectedSigningCertificateSha256',$cert,
        '-Directory',$temp,
        '-ReceiptPath',$negativeReceipt
    ) 2 | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $negativeReceipt)) 'Digest mismatch must not emit a PASS receipt.'

    $receipt | Add-Member -NotePropertyName 'password' -NotePropertyValue 'must-not-leak'
    $receipt | Add-Member -NotePropertyName 'token' -NotePropertyValue 'must-not-leak'
    [IO.File]::WriteAllText($verification, ($receipt | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $evidencePath = Join-Path $temp 'evidence.json'
    Invoke-LabctlChild @('evidence','collect','-InputPath',$verification,'-EvidencePath',$evidencePath) 0 | Out-Null
    $evidenceText = Get-Content -Raw -LiteralPath $evidencePath
    $evidence = $evidenceText | ConvertFrom-Json
    Assert-True ($evidence.schema -eq 'mish.lab.evidence/v1') 'Evidence schema mismatch.'
    Assert-True ($evidence.observations.release.apk_sha256 -eq $digest) 'Evidence release digest mismatch.'
    Assert-True (-not $evidenceText.Contains('must-not-leak')) 'Evidence allowlist leaked arbitrary input data.'
    Assert-True (-not $evidenceText.Contains('password')) 'Evidence must not contain password-shaped input.'
    Assert-True (-not $evidenceText.Contains('token')) 'Evidence must not contain token-shaped input.'

    # Install must reject stale bytes before it can invoke adb.
    [IO.File]::AppendAllText($apkPath, 'tampered')
    Invoke-LabctlChild @(
        'android','install',
        '-VerificationReceipt',$verification,
        '-Tag',$tag,
        '-ExpectedSourceCommit',$source,
        '-ExpectedApkSha256',$digest,
        '-ExpectedSigningCertificateSha256',$cert,
        '-AdbPath','this-adb-command-must-never-run'
    ) 2 | Out-Null

    # Test the private bounded-process primitive without exposing it as a labctl command.
    Import-Module $module -Force
    $moduleInfo = Get-Module Labctl
    $timeoutObserved = $false
    try {
        & $moduleInfo {
            param($Executable)
            Invoke-LabProcess $Executable @('-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 5') 1 | Out-Null
        } $pwsh
    }
    catch {
        $timeoutObserved = $_.Exception.Message -match '^MISH_LABCTL_FAILURE\|PROCESS_TIMEOUT\|'
    }
    Assert-True $timeoutObserved 'Bounded subprocess timeout was not enforced.'

    Write-Host 'LABCTL_DETERMINISTIC_TESTS=PASS'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

# Expected negative child cases set LASTEXITCODE; do not let that leak into the
# test-harness process result after all assertions have passed.
$global:LASTEXITCODE = 0
exit 0
