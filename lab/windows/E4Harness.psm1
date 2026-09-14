Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Repository = 'iamaman11/mobile-proxy-mish'
$script:ReleaseVerificationSchema = 'mish.lab.release-verification/v1'
$script:FixtureSchema = 'mish.external-client-fixture/v1'
$script:SessionSchema = 'mish.lab.e4-session/v1'
$script:ObservationSchema = 'mish.lab.e4-observations/v1'
$script:EvidenceSchema = 'mish.lab.e4-evidence/v1'
$script:Hex40Pattern = '^[0-9a-f]{40}$'
$script:Hex64Pattern = '^[0-9a-f]{64}$'
$script:ReasonCodePattern = '^[A-Z][A-Z0-9_]{2,63}$'
$script:SupportedAndroidAbis = @('armeabi-v7a', 'arm64-v8a')

# This is the canonical M1 E4 acceptance matrix. Every ID is mandatory. A scenario
# may be BLOCKED when an external prerequisite is genuinely unavailable, but a
# BLOCKED ceremony is never E4 PASS.
$script:RequiredScenarioIds = @(
    'windows_route_ownership',
    'android_vpn_ownership',
    'mesh_reachability',
    'proxy_1080_mixed_auth',
    'proxy_1081_socks5_auth',
    'proxy_3128_http_connect_auth',
    'proxy_wrong_missing_auth_rejected',
    'cellular_positive',
    'cellular_loss_fail_closed',
    'cellular_recovery',
    'ipv6_fail_closed',
    'background_idle_5m',
    'background_post_idle_10_session_load',
    'background_foreground',
    'normal_stop_cleanup',
    'force_stop_explicit_relaunch',
    'owned_child_recovery',
    'root_authority_loss_recovery',
    'one_agent_fresh_epoch_reconnect',
    'one_client_recovery',
    'selected_app_fail_closed',
    'quic_webrtc_no_direct_udp',
    'camoufox_real_client',
    'kameleo_chroma_real_client',
    'kameleo_junglefox_real_client'
)

function Stop-E4 {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )
    throw "MISH_LABCTL_FAILURE|$Category|$Message"
}

function Read-E4Json {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Stop-E4 'ARTIFACT_MISSING' 'Required E4 JSON input is missing.'
    }
    try {
        return Get-Content -Raw -LiteralPath $full | ConvertFrom-Json
    }
    catch {
        Stop-E4 'ARTIFACT_INVALID' 'Required E4 JSON input is invalid.'
    }
}

