$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourcePath = Join-Path $PSScriptRoot 'diagnose-capacity-resources.ps1'
$measurementPath = Join-Path $PSScriptRoot 'U7Measurement.psm1'

foreach ($path in @($sourcePath, $measurementPath)) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        $path,
        [ref]$tokens,
        [ref]$errors
    )
    if ($errors.Count -ne 0) {
        $errors | ForEach-Object { Write-Error $_.Message }
        throw "U7 capacity/resource PowerShell parse failed: $path"
    }
}

$source = Get-Content -Raw -LiteralPath $sourcePath
foreach ($required in @(
    'Import-Module (Join-Path $PSScriptRoot ''U7Measurement.psm1'') -Force',
    'function Open-MishApplicationSession',
    'function Invoke-MishApplicationRoundTrip',
    'function Test-MishApplicationLiveSet',
    'function Add-MishApplicationSessionsUntil',
    '[Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]] $Sessions',
    '[Net.Security.SslStream]::new($stream, $false)',
    '$tlsStream.AuthenticateAsClient($TargetHost)',
    'HEAD / HTTP/1.1',
    'Connection: keep-alive',
    "HeldProtocol = 'TLS+HTTP'",
    'MeshConnectElapsedMs = $meshConnectElapsedMs',
    'SetupElapsedMs = [int64]$setupWatch.ElapsedMilliseconds',
    'application_round_trip_latency = Get-MishU7LatencyDistribution',
    "acceptance_profile = 'u7-baseline-v1'",
    "batch_model = 'independent_bounded'",
    "measurement_stage = 'U7'",
    'foreach ($target in @(10, 32, 64))',
    'Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target',
    '$applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target',
    '$ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target',
    'Measure-MishU7SupplementalObservation -AdbPath $AdbPath -PackageName $PackageName -PidText $pidBefore',
    'Get-MishSafeOwnerDiagnostics',
    '$stageRecord[''cleanup''] = [ordered]@{',
    'resource_delta_from_idle = if ($null -ne $stageCleanupResources)',
    '$attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease',
    'ordinal = 65',
    '$postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64',
    '$overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64',
    "'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'",
    "'LAB_APPLICATION_LIVE_POST_OVERFLOW_FAILED'",
    "'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'",
    "'U2_CAPACITY_OWNER_COUNT_MISMATCH'",
    "schema = 'mish.lab.capacity-resources/v1'",
    "application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'",
    'pre_overflow_application_liveness = $preOverflowLiveness',
    'post_cleanup_mesh_e2e = $postCleanupMeshE2e'
)) {
    if (-not $source.Contains($required)) {
        throw "Capacity/resource probe lost U7 bounded baseline semantics: $required"
    }
}

foreach ($forbidden in @(
    '$held',
    'Open-MishFreshApplicationSet',
    'fresh_batch = $true',
    'openingLiveness',
    '($ordinal % 8)',
    'foreach ($checkpoint',
    'soak_checkpoints',
    '65..80',
    '[Parameter(Mandatory)][Collections.Generic.List[object]] $Sessions',
    "reason = 'CONNECT_TIMEOUT_BEFORE_ADMISSION'"
)) {
    if ($source.Contains($forbidden)) {
        throw "Capacity/resource probe regressed to redundant/stale capacity semantics: $forbidden"
    }
}

$measurement = Get-Content -Raw -LiteralPath $measurementPath
foreach ($required in @(
    'function Get-MishU7CpuObservation',
    'process_cpu_percent_total_capacity',
    'process_cpu_percent_one_core_equivalent',
    'voluntary_context_switches_delta',
    'wakeups_supported = $false',
    "'dumpsys', 'battery'",
    "'dumpsys', 'thermalservice'",
    "'ps', '-A', '-o', 'PID,PPID,NAME'",
    "'ps', '-A', '-T', '-w', '-o', 'PID,TID,CMD'",
    "'mish-runtime-i*'",
    'external_powered = $externalPower',
    'product_su_like_descendants',
    'Export-ModuleMember -Function Get-MishU7LatencyDistribution, Measure-MishU7SupplementalObservation'
)) {
    if (-not $measurement.Contains($required)) {
        throw "U7 measurement helper lost bounded observation semantics: $required"
    }
}

foreach ($forbidden in @(
    "'shell', 'su'",
    "'shell', 'kill'",
    "'shell', 'pkill'",
    'settings put',
    'airplane-mode',
    'ProcessBuilder',
    'tokio::runtime'
)) {
    if ($measurement.Contains($forbidden)) {
        throw "U7 measurement helper became a mutation/PRODUCT execution path: $forbidden"
    }
}

$tlsHandshake = $source.IndexOf('$tlsStream.AuthenticateAsClient($TargetHost)', [StringComparison]::Ordinal)
$sessionReturn = $source.IndexOf("HeldProtocol = 'TLS+HTTP'", [StringComparison]::Ordinal)
if ($tlsHandshake -lt 0 -or $sessionReturn -lt 0 -or $tlsHandshake -gt $sessionReturn) {
    throw 'A capacity session must complete target TLS before it can be returned.'
}

$stageOpen = $source.LastIndexOf('Add-MishApplicationSessionsUntil -ProxyHost $meshAddress -Lease $lease -Sessions $activeSessions -ExpectedSessions $target', [StringComparison]::Ordinal)
$stageLive = $source.LastIndexOf('$applicationLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions $target', [StringComparison]::Ordinal)
$ownerSample = $source.LastIndexOf('$ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target', [StringComparison]::Ordinal)
if ($stageOpen -lt 0 -or $stageLive -lt 0 -or $ownerSample -lt 0 -or $stageOpen -gt $stageLive -or $stageLive -gt $ownerSample) {
    throw 'Each capacity milestone must establish sessions, prove application liveness, then sample owner counts.'
}

$overflowAttempt = $source.LastIndexOf('$attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease', [StringComparison]::Ordinal)
$postOverflowLive = $source.LastIndexOf('$postOverflowLiveness = Test-MishApplicationLiveSet -Sessions @($activeSessions) -ExpectedSessions 64', [StringComparison]::Ordinal)
$postOverflowOwners = $source.LastIndexOf('$overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64', [StringComparison]::Ordinal)
if ($overflowAttempt -lt 0 -or $postOverflowLive -lt 0 -or $postOverflowOwners -lt 0 -or $overflowAttempt -gt $postOverflowLive -or $postOverflowLive -gt $postOverflowOwners) {
    throw 'The single 65th overflow attempt must be followed by application-liveness re-proof of the original 64 and owner counts.'
}

Write-Host 'CAPACITY_PROBE_CONTRACT=PASS'
