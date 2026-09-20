$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = Join-Path $env:TEMP ('mish-device-cycle-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    foreach ($path in @(
        'start-device-app.ps1',
        'collect-device-diagnostic.ps1',
        'DeviceDiagnosticClassification.psm1',
        'DiagnosticConnectProbe.psm1',
        'diagnose-loopback-connect.ps1',
        'diagnose-capacity-resources.ps1',
        'diagnose-dns-lifetime-live.ps1',
        'test-diagnostic-connect-probe.ps1',
        'new-device-cycle-report.ps1'
    )) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $PSScriptRoot $path),
            [ref]$tokens,
            [ref]$errors
        )
        if ($errors.Count -ne 0) {
            $errors | ForEach-Object { Write-Error "${path}: $($_.Message)" }
            throw "PowerShell parse failed for $path."
        }
        if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
            throw "PowerShell automatic variable `$PID must not be reused by device-cycle script $path."
        }
    }

    & (Join-Path $PSScriptRoot 'test-diagnostic-connect-probe.ps1')

    $loopbackProbeSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'diagnose-loopback-connect.ps1')
    foreach ($required in @(
        "'ss', '-H', '-tanp'",
        "'/proc/net/tcp'",
        "'/proc/net/tcp6'",
        'listener_state = $listenerState',
        'MISH_LOOPBACK_DIAGNOSTIC_TARGET_SOCKET_ROWS',
        'Invoke-MishDiagnosticHttpRelayProbe',
        'Invoke-MishDiagnosticSocks5RelayProbe',
        '$forwardPorts[1080]',
        '$forwardPorts[1081]',
        '$forwardPorts[3128]',
        '-ExpectAuthRejection',
        'protocol_matrix = $protocolMatrix',
        'U2_PROXY_PROTOCOL_MATRIX_PASS',
        'MISH_LOOPBACK_DIAGNOSTIC_PROTOCOL_MATRIX_PASS'
    )) {
        if (-not $loopbackProbeSource.Contains($required)) {
            throw "Manual loopback probe lost bounded U2 listener/protocol evidence: $required"
        }
    }
    foreach ($forbidden in @('sing-box', "'shell', 'su'", "'shell', 'kill'", "'shell', 'pkill'", "'shell', 'am', 'force-stop'")) {
        if ($loopbackProbeSource.Contains($forbidden)) {
            throw "Manual loopback probe must remain product-agnostic, read-only and non-root: $forbidden"
        }
    }

    $capacitySource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'diagnose-capacity-resources.ps1')
    foreach ($required in @(
        "content://`$PackageName.diagnostics",
        "`$snapshot.mesh.active_sessions",
        "`$snapshot.proxy.active_sessions",
        'Find-NetRoute -RemoteIPAddress $meshAddress',
        'ConnectAsync($ProxyHost, 3128)',
        'foreach ($target in @(10, 32, 64))',
        'Test-MishOverflowRejected',
        'Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64',
        'Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0',
        "Import-Module (Join-Path `$PSScriptRoot 'U7Measurement.psm1') -Force",
        "acceptance_profile = 'u7-baseline-v1'",
        "batch_model = 'independent_bounded'",
        'Get-MishSafeOwnerDiagnostics',
        'Measure-MishU7SupplementalObservation',
        "`$stageRecord['cleanup'] = [ordered]@{",
        'resource_delta_from_idle',
        "'shell', 'run-as', `$PackageName, 'cat'",
        "'shell', 'dumpsys', 'meminfo', '-s'",
        "schema = 'mish.lab.capacity-resources/v1'",
        "acceptance_result = `$acceptanceResult",
        'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS',
        'post_cleanup_delta_from_idle'
    )) {
        if (-not $capacitySource.Contains($required)) {
            throw "Capacity/resource probe lost real-path owner evidence: $required"
        }
    }
    $u7MeasurementSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'U7Measurement.psm1')
    foreach ($required in @(
        'Get-MishU7CpuObservation',
        'process_cpu_percent_total_capacity',
        'process_cpu_percent_one_core_equivalent',
        "'dumpsys', 'battery'",
        "'dumpsys', 'thermalservice'",
        "'ps', '-A', '-o', 'PID,PPID,NAME'",
        "'ps', '-A', '-T', '-w', '-o', 'PID,TID,CMD'",
        "'mish-runtime-i*'",
        'external_powered = $externalPower',
        'product_su_like_descendants'
    )) {
        if (-not $u7MeasurementSource.Contains($required)) {
            throw "U7 measurement helper lost bounded host evidence: $required"
        }
    }
    foreach ($forbidden in @(
        "'shell', 'su'",
        "'shell', 'kill'",
        "'shell', 'pkill'",
        'settings put',
        'airplane-mode'
    )) {
        if ($u7MeasurementSource.Contains($forbidden)) {
            throw "U7 measurement helper became a mutation path: $forbidden"
        }
    }
    foreach ($forbidden in @(
        " forward ",
        "'forward'",
        "'shell', 'su'",
        "'shell', 'kill'",
        "'shell', 'pkill'",
        'airplane-mode',
        'settings put',
        'sing-box'
    )) {
        if ($capacitySource.Contains($forbidden)) {
            throw "Capacity/resource probe must stay external-Mesh, read-only and non-root: $forbidden"
        }
    }

    Import-Module (Join-Path $PSScriptRoot 'DeviceDiagnosticClassification.psm1') -Force
    $base = @{
        PidStable = $true
        AndroidConsistent = $true
        RuntimeRunning = $true
        CellularState = 'ADMITTED'
        CellularReason = 'NONE'
        CellularAdmitted = $true
        CellularBoundaryFailure = ''
        RootAuthorityObservation = 'READY_AT_POLICY_AUTHORIZATION'
        RootPolicyAuthorized = $true
        ProxyState = 'RUNNING'
        ProxyHealthy = $true
        ProxyFailure = ''
        CredentialActive = $true
        CredentialLeaseStatus = 'AVAILABLE'
        MeshState = 'ADMITTED'
        MeshAdmitted = $true
        MeshEpochPresent = $true
        MeshIngressRunning = $true
        MeshIngressFailure = 'NONE'
        ReadinessState = 'READY'
        ReadinessBindingEligible = $true
        ReadinessProbeState = 'SUCCEEDED'
        LoopbackResult = 'PASS'
        LoopbackReason = 'NONE'
        MeshEndpointCount = 1
        RoutePresent = $true
        Tcp3128 = $true
        MeshProbeResult = 'PASS'
        MeshProbeReason = 'NONE'
    }

    $case = $base.Clone()
    $case.ProxyState = 'FAILED'
    $case.ProxyHealthy = $false
    $case.ProxyFailure = 'MIXED_LISTENER_UNAVAILABLE'
    $case.CellularState = 'BOUNDARY_UNAVAILABLE'
    $case.CellularAdmitted = $false
    $case.RootAuthorityObservation = 'NOT_OBSERVED'
    $case.RootPolicyAuthorized = $false
    $case.CredentialActive = $false
    $case.CredentialLeaseStatus = 'NOT_ATTEMPTED'
    $case.MeshState = 'ABSENT'
    $case.MeshAdmitted = $false
    $case.MeshEpochPresent = $false
    $case.MeshIngressRunning = $false
    $case.ReadinessState = 'NOT_READY'
    $case.ReadinessBindingEligible = $false
    $case.ReadinessProbeState = 'BLOCKED'
    $observed = Get-MishDeviceDiagnosticClassification @case
    if ($observed -cne 'PRODUCT_PROXY_MIXED_LISTENER_UNAVAILABLE') {
        throw "Terminal current Proxy Serving failure was masked by downstream non-observation: $observed"
    }

    $case = $base.Clone(); $case.RuntimeRunning = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_RUNTIME_NOT_RUNNING') { throw 'Stopped current native runtime was not attributed to the runtime owner.' }
    $case = $base.Clone(); $case.RootAuthorityObservation = 'UNAVAILABLE'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_ROOT_AUTHORITY_UNAVAILABLE') { throw 'Root authority failure was not attributed to the root authority boundary.' }
    $case = $base.Clone(); $case.CellularBoundaryFailure = 'NetworkHandleUnavailable'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_CELLULAR_BOUNDARY_NetworkHandleUnavailable') { throw 'Typed Cellular boundary failure was not preserved.' }
    $case = $base.Clone(); $case.CellularAdmitted = $false; $case.CellularState = 'REJECTED'; $case.CellularReason = 'NO_VALIDATED_CELLULAR'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_CELLULAR_REJECTED_NO_VALIDATED_CELLULAR') { throw 'Current Cellular admission failure was not attributed to Cellular Egress.' }
    $case = $base.Clone(); $case.RootPolicyAuthorized = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_ROOT_POLICY_NOT_AUTHORIZED') { throw 'Root policy authorization failure was not distinguished from root authority.' }
    $case = $base.Clone(); $case.ProxyHealthy = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_PROXY_SERVING_UNHEALTHY') { throw 'Native Proxy Serving health failure was not attributed to Proxy Serving.' }
    $case = $base.Clone(); $case.CredentialActive = $false; $case.CredentialLeaseStatus = 'NOT_ATTEMPTED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_CREDENTIAL_INACTIVE') { throw 'Inactive PRODUCT credential was not distinguished from a LAB lease failure.' }
    $case = $base.Clone(); $case.CredentialLeaseStatus = 'PROVISIONING_FAILED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'LAB_CREDENTIAL_PROVISIONING_FAILED') { throw 'LAB credential provisioning failure was not attributed to LAB.' }
    $case = $base.Clone(); $case.MeshAdmitted = $false; $case.MeshState = 'NOT_ADMITTED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_MESH_NOT_ADMITTED_NOT_ADMITTED') { throw 'Current Mesh admission failure was not attributed to Mesh.' }
    $case = $base.Clone(); $case.MeshEpochPresent = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_MESH_ADMISSION_EPOCH_MISSING') { throw 'Missing Mesh admission epoch was not distinguished from external Mesh reachability.' }
    $case = $base.Clone(); $case.MeshIngressRunning = $false; $case.MeshIngressFailure = 'LISTENER_UNAVAILABLE'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_MESH_INGRESS_LISTENER_UNAVAILABLE') { throw 'Mesh ingress owner failure was not preserved.' }
    $case = $base.Clone(); $case.ReadinessBindingEligible = $false
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'READINESS_BINDING_INELIGIBLE') { throw 'Readiness structural binding failure was not distinguished from the probe result.' }
    $case = $base.Clone(); $case.ReadinessProbeState = 'FAILED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'READINESS_PROBE_FAILED') { throw 'Current readiness probe state was not preserved.' }
    $case = $base.Clone(); $case.LoopbackResult = 'FAIL'; $case.LoopbackReason = 'AUTHENTICATION_FAILED'
    if ((Get-MishDeviceDiagnosticClassification @case) -cne 'PRODUCT_LOOPBACK_E2E_AUTHENTICATION_FAILED') { throw 'External loopback E2E failure was not preserved.' }
    if ((Get-MishDeviceDiagnosticClassification @base) -cne 'PASS') { throw 'Healthy current L8 fact set did not classify PASS.' }

    $reportScript = Join-Path $PSScriptRoot 'new-device-cycle-report.ps1'
    $controlSha = '1' * 40
    $passDiagnostic = Join-Path $root 'pass-diagnostic.json'
    [ordered]@{ classification = 'PASS'; collection_result = 'PASS'; schema = 'mish.lab.diagnostic/v2' } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $passDiagnostic

    $report = & $reportScript -Mode full -PrNumber 197 -SourceSha ('a' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe none -OutputPath (Join-Path $root 'pass-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$report.cycle_result -cne 'PASS' -or [string]$report.acceptance_scope -cne 'FULL_BASELINE' -or [string]$report.exact_candidate_acceptance -cne 'PASS' -or [bool]$report.targeted_probe.automatic -ne $false) {
        throw 'Full PASS report must accept the exact current candidate and contain no automatic probe decision.'
    }

    $productDiagnostic = Join-Path $root 'product-diagnostic.json'
    [ordered]@{ schema = 'mish.lab.diagnostic/v2'; classification = 'PRODUCT_PROXY_MIXED_LISTENER_UNAVAILABLE'; collection_result = 'PASS' } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $productDiagnostic
    $productReport = & $reportScript -Mode full -PrNumber 197 -SourceSha ('b' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $productDiagnostic -RequestedProbe none -OutputPath (Join-Path $root 'product-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$productReport.cycle_result -cne 'PRODUCT_FAIL' -or [string]$productReport.classification -cne 'PRODUCT_PROXY_MIXED_LISTENER_UNAVAILABLE' -or [string]$productReport.exact_candidate_acceptance -cne 'FAIL') {
        throw 'Current native PRODUCT diagnostic classification and exact candidate rejection were not preserved.'
    }

    $launchFailure = Join-Path $root 'launch-failure.json'
    [ordered]@{ schema = 'mish.device-start/v1'; result = 'FAIL'; failure_category = 'PROCESS_NOT_STABLE' } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $launchFailure
    $launchFailureReport = & $reportScript -Mode full -PrNumber 197 -SourceSha ('c' * 40) -ControlSha $controlSha -LaunchReceiptPath $launchFailure -RequestedProbe none -OutputPath (Join-Path $root 'launch-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$launchFailureReport.cycle_result -cne 'LAB_FAIL' -or [string]$launchFailureReport.classification -cne 'LAB_LAUNCH_PROCESS_NOT_STABLE' -or [string]$launchFailureReport.exact_candidate_acceptance -cne 'NOT_EVALUATED') {
        throw 'Typed launcher failure must remain a LAB failure and cannot reject the PRODUCT candidate.'
    }

    $missingProbe = & $reportScript -Mode probe_only -PrNumber 197 -SourceSha ('d' * 40) -ControlSha $controlSha -RequestedProbe loopback_connect -OutputPath (Join-Path $root 'missing-probe-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$missingProbe.cycle_result -cne 'LAB_FAIL' -or [string]$missingProbe.classification -cne 'LAB_TARGETED_PROBE_COLLECTION_FAILED' -or [string]$missingProbe.exact_candidate_acceptance -cne 'NOT_EVALUATED') {
        throw 'Explicit current-function probe without evidence must fail closed without evaluating PRODUCT.'
    }

    $loopbackPassPath = Join-Path $root 'loopback-pass.json'
    [ordered]@{
        schema = 'mish.lab.loopback-connect-diagnostic/v1'
        classification = 'U2_PROXY_PROTOCOL_MATRIX_PASS'
        pid_stable = $true
        protocol_matrix_pass = $true
        connect_probe = [ordered]@{ result = 'PASS'; reason = 'NONE' }
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $loopbackPassPath
    $probeReport = & $reportScript -Mode probe_only -PrNumber 197 -SourceSha ('e' * 40) -ControlSha $controlSha -RequestedProbe loopback_connect -TargetedEvidencePath $loopbackPassPath -OutputPath (Join-Path $root 'probe-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$probeReport.cycle_result -cne 'PASS' -or [string]$probeReport.classification -cne 'U2_PROXY_PROTOCOL_MATRIX_PASS' -or [string]$probeReport.targeted_probe.acceptance_result -cne 'PASS' -or [string]$probeReport.exact_candidate_acceptance -cne 'NOT_EVALUATED') {
        throw 'Loopback probe PASS must require real protocol evidence and cannot claim exact PRODUCT acceptance.'
    }

    $loopbackFailPath = Join-Path $root 'loopback-fail.json'
    [ordered]@{
        schema = 'mish.lab.loopback-connect-diagnostic/v1'
        classification = 'U2_PROXY_PROTOCOL_MATRIX_FAILED'
        pid_stable = $true
        protocol_matrix_pass = $false
        connect_probe = [ordered]@{ result = 'PASS'; reason = 'NONE' }
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $loopbackFailPath
    $probeFailReport = & $reportScript -Mode probe_only -PrNumber 197 -SourceSha ('f' * 40) -ControlSha $controlSha -RequestedProbe loopback_connect -TargetedEvidencePath $loopbackFailPath -OutputPath (Join-Path $root 'probe-fail-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$probeFailReport.cycle_result -cne 'PRODUCT_FAIL' -or [string]$probeFailReport.targeted_probe.acceptance_result -cne 'FAIL') {
        throw 'A collected but failing loopback matrix must not be promoted to a green probe.'
    }

    $dnsObservationPath = Join-Path $root 'dns-lifetime-live-pass.json'
    [ordered]@{
        schema = 'mish.lab.dns-lifetime-live/v1'
        collection_result = 'PASS'
        acceptance_result = 'PASS'
        observation_only = $true
        classification = 'U3_DNS_LIFETIME_LIVE_OBSERVATION_COMPLETE'
        same_process = $true
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $dnsObservationPath
    $dnsObservation = & $reportScript -Mode full -PrNumber 251 -SourceSha ('5' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe dns_lifetime_live -TargetedEvidencePath $dnsObservationPath -OutputPath (Join-Path $root 'dns-lifetime-live-pass-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$dnsObservation.cycle_result -cne 'PASS' -or
        [string]$dnsObservation.classification -cne 'U3_DNS_LIFETIME_LIVE_OBSERVATION_COMPLETE' -or
        [string]$dnsObservation.acceptance_scope -cne 'FULL_BASELINE_PLUS_DNS_LIFETIME_OBSERVATION' -or
        [string]$dnsObservation.targeted_probe.acceptance_result -cne 'PASS' -or
        [string]$dnsObservation.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'DNS lifetime observation PASS must remain measurement-only and never claim exact PRODUCT acceptance.'
    }

    $dnsLabPath = Join-Path $root 'dns-lifetime-live-lab-fail.json'
    [ordered]@{
        schema = 'mish.lab.dns-lifetime-live/v1'
        collection_result = 'FAIL'
        acceptance_result = 'FAIL'
        observation_only = $true
        classification = 'LAB_DNS_LIFETIME_TARGET_NOT_EXERCISED'
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $dnsLabPath
    $dnsLab = & $reportScript -Mode full -PrNumber 251 -SourceSha ('6' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe dns_lifetime_live -TargetedEvidencePath $dnsLabPath -OutputPath (Join-Path $root 'dns-lifetime-live-lab-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$dnsLab.cycle_result -cne 'LAB_FAIL' -or
        [string]$dnsLab.classification -cne 'LAB_DNS_LIFETIME_TARGET_NOT_EXERCISED' -or
        [string]$dnsLab.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'DNS lifetime collection failure must remain LAB-only and cannot reject PRODUCT.'
    }

    $dnsBaselineFailure = & $reportScript -Mode full -PrNumber 251 -SourceSha ('7' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $productDiagnostic -RequestedProbe dns_lifetime_live -TargetedEvidencePath $dnsObservationPath -OutputPath (Join-Path $root 'dns-lifetime-live-product-baseline-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$dnsBaselineFailure.cycle_result -cne 'PRODUCT_FAIL' -or
        [string]$dnsBaselineFailure.classification -cne 'PRODUCT_PROXY_MIXED_LISTENER_UNAVAILABLE' -or
        [string]$dnsBaselineFailure.exact_candidate_acceptance -cne 'FAIL'
    ) {
        throw 'A baseline PRODUCT failure must still outrank measurement-only DNS evidence.'
    }

    $capacityPassPath = Join-Path $root 'capacity-pass.json'
    [ordered]@{ schema = 'mish.lab.capacity-resources/v1'; acceptance_result = 'PASS'; classification = 'U2_CAPACITY_AND_RESOURCE_MEASUREMENTS_PASS' } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $capacityPassPath
    $capacityPass = & $reportScript -Mode full -PrNumber 208 -SourceSha ('1' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe capacity_resources -TargetedEvidencePath $capacityPassPath -OutputPath (Join-Path $root 'capacity-pass-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$capacityPass.cycle_result -cne 'PASS' -or [string]$capacityPass.acceptance_scope -cne 'FULL_BASELINE_PLUS_CAPACITY_RESOURCES' -or [string]$capacityPass.exact_candidate_acceptance -cne 'PASS' -or [string]$capacityPass.targeted_probe.acceptance_result -cne 'PASS') {
        throw 'Full capacity PASS must require baseline + targeted acceptance and accept the exact candidate.'
    }

    $capacityFailPath = Join-Path $root 'capacity-fail.json'
    [ordered]@{ schema = 'mish.lab.capacity-resources/v1'; acceptance_result = 'FAIL'; classification = 'U2_CAPACITY_65TH_NOT_REJECTED' } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $capacityFailPath
    $capacityFail = & $reportScript -Mode full -PrNumber 208 -SourceSha ('2' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe capacity_resources -TargetedEvidencePath $capacityFailPath -OutputPath (Join-Path $root 'capacity-fail-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$capacityFail.cycle_result -cne 'PRODUCT_FAIL' -or [string]$capacityFail.classification -cne 'U2_CAPACITY_65TH_NOT_REJECTED' -or [string]$capacityFail.exact_candidate_acceptance -cne 'FAIL') {
        throw 'A real capacity failure must reject the exact PRODUCT candidate.'
    }

    $capacityLabPath = Join-Path $root 'capacity-lab.json'
    [ordered]@{ schema = 'mish.lab.capacity-resources/v1'; acceptance_result = 'FAIL'; classification = 'LAB_RESOURCE_POST_CLEANUP_UNAVAILABLE' } | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 -LiteralPath $capacityLabPath
    $capacityLab = & $reportScript -Mode full -PrNumber 208 -SourceSha ('3' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe capacity_resources -TargetedEvidencePath $capacityLabPath -OutputPath (Join-Path $root 'capacity-lab-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$capacityLab.cycle_result -cne 'LAB_FAIL' -or [string]$capacityLab.exact_candidate_acceptance -cne 'NOT_EVALUATED') {
        throw 'LAB resource collection failure must not reject PRODUCT.'
    }

    $baselineWins = & $reportScript -Mode full -PrNumber 208 -SourceSha ('4' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $productDiagnostic -RequestedProbe capacity_resources -OutputPath (Join-Path $root 'baseline-wins.json') | Select-Object -Last 1 | ConvertFrom-Json
    if ([string]$baselineWins.cycle_result -cne 'PRODUCT_FAIL' -or [string]$baselineWins.classification -cne 'PRODUCT_PROXY_MIXED_LISTENER_UNAVAILABLE') {
        throw 'Baseline PRODUCT failure must outrank absent capacity evidence.'
    }

    $rotationPassPath = Join-Path $root 'u5-rotation-pass.json'
    [ordered]@{
        schema = 'mish.lab.u5-rotation-acceptance/v1'
        acceptance_result = 'PASS'
        classification = 'U5_ROTATION_PHYSICAL_ACCEPTANCE_PASS'
        raw_ip_persisted = $false
        credential = [ordered]@{ version_unchanged = $true; material_unchanged = $true }
    } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 -LiteralPath $rotationPassPath
    $rotationPass = & $reportScript -Mode full -PrNumber 269 -SourceSha ('8' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe u5_rotation -TargetedEvidencePath $rotationPassPath -OutputPath (Join-Path $root 'u5-rotation-pass-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$rotationPass.cycle_result -cne 'PASS' -or
        [string]$rotationPass.classification -cne 'U5_ROTATION_PHYSICAL_ACCEPTANCE_PASS' -or
        [string]$rotationPass.acceptance_scope -cne 'FULL_BASELINE_PLUS_U5_ROTATION' -or
        [string]$rotationPass.exact_candidate_acceptance -cne 'PASS'
    ) {
        throw 'U5 rotation PASS must accept the exact candidate only with baseline + targeted physical evidence.'
    }

    $rotationProductPath = Join-Path $root 'u5-rotation-product-fail.json'
    [ordered]@{
        schema = 'mish.lab.u5-rotation-acceptance/v1'
        acceptance_result = 'FAIL'
        classification = 'PRODUCT_ROTATION_FAILED'
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $rotationProductPath
    $rotationProduct = & $reportScript -Mode full -PrNumber 269 -SourceSha ('9' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe u5_rotation -TargetedEvidencePath $rotationProductPath -OutputPath (Join-Path $root 'u5-rotation-product-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$rotationProduct.cycle_result -cne 'PRODUCT_FAIL' -or
        [string]$rotationProduct.classification -cne 'PRODUCT_ROTATION_FAILED' -or
        [string]$rotationProduct.exact_candidate_acceptance -cne 'FAIL'
    ) {
        throw 'Observed U5 rotation PRODUCT failure must reject the exact candidate.'
    }

    $rotationLabPath = Join-Path $root 'u5-rotation-lab-fail.json'
    [ordered]@{
        schema = 'mish.lab.u5-rotation-acceptance/v1'
        acceptance_result = 'FAIL'
        classification = 'LAB_ADB_FAILED'
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $rotationLabPath
    $rotationLab = & $reportScript -Mode full -PrNumber 269 -SourceSha ('a' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe u5_rotation -TargetedEvidencePath $rotationLabPath -OutputPath (Join-Path $root 'u5-rotation-lab-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$rotationLab.cycle_result -cne 'LAB_FAIL' -or
        [string]$rotationLab.classification -cne 'LAB_ADB_FAILED' -or
        [string]$rotationLab.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'LAB U5 rotation collection failure must not reject the PRODUCT candidate.'
    }

    $restartPassPath = Join-Path $root 'u7-runtime-restart-pass.json'
    [ordered]@{
        schema = 'mish.lab.u7-runtime-restart-resources/v1'
        acceptance_result = 'PASS'
        classification = 'U7_RUNTIME_RESTART_RESOURCES_PASS'
        cycles_requested = 3
        cycles_completed = 3
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $restartPassPath
    $restartPass = & $reportScript -Mode full -PrNumber 301 -SourceSha ('b' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe u7_runtime_restart_resources -TargetedEvidencePath $restartPassPath -OutputPath (Join-Path $root 'u7-runtime-restart-pass-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$restartPass.cycle_result -cne 'PASS' -or
        [string]$restartPass.classification -cne 'U7_RUNTIME_RESTART_RESOURCES_PASS' -or
        [string]$restartPass.acceptance_scope -cne 'FULL_BASELINE_PLUS_U7_RUNTIME_RESTART_RESOURCES' -or
        [string]$restartPass.exact_candidate_acceptance -cne 'PASS'
    ) {
        throw 'U7 runtime restart resource PASS must accept the exact candidate only with baseline + targeted evidence.'
    }

    $restartProductPath = Join-Path $root 'u7-runtime-restart-product-fail.json'
    [ordered]@{
        schema = 'mish.lab.u7-runtime-restart-resources/v1'
        acceptance_result = 'FAIL'
        classification = 'PRODUCT_RESTART_RESOURCE_NOT_QUIESCENT'
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $restartProductPath
    $restartProduct = & $reportScript -Mode full -PrNumber 301 -SourceSha ('c' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe u7_runtime_restart_resources -TargetedEvidencePath $restartProductPath -OutputPath (Join-Path $root 'u7-runtime-restart-product-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$restartProduct.cycle_result -cne 'PRODUCT_FAIL' -or
        [string]$restartProduct.classification -cne 'PRODUCT_RESTART_RESOURCE_NOT_QUIESCENT' -or
        [string]$restartProduct.exact_candidate_acceptance -cne 'FAIL'
    ) {
        throw 'Observed U7 runtime restart resource PRODUCT failure must reject the exact candidate.'
    }

    $restartLabPath = Join-Path $root 'u7-runtime-restart-lab-fail.json'
    [ordered]@{
        schema = 'mish.lab.u7-runtime-restart-resources/v1'
        acceptance_result = 'FAIL'
        classification = 'LAB_ADB_FAILED'
    } | ConvertTo-Json -Depth 5 | Set-Content -Encoding UTF8 -LiteralPath $restartLabPath
    $restartLab = & $reportScript -Mode full -PrNumber 301 -SourceSha ('d' * 40) -ControlSha $controlSha -DiagnosticEvidencePath $passDiagnostic -RequestedProbe u7_runtime_restart_resources -TargetedEvidencePath $restartLabPath -OutputPath (Join-Path $root 'u7-runtime-restart-lab-report.json') | Select-Object -Last 1 | ConvertFrom-Json
    if (
        [string]$restartLab.cycle_result -cne 'LAB_FAIL' -or
        [string]$restartLab.classification -cne 'LAB_ADB_FAILED' -or
        [string]$restartLab.exact_candidate_acceptance -cne 'NOT_EVALUATED'
    ) {
        throw 'LAB U7 runtime restart collection failure must not reject the PRODUCT candidate.'
    }

    Write-Host 'DEVICE_CYCLE_CONTRACT=PASS'
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue
}

exit 0