function Write-E4Json {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $full,
        (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    return $full
}

function Get-E4Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-E4 'ARTIFACT_MISSING' 'Required E4 artifact is missing.'
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-E4Hex40 {
    param([string]$Value, [string]$Name)
    if ($Value -notmatch $script:Hex40Pattern) { Stop-E4 'IDENTITY_MISMATCH' "$Name must be lowercase 40-hex." }
}

function Assert-E4Hex64 {
    param([string]$Value, [string]$Name)
    if ($Value -notmatch $script:Hex64Pattern) { Stop-E4 'IDENTITY_MISMATCH' "$Name must be lowercase 64-hex." }
}

function Get-E4Property {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Assert-PhysicalMain {
    if ($env:GITHUB_REPOSITORY -ne $script:Repository -or
        $env:GITHUB_REF -ne 'refs/heads/main' -or
        $env:GITHUB_REF_PROTECTED -ne 'true') {
        Stop-E4 'UNTRUSTED_REF' 'E4 finalization requires protected main.'
    }
    if ($env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64') {
        Stop-E4 'IDENTITY_MISMATCH' 'E4 finalization requires the accepted Windows x64 LAB boundary.'
    }
}

function Assert-ReleaseReceipt {
    param([Parameter(Mandatory)]$Receipt)
    if ([string]$Receipt.schema -ne $script:ReleaseVerificationSchema -or
        [string]$Receipt.result -ne 'PASS' -or
        [string]$Receipt.repository -ne $script:Repository) {
        Stop-E4 'VERIFICATION_REQUIRED' 'A PASS exact release verification receipt is required.'
    }

    $tag = [string]$Receipt.tag
    $source = [string]$Receipt.source_commit
    $abi = [string]$Receipt.abi
    $apkName = [string]$Receipt.apk.name
    $apkPath = [string]$Receipt.apk.path
    $apkSha = [string]$Receipt.apk.sha256
    $cert = [string]$Receipt.apk.signing_certificate_sha256

    if ([string]::IsNullOrWhiteSpace($tag) -or [string]::IsNullOrWhiteSpace($apkName)) {
        Stop-E4 'IDENTITY_MISMATCH' 'Verified release tag/APK identity is incomplete.'
    }
    Assert-E4Hex40 $source 'ReleaseSource'
    Assert-E4Hex64 $apkSha 'ProductApkSha256'
    Assert-E4Hex64 $cert 'SigningCertificateSha256'
    if (-not ($script:SupportedAndroidAbis -contains $abi)) {
        Stop-E4 'IDENTITY_MISMATCH' 'Verified release Android ABI is unsupported.'
    }
    if (-not [IO.Path]::IsPathFullyQualified($apkPath)) {
        Stop-E4 'IDENTITY_MISMATCH' 'Verified product APK path must be absolute.'
    }
    $fullApkPath = [IO.Path]::GetFullPath($apkPath)
    if ((Get-E4Sha256 $fullApkPath) -ne $apkSha) {
        Stop-E4 'DIGEST_MISMATCH' 'Verified product APK bytes changed after release verification.'
    }

    return [pscustomobject]@{
        tag = $tag
        source = $source
        abi = $abi
        apk_name = $apkName
        apk_path = $fullApkPath
        apk_sha256 = $apkSha
        signing_certificate_sha256 = $cert
    }
}

function Assert-ExternalFixture {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $fixture = Read-E4Json $full
    if ([string]$fixture.schema -ne $script:FixtureSchema) {
        Stop-E4 'FIXTURE_INVALID' 'External-client fixture schema mismatch.'
    }
    if ([string]$fixture.m1_transport_contract.product_transport -ne 'tcp-only' -or
        $fixture.m1_transport_contract.udp_quic_product_support -ne $false) {
        Stop-E4 'FIXTURE_INVALID' 'External-client fixture no longer describes the accepted M1 TCP-only contract.'
    }

    $surfaces = @($fixture.m1_transport_contract.proxy_surface)
    if ($surfaces.Count -ne 3) {
        Stop-E4 'FIXTURE_INVALID' 'External-client fixture must contain exactly three proxy surfaces.'
    }
    $ports = @($surfaces | ForEach-Object { [int]$_.port } | Sort-Object)
    if (($ports -join ',') -ne '1080,1081,3128') {
        Stop-E4 'FIXTURE_INVALID' 'External-client fixture proxy ports drifted from the accepted M1 contract.'
    }
    foreach ($surface in $surfaces) {
        if ([string]$surface.transport -ne 'tcp') {
            Stop-E4 'FIXTURE_INVALID' 'Every M1 external proxy surface must remain TCP-only.'
        }
    }

    foreach ($value in @(
        [string]$fixture.kameleo.engine_version,
        [string]$fixture.kameleo.chroma.kernel_release,
        [string]$fixture.kameleo.junglefox.kernel_release,
        [string]$fixture.camoufox.browser_version,
        [string]$fixture.camoufox.python_package_version
    )) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            Stop-E4 'FIXTURE_INVALID' 'Pinned external-client version identity is incomplete.'
        }
    }

    return [pscustomobject]@{
        path = $full
        sha256 = Get-E4Sha256 $full
        kameleo_engine = [string]$fixture.kameleo.engine_version
        kameleo_chroma = [string]$fixture.kameleo.chroma.kernel_release
        kameleo_junglefox = [string]$fixture.kameleo.junglefox.kernel_release
        camoufox_browser = [string]$fixture.camoufox.browser_version
        camoufox_python = [string]$fixture.camoufox.python_package_version
    }
}

