[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$labctl = Join-Path $PSScriptRoot 'labctl.ps1'
$fixture = Join-Path $PSScriptRoot 'external-client-fixture.json'
$pwsh = (Get-Process -Id $PID).Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('mish-e4-test-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temp) | Out-Null

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-LabctlChild {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$ExpectedExitCode
    )
    $output = & $pwsh -NoLogo -NoProfile -NonInteractive -File $labctl @Arguments 2>&1
    $actual = $LASTEXITCODE
    if ($actual -ne $ExpectedExitCode) {
        throw "labctl exit code $actual did not match expected $ExpectedExitCode. Output: $($output -join ' ')"
    }
    return @($output)
}

function New-PassScenario {
    param([Parameter(Mandatory)][string]$Id)
    $facts = [ordered]@{}
    switch ($Id) {
        'background_idle_5m' { $facts.observed_seconds = 300 }
        'background_post_idle_10_session_load' {
            $facts.attempted_sessions = 10
            $facts.successful_sessions = 10
        }
        'cellular_loss_fail_closed' { $facts.fallback_observed = $false }
        'ipv6_fail_closed' { $facts.fallback_observed = $false }
        'selected_app_fail_closed' { $facts.direct_fallback_observed = $false }
        'quic_webrtc_no_direct_udp' { $facts.direct_udp_observed = $false }
        'normal_stop_cleanup' { $facts.generation_artifacts_removed = $true }
        'force_stop_explicit_relaunch' {
            $facts.automatic_relaunch_observed = $false
            $facts.explicit_relaunch_recovered = $true
        }
        'owned_child_recovery' { $facts.fresh_generation = $true }
        'root_authority_loss_recovery' {
            $facts.gate_closed_during_loss = $true
            $facts.fresh_reauthorization = $true
        }
        'one_agent_fresh_epoch_reconnect' { $facts.fresh_epoch = $true }
        'one_client_recovery' { $facts.recovered = $true }
        'proxy_wrong_missing_auth_rejected' {
            $facts.wrong_credentials_rejected = $true
            $facts.missing_credentials_rejected = $true
        }
    }
    return [ordered]@{ id = $Id; status = 'PASS'; facts = $facts }
}

function New-ObservationDocument {
    param([Parameter(Mandatory)]$Session)
    $sessionSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Session.Path).Hash.ToLowerInvariant()
    return [ordered]@{
        schema = 'mish.lab.e4-observations/v1'
        repository = 'iamaman11/mobile-proxy-mish'
        session_sha256 = $sessionSha
        release = [ordered]@{
            tag = [string]$Session.Json.release.tag
            source_commit = [string]$Session.Json.release.source_commit
            apk_sha256 = [string]$Session.Json.release.apk_sha256
            signing_certificate_sha256 = [string]$Session.Json.release.signing_certificate_sha256
        }
        scenarios = @($Session.Json.required_scenarios | ForEach-Object { New-PassScenario ([string]$_.id) })
        # Deliberately secret/privacy-shaped arbitrary fields. Final durable E4 evidence must
        # project through an allowlist and never copy these values.
        password = 'must-not-leak'
        token = 'must-not-leak'
        public_ip = '203.0.113.123'
        device_identifier = 'must-not-leak'
    }
}

