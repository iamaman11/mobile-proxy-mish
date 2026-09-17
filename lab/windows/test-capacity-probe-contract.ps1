$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourcePath = Join-Path $PSScriptRoot 'diagnose-capacity-resources.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $sourcePath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'Capacity/resource probe PowerShell parse failed.'
}

$source = Get-Content -Raw -LiteralPath $sourcePath
foreach ($required in @(
    'function Open-MishApplicationSession',
    'function Invoke-MishApplicationRoundTrip',
    'function Test-MishApplicationLiveSet',
    'function Open-MishFreshApplicationSet',
    '[Net.Security.SslStream]::new($stream, $false)',
    '$tlsStream.AuthenticateAsClient($TargetHost)',
    'HEAD / HTTP/1.1',
    'Connection: keep-alive',
    "HeldProtocol = 'TLS+HTTP'",
    'fresh_batch = $true',
    'foreach ($target in @(10, 32, 64))',
    'Open-MishFreshApplicationSet -ProxyHost $meshAddress -Lease $lease -ExpectedSessions $target',
    'Wait-MishOwnerCounts -ExpectedMesh 0 -ExpectedProxy 0',
    'foreach ($checkpoint in @(10, 20, 30, 45, 60, 90))',
    'Test-MishApplicationLiveSet -Sessions $activeSessions -ExpectedSessions 64',
    'foreach ($overflowOrdinal in 65..80)',
    '$attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease',
    '$postOverflowLiveness = Test-MishApplicationLiveSet -Sessions $activeSessions -ExpectedSessions 64',
    '$overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64',
    "'LAB_APPLICATION_LIVE_PRECONDITION_FAILED'",
    "'LAB_APPLICATION_LIVENESS_SOAK_FAILED'",
    "'LAB_OVERFLOW_OBSERVATION_INCONCLUSIVE'",
    "'U2_CAPACITY_OWNER_COUNT_MISMATCH'",
    "schema = 'mish.lab.capacity-resources/v1'",
    "application_live_semantics = 'fresh HTTP HEAD round-trip on the same established TLS connection'",
    'post_cleanup_mesh_e2e = $postCleanupMeshE2e'
)) {
    if (-not $source.Contains($required)) {
        throw "Capacity/resource probe lost application-live U2 semantics: $required"
    }
}

foreach ($forbidden in @(
    '$held',
    'while ($held.Count -lt $target)',
    "reason = 'CONNECT_TIMEOUT_BEFORE_ADMISSION'"
)) {
    if ($source.Contains($forbidden)) {
        throw "Capacity/resource probe regressed to stale/ambiguous capacity semantics: $forbidden"
    }
}

$tlsHandshake = $source.IndexOf('$tlsStream.AuthenticateAsClient($TargetHost)', [StringComparison]::Ordinal)
$sessionReturn = $source.IndexOf("HeldProtocol = 'TLS+HTTP'", [StringComparison]::Ordinal)
if ($tlsHandshake -lt 0 -or $sessionReturn -lt 0 -or $tlsHandshake -gt $sessionReturn) {
    throw 'A capacity session must complete target TLS before it can be returned.'
}

$mainStageOpen = $source.LastIndexOf('Open-MishFreshApplicationSet -ProxyHost $meshAddress -Lease $lease -ExpectedSessions $target', [StringComparison]::Ordinal)
$ownerSample = $source.LastIndexOf('$ownerCounts = Wait-MishOwnerCounts -ExpectedMesh $target -ExpectedProxy $target', [StringComparison]::Ordinal)
if ($mainStageOpen -lt 0 -or $ownerSample -lt 0 -or $mainStageOpen -gt $ownerSample) {
    throw 'Each fresh stage must establish application-live client sessions before owner-count acceptance.'
}

$overflowAttempt = $source.LastIndexOf('$attempt = Test-MishOverflowRejected -ProxyHost $meshAddress -Lease $lease', [StringComparison]::Ordinal)
$postOverflowLive = $source.LastIndexOf('$postOverflowLiveness = Test-MishApplicationLiveSet -Sessions $activeSessions -ExpectedSessions 64', [StringComparison]::Ordinal)
$postOverflowOwners = $source.LastIndexOf('$overflowOwnerCounts = Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64', [StringComparison]::Ordinal)
if ($overflowAttempt -lt 0 -or $postOverflowLive -lt 0 -or $postOverflowOwners -lt 0 -or $overflowAttempt -gt $postOverflowLive -or $postOverflowLive -gt $postOverflowOwners) {
    throw 'Overflow must be followed by application-liveness re-proof of the original 64 before owner-count verdict.'
}

Write-Host 'CAPACITY_PROBE_CONTRACT=PASS'