function Invoke-E4Plan {
    param(
        [Parameter(Mandatory)][string]$ReleaseVerificationReceipt,
        [Parameter(Mandatory)][string]$ExternalFixturePath,
        [Parameter(Mandatory)][string]$ReceiptPath
    )

    $release = Assert-ReleaseReceipt (Read-E4Json $ReleaseVerificationReceipt)
    $fixture = Assert-ExternalFixture $ExternalFixturePath
    $session = [ordered]@{
        schema = $script:SessionSchema
        result = 'READY'
        e4_pass = $false
        no_evidence_escalation = $true
        repository = $script:Repository
        release = [ordered]@{
            tag = $release.tag
            source_commit = $release.source
            abi = $release.abi
            apk_name = $release.apk_name
            apk_path = $release.apk_path
            apk_sha256 = $release.apk_sha256
            signing_certificate_sha256 = $release.signing_certificate_sha256
        }
        fixture = [ordered]@{
            schema = $script:FixtureSchema
            path = $fixture.path
            sha256 = $fixture.sha256
            kameleo_engine = $fixture.kameleo_engine
            kameleo_chroma = $fixture.kameleo_chroma
            kameleo_junglefox = $fixture.kameleo_junglefox
            camoufox_browser = $fixture.camoufox_browser
            camoufox_python = $fixture.camoufox_python
        }
        required_scenarios = @($script:RequiredScenarioIds | ForEach-Object { [ordered]@{ id = $_; required = $true } })
        created_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $written = Write-E4Json $session $ReceiptPath
    return [pscustomobject]@{
        result = 'READY'
        e4_pass = $false
        no_evidence_escalation = $true
        rc_tag = $release.tag
        scenario_count = $script:RequiredScenarioIds.Count
        receipt = $written
    }
}

function Assert-SessionReceipt {
    param([Parameter(Mandatory)][string]$Path)
    $session = Read-E4Json $Path
    if ([string]$session.schema -ne $script:SessionSchema -or
        [string]$session.result -ne 'READY' -or
        $session.e4_pass -ne $false -or
        $session.no_evidence_escalation -ne $true -or
        [string]$session.repository -ne $script:Repository) {
        Stop-E4 'VERIFICATION_REQUIRED' 'A READY non-PASS E4 session receipt is required.'
    }

    $source = [string]$session.release.source_commit
    $apkSha = [string]$session.release.apk_sha256
    $cert = [string]$session.release.signing_certificate_sha256
    $abi = [string]$session.release.abi
    Assert-E4Hex40 $source 'SessionReleaseSource'
    Assert-E4Hex64 $apkSha 'SessionProductApkSha256'
    Assert-E4Hex64 $cert 'SessionSigningCertificateSha256'
    if (-not ($script:SupportedAndroidAbis -contains $abi)) {
        Stop-E4 'IDENTITY_MISMATCH' 'E4 session Android ABI is unsupported.'
    }
    $apkPath = [string]$session.release.apk_path
    if (-not [IO.Path]::IsPathFullyQualified($apkPath) -or (Get-E4Sha256 $apkPath) -ne $apkSha) {
        Stop-E4 'DIGEST_MISMATCH' 'E4 session product APK bytes are absent or changed.'
    }
    $fixturePath = [string]$session.fixture.path
    $fixtureSha = [string]$session.fixture.sha256
    Assert-E4Hex64 $fixtureSha 'SessionFixtureSha256'
    if (-not [IO.Path]::IsPathFullyQualified($fixturePath) -or (Get-E4Sha256 $fixturePath) -ne $fixtureSha) {
        Stop-E4 'DIGEST_MISMATCH' 'E4 session external-client fixture bytes are absent or changed.'
    }

    $sessionIds = @($session.required_scenarios | ForEach-Object { [string]$_.id })
    if ($sessionIds.Count -ne $script:RequiredScenarioIds.Count -or
        (($sessionIds | Sort-Object) -join ',') -ne (($script:RequiredScenarioIds | Sort-Object) -join ',')) {
        Stop-E4 'CONTRACT_MISMATCH' 'E4 session mandatory scenario set drifted.'
    }
    foreach ($entry in @($session.required_scenarios)) {
        if ($entry.required -ne $true) { Stop-E4 'CONTRACT_MISMATCH' 'Every E4 scenario is mandatory for final PASS.' }
    }
    return $session
}

function Assert-BooleanFact {
    param(
        [Parameter(Mandatory)]$Scenario,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Expected
    )
    $facts = Get-E4Property $Scenario 'facts'
    if ($null -eq $facts) { Stop-E4 'OBSERVATION_INVALID' "Scenario $($Scenario.id) is missing required facts." }
    $value = Get-E4Property $facts $Name
    if ($value -isnot [bool] -or [bool]$value -ne $Expected) {
        Stop-E4 'OBSERVATION_INVALID' "Scenario $($Scenario.id) has invalid $Name fact."
    }
}

function Assert-MinimumIntegerFact {
    param(
        [Parameter(Mandatory)]$Scenario,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][int]$Minimum
    )
    $facts = Get-E4Property $Scenario 'facts'
    if ($null -eq $facts) { Stop-E4 'OBSERVATION_INVALID' "Scenario $($Scenario.id) is missing required facts." }
    $value = Get-E4Property $facts $Name
    if ($null -eq $value) { Stop-E4 'OBSERVATION_INVALID' "Scenario $($Scenario.id) is missing $Name." }
    try { $number = [int]$value } catch { Stop-E4 'OBSERVATION_INVALID' "Scenario $($Scenario.id) has non-integer $Name." }
    if ($number -lt $Minimum) { Stop-E4 'OBSERVATION_INVALID' "Scenario $($Scenario.id) does not meet the minimum $Name contract." }
}