try {
    $apkPath = Join-Path $temp 'candidate.apk'
    [IO.File]::WriteAllBytes($apkPath, [Text.Encoding]::UTF8.GetBytes('deterministic-e4-product-bytes'))
    $apkSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $apkPath).Hash.ToLowerInvariant()
    $source = '0123456789abcdef0123456789abcdef01234567'
    $cert = 'abcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd'

    $releasePath = Join-Path $temp 'release-verification.json'
    $release = [ordered]@{
        schema = 'mish.lab.release-verification/v1'
        result = 'PASS'
        repository = 'iamaman11/mobile-proxy-mish'
        tag = 'v0.1.0-rc.999'
        source_commit = $source
        abi = 'armeabi-v7a'
        apk = [ordered]@{
            name = 'candidate.apk'
            path = [IO.Path]::GetFullPath($apkPath)
            sha256 = $apkSha
            signing_certificate_sha256 = $cert
        }
    }
    [IO.File]::WriteAllText($releasePath, ($release | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

    # PLAN is deliberately non-accepting: it can bind identities and enumerate the mandatory
    # physical matrix, but it can never claim E4 PASS.
    $sessionPath = Join-Path $temp 'session.json'
    $planOutput = Invoke-LabctlChild @(
        'e4','plan',
        '-VerificationReceipt',$releasePath,
        '-ExternalFixturePath',$fixture,
        '-ReceiptPath',$sessionPath
    ) 0
    $session = Get-Content -Raw -LiteralPath $sessionPath | ConvertFrom-Json
    Assert-True ($session.schema -eq 'mish.lab.e4-session/v1') 'E4 session schema mismatch.'
    Assert-True ($session.result -eq 'READY') 'E4 plan did not return READY.'
    Assert-True ($session.e4_pass -eq $false) 'E4 plan must never claim acceptance.'
    Assert-True ($session.no_evidence_escalation -eq $true) 'E4 plan must preserve NO_EVIDENCE_ESCALATION.'
    Assert-True (@($session.required_scenarios).Count -eq 25) 'Canonical E4 mandatory scenario count drifted.'
    Assert-True (($planOutput -join ' ') -match '"e4_pass":false') 'E4 plan command output must state e4_pass=false.'

    $sessionContext = [pscustomobject]@{ Path = $sessionPath; Json = $session }
    $observationPath = Join-Path $temp 'observations-pass.json'
    $observations = New-ObservationDocument $sessionContext
    [IO.File]::WriteAllText($observationPath, ($observations | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))

    # Final acceptance is allowed only at the trusted Windows/protected-main boundary. Hosted
    # tests project that boundary explicitly; production callers receive it from the runner.
    $savedEnvironment = @{
        GITHUB_REPOSITORY = $env:GITHUB_REPOSITORY
        GITHUB_REF = $env:GITHUB_REF
        GITHUB_REF_PROTECTED = $env:GITHUB_REF_PROTECTED
        GITHUB_SHA = $env:GITHUB_SHA
        GITHUB_RUN_ID = $env:GITHUB_RUN_ID
        RUNNER_OS = $env:RUNNER_OS
        RUNNER_ARCH = $env:RUNNER_ARCH
    }
    $env:GITHUB_REPOSITORY = 'iamaman11/mobile-proxy-mish'
    $env:GITHUB_REF = 'refs/heads/main'
    $env:GITHUB_REF_PROTECTED = 'true'
    $env:GITHUB_SHA = '89abcdef0123456789abcdef0123456789abcdef'
    $env:GITHUB_RUN_ID = '424242'
    $env:RUNNER_OS = 'Windows'
    $env:RUNNER_ARCH = 'X64'

    try {
        $passEvidencePath = Join-Path $temp 'e4-pass.json'
        Invoke-LabctlChild @(
            'e4','finalize',
            '-SessionReceipt',$sessionPath,
            '-ObservationPath',$observationPath,
            '-EvidencePath',$passEvidencePath
        ) 0 | Out-Null
        $passText = Get-Content -Raw -LiteralPath $passEvidencePath
        $passEvidence = $passText | ConvertFrom-Json
        Assert-True ($passEvidence.schema -eq 'mish.lab.e4-evidence/v1') 'E4 PASS evidence schema mismatch.'
        Assert-True ($passEvidence.result -eq 'PASS' -and $passEvidence.e4_pass -eq $true) 'Complete E4 ceremony did not PASS.'
        Assert-True (@($passEvidence.scenarios).Count -eq 25) 'E4 PASS evidence scenario count mismatch.'
        Assert-True (-not $passText.Contains('must-not-leak')) 'E4 evidence leaked arbitrary secret-shaped observation data.'
        Assert-True (-not $passText.Contains('203.0.113.123')) 'E4 evidence leaked public-IP observation data.'
        Assert-True (-not $passText.Contains('password')) 'E4 evidence leaked password-shaped field names.'
        Assert-True (-not $passText.Contains('token')) 'E4 evidence leaked token-shaped field names.'

        # Missing external software is a typed BLOCKED outcome, never a green PASS. labctl uses
        # exit code 3 so automation cannot accidentally treat the ceremony as accepted.
        $blocked = (($observations | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
        $blockedScenario = @($blocked.scenarios | Where-Object { $_.id -eq 'kameleo_junglefox_real_client' })[0]
        $blockedScenario.status = 'BLOCKED'
        $blockedScenario | Add-Member -NotePropertyName reason_code -NotePropertyValue 'EXTERNAL_BINARY_UNAVAILABLE'
        $blockedPath = Join-Path $temp 'observations-blocked.json'
        [IO.File]::WriteAllText($blockedPath, ($blocked | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        $blockedEvidencePath = Join-Path $temp 'e4-blocked.json'
        Invoke-LabctlChild @(
            'e4','finalize',
            '-SessionReceipt',$sessionPath,
            '-ObservationPath',$blockedPath,
            '-EvidencePath',$blockedEvidencePath
        ) 3 | Out-Null
        $blockedEvidence = Get-Content -Raw -LiteralPath $blockedEvidencePath | ConvertFrom-Json
        Assert-True ($blockedEvidence.result -eq 'BLOCKED' -and $blockedEvidence.e4_pass -eq $false) 'Unavailable required client must BLOCK E4.'

        # A real mandatory scenario failure writes sanitized FAIL evidence and exits non-zero.
        $failed = (($observations | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
        $failedScenario = @($failed.scenarios | Where-Object { $_.id -eq 'selected_app_fail_closed' })[0]
        $failedScenario.status = 'FAIL'
        $failedScenario | Add-Member -NotePropertyName reason_code -NotePropertyValue 'DIRECT_FALLBACK_OBSERVED'
        $failedPath = Join-Path $temp 'observations-fail.json'
        [IO.File]::WriteAllText($failedPath, ($failed | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        $failedEvidencePath = Join-Path $temp 'e4-fail.json'
        Invoke-LabctlChild @(
            'e4','finalize',
            '-SessionReceipt',$sessionPath,
            '-ObservationPath',$failedPath,
            '-EvidencePath',$failedEvidencePath
        ) 2 | Out-Null
        $failedEvidence = Get-Content -Raw -LiteralPath $failedEvidencePath | ConvertFrom-Json
        Assert-True ($failedEvidence.result -eq 'FAIL' -and $failedEvidence.e4_pass -eq $false) 'Mandatory scenario failure must fail E4.'

        # Five-minute idle and post-idle load are measurable gates, not labels.
        $shortIdle = (($observations | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
        $shortIdleScenario = @($shortIdle.scenarios | Where-Object { $_.id -eq 'background_idle_5m' })[0]
        $shortIdleScenario.facts.observed_seconds = 299
        $shortIdlePath = Join-Path $temp 'observations-short-idle.json'
        [IO.File]::WriteAllText($shortIdlePath, ($shortIdle | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        Invoke-LabctlChild @(
            'e4','finalize',
            '-SessionReceipt',$sessionPath,
            '-ObservationPath',$shortIdlePath,
            '-EvidencePath',(Join-Path $temp 'must-not-pass-short-idle.json')
        ) 2 | Out-Null

        $weakLoad = (($observations | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
        $weakLoadScenario = @($weakLoad.scenarios | Where-Object { $_.id -eq 'background_post_idle_10_session_load' })[0]
        $weakLoadScenario.facts.successful_sessions = 9
        $weakLoadPath = Join-Path $temp 'observations-weak-load.json'
        [IO.File]::WriteAllText($weakLoadPath, ($weakLoad | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        Invoke-LabctlChild @(
            'e4','finalize',
            '-SessionReceipt',$sessionPath,
            '-ObservationPath',$weakLoadPath,
            '-EvidencePath',(Join-Path $temp 'must-not-pass-weak-load.json')
        ) 2 | Out-Null

        # Observation identity is bound to the exact session receipt, not merely the same tag.
        $wrongSession = (($observations | ConvertTo-Json -Depth 12) | ConvertFrom-Json)
        $wrongSession.session_sha256 = '0' * 64
        $wrongSessionPath = Join-Path $temp 'observations-wrong-session.json'
        [IO.File]::WriteAllText($wrongSessionPath, ($wrongSession | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
        Invoke-LabctlChild @(
            'e4','finalize',
            '-SessionReceipt',$sessionPath,
            '-ObservationPath',$wrongSessionPath,
            '-EvidencePath',(Join-Path $temp 'must-not-pass-wrong-session.json')
        ) 2 | Out-Null

        # Session identity is still byte-bound at finalization time. Stale/tampered APK bytes
        # cannot be promoted by a previously prepared E4 session.
        [IO.File]::AppendAllText($apkPath, 'tampered')
        Invoke-LabctlChild @(
            'e4','finalize',
            '-SessionReceipt',$sessionPath,
            '-ObservationPath',$observationPath,
            '-EvidencePath',(Join-Path $temp 'must-not-pass-tampered-apk.json')
        ) 2 | Out-Null
        [IO.File]::WriteAllBytes($apkPath, [Text.Encoding]::UTF8.GetBytes('deterministic-e4-product-bytes'))

        # Finalization cannot run from an arbitrary branch even with syntactically valid input.
        $env:GITHUB_REF = 'refs/heads/not-main'
        Invoke-LabctlChild @(
            'e4','finalize',
            '-SessionReceipt',$sessionPath,
            '-ObservationPath',$observationPath,
            '-EvidencePath',(Join-Path $temp 'must-not-pass-untrusted-ref.json')
        ) 2 | Out-Null
        $env:GITHUB_REF = 'refs/heads/main'
    }
    finally {
        foreach ($key in $savedEnvironment.Keys) {
            Set-Item -Path "Env:$key" -Value $savedEnvironment[$key]
        }
    }

    Write-Host 'E4_HARNESS_DETERMINISTIC_TESTS=PASS'
}
finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}

$global:LASTEXITCODE = 0
exit 0