function Assert-PassScenarioFacts {
    param([Parameter(Mandatory)][hashtable]$ScenarioById)

    Assert-MinimumIntegerFact $ScenarioById['background_idle_5m'] 'observed_seconds' 300
    Assert-MinimumIntegerFact $ScenarioById['background_post_idle_10_session_load'] 'attempted_sessions' 10
    Assert-MinimumIntegerFact $ScenarioById['background_post_idle_10_session_load'] 'successful_sessions' 10

    Assert-BooleanFact $ScenarioById['cellular_loss_fail_closed'] 'fallback_observed' $false
    Assert-BooleanFact $ScenarioById['ipv6_fail_closed'] 'fallback_observed' $false
    Assert-BooleanFact $ScenarioById['selected_app_fail_closed'] 'direct_fallback_observed' $false
    Assert-BooleanFact $ScenarioById['quic_webrtc_no_direct_udp'] 'direct_udp_observed' $false

    Assert-BooleanFact $ScenarioById['normal_stop_cleanup'] 'generation_artifacts_removed' $true
    Assert-BooleanFact $ScenarioById['force_stop_explicit_relaunch'] 'automatic_relaunch_observed' $false
    Assert-BooleanFact $ScenarioById['force_stop_explicit_relaunch'] 'explicit_relaunch_recovered' $true
    Assert-BooleanFact $ScenarioById['owned_child_recovery'] 'fresh_generation' $true
    Assert-BooleanFact $ScenarioById['root_authority_loss_recovery'] 'gate_closed_during_loss' $true
    Assert-BooleanFact $ScenarioById['root_authority_loss_recovery'] 'fresh_reauthorization' $true
    Assert-BooleanFact $ScenarioById['one_agent_fresh_epoch_reconnect'] 'fresh_epoch' $true
    Assert-BooleanFact $ScenarioById['one_client_recovery'] 'recovered' $true
    Assert-BooleanFact $ScenarioById['proxy_wrong_missing_auth_rejected'] 'wrong_credentials_rejected' $true
    Assert-BooleanFact $ScenarioById['proxy_wrong_missing_auth_rejected'] 'missing_credentials_rejected' $true
}

function Get-SanitizedScenarioEvidence {
    param([Parameter(Mandatory)]$Scenario)
    $safe = [ordered]@{
        id = [string]$Scenario.id
        status = [string]$Scenario.status
    }
    $reason = [string](Get-E4Property $Scenario 'reason_code' '')
    if ($reason) { $safe.reason_code = $reason }

    if ([string]$Scenario.status -eq 'PASS') {
        switch ([string]$Scenario.id) {
            'background_idle_5m' {
                $safe.observed_seconds = [int](Get-E4Property (Get-E4Property $Scenario 'facts') 'observed_seconds')
            }
            'background_post_idle_10_session_load' {
                $safe.attempted_sessions = [int](Get-E4Property (Get-E4Property $Scenario 'facts') 'attempted_sessions')
                $safe.successful_sessions = [int](Get-E4Property (Get-E4Property $Scenario 'facts') 'successful_sessions')
            }
            'owned_child_recovery' { $safe.fresh_generation = $true }
            'root_authority_loss_recovery' {
                $safe.gate_closed_during_loss = $true
                $safe.fresh_reauthorization = $true
            }
            'one_agent_fresh_epoch_reconnect' { $safe.fresh_epoch = $true }
            'force_stop_explicit_relaunch' {
                $safe.automatic_relaunch_observed = $false
                $safe.explicit_relaunch_recovered = $true
            }
        }
    }
    return $safe
}

function Invoke-E4Finalize {
    param(
        [Parameter(Mandatory)][string]$SessionReceipt,
        [Parameter(Mandatory)][string]$ObservationPath,
        [Parameter(Mandatory)][string]$EvidencePath
    )

    Assert-PhysicalMain
    $session = Assert-SessionReceipt $SessionReceipt
    $sessionSha = Get-E4Sha256 $SessionReceipt
    $observations = Read-E4Json $ObservationPath

    if ([string]$observations.schema -ne $script:ObservationSchema -or
        [string]$observations.repository -ne $script:Repository -or
        [string]$observations.session_sha256 -ne $sessionSha) {
        Stop-E4 'IDENTITY_MISMATCH' 'E4 observation set is not bound to the exact prepared session.'
    }
    Assert-E4Hex64 ([string]$observations.session_sha256) 'ObservationSessionSha256'

    if ([string]$observations.release.tag -ne [string]$session.release.tag -or
        [string]$observations.release.source_commit -ne [string]$session.release.source_commit -or
        [string]$observations.release.apk_sha256 -ne [string]$session.release.apk_sha256 -or
        [string]$observations.release.signing_certificate_sha256 -ne [string]$session.release.signing_certificate_sha256) {
        Stop-E4 'IDENTITY_MISMATCH' 'E4 observations do not match the exact session release identity.'
    }

    $entries = @($observations.scenarios)
    if ($entries.Count -ne $script:RequiredScenarioIds.Count) {
        Stop-E4 'OBSERVATION_INVALID' 'E4 observation set must contain exactly the canonical mandatory scenarios.'
    }
    $scenarioById = @{}
    foreach ($entry in $entries) {
        $id = [string]$entry.id
        $status = [string]$entry.status
        if (-not ($script:RequiredScenarioIds -contains $id) -or $scenarioById.ContainsKey($id)) {
            Stop-E4 'OBSERVATION_INVALID' 'E4 observation contains an unknown or duplicate scenario ID.'
        }
        if (-not (@('PASS','FAIL','BLOCKED') -contains $status)) {
            Stop-E4 'OBSERVATION_INVALID' "E4 scenario $id has an invalid status."
        }
        $reason = [string](Get-E4Property $entry 'reason_code' '')
        if ($status -eq 'PASS') {
            if ($reason) { Stop-E4 'OBSERVATION_INVALID' "PASS scenario $id must not carry a failure reason code." }
        }
        elseif ($reason -notmatch $script:ReasonCodePattern) {
            Stop-E4 'OBSERVATION_INVALID' "Non-PASS scenario $id requires a bounded uppercase reason_code."
        }
        $scenarioById[$id] = $entry
    }
    foreach ($required in $script:RequiredScenarioIds) {
        if (-not $scenarioById.ContainsKey($required)) {
            Stop-E4 'OBSERVATION_INVALID' "Mandatory E4 scenario is missing: $required"
        }
    }

    $failed = @($entries | Where-Object { [string]$_.status -eq 'FAIL' })
    $blocked = @($entries | Where-Object { [string]$_.status -eq 'BLOCKED' })
    if ($failed.Count -eq 0 -and $blocked.Count -eq 0) {
        Assert-PassScenarioFacts $scenarioById
    }

    $result = if ($failed.Count -gt 0) { 'FAIL' } elseif ($blocked.Count -gt 0) { 'BLOCKED' } else { 'PASS' }
    $evidence = [ordered]@{
        schema = $script:EvidenceSchema
        result = $result
        e4_pass = ($result -eq 'PASS')
        repository = $script:Repository
        execution_adapter = [ordered]@{
            git_ref = [string]$env:GITHUB_REF
            git_commit = [string]$env:GITHUB_SHA
            run_id = [string]$env:GITHUB_RUN_ID
        }
        release = [ordered]@{
            tag = [string]$session.release.tag
            source_commit = [string]$session.release.source_commit
            abi = [string]$session.release.abi
            apk_sha256 = [string]$session.release.apk_sha256
            signing_certificate_sha256 = [string]$session.release.signing_certificate_sha256
        }
        fixture = [ordered]@{
            sha256 = [string]$session.fixture.sha256
            kameleo_engine = [string]$session.fixture.kameleo_engine
            kameleo_chroma = [string]$session.fixture.kameleo_chroma
            kameleo_junglefox = [string]$session.fixture.kameleo_junglefox
            camoufox_browser = [string]$session.fixture.camoufox_browser
            camoufox_python = [string]$session.fixture.camoufox_python
        }
        scenarios = @($entries | Sort-Object { [string]$_.id } | ForEach-Object { Get-SanitizedScenarioEvidence $_ })
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $written = Write-E4Json $evidence $EvidencePath

    if ($failed.Count -gt 0) {
        $ids = @($failed | ForEach-Object { [string]$_.id }) -join ','
        Stop-E4 'E4_FAILED' "E4 physical ceremony failed mandatory scenarios: $ids"
    }
    if ($blocked.Count -gt 0) {
        return [pscustomobject]@{
            result = 'BLOCKED'
            e4_pass = $false
            blocked_scenarios = @($blocked | ForEach-Object { [string]$_.id })
            evidence = $written
        }
    }
    return [pscustomobject]@{
        result = 'PASS'
        e4_pass = $true
        scenario_count = $entries.Count
        evidence = $written
    }
}

function Invoke-E4Domain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('plan','finalize')][string]$Action,
        [string]$ReleaseVerificationReceipt,
        [string]$ExternalFixturePath,
        [string]$ReceiptPath,
        [string]$SessionReceipt,
        [string]$ObservationPath,
        [string]$EvidencePath
    )
    switch ($Action) {
        'plan' {
            if (-not $ReleaseVerificationReceipt -or -not $ExternalFixturePath -or -not $ReceiptPath) {
                Stop-E4 'INPUT_INVALID' 'E4 plan requires release verification, external fixture, and receipt path.'
            }
            return Invoke-E4Plan $ReleaseVerificationReceipt $ExternalFixturePath $ReceiptPath
        }
        'finalize' {
            if (-not $SessionReceipt -or -not $ObservationPath -or -not $EvidencePath) {
                Stop-E4 'INPUT_INVALID' 'E4 finalize requires session receipt, physical observations, and evidence path.'
            }
            return Invoke-E4Finalize $SessionReceipt $ObservationPath $EvidencePath
        }
    }
}

Export-ModuleMember -Function Invoke-E4Domain
