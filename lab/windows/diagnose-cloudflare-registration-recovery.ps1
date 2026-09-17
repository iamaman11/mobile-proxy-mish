[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{32}$')][string] $AccountId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string] $RegistrationId,
    [string] $ApiTokenEnvironmentVariable = 'MISH_CF_REGISTRATION_TOKEN',
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [string] $ExpectedClientVersion = '2.5.5',
    [string] $ExpectedPolicyName = 'adds-android-mesh',
    [ValidateRange(1, 100)][int] $ExpectedRegistrationCount = 4,
    [ValidateRange(5, 300)][int] $LossWindowSeconds = 60,
    [ValidateRange(5, 300)][int] $RecoveryWindowSeconds = 90,
    [ValidateRange(1, 15)][int] $SnapshotTimeoutSeconds = 3,
    [ValidateRange(1, 30)][int] $ApiTimeoutSeconds = 10,
    [string] $PostRecoveryDiagnosticPath = (Join-Path $env:TEMP 'mish-registration-recovery-diagnostic.json'),
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-cloudflare-registration-recovery-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.cloudflare-registration-recovery/v1'
$script:SnapshotMethod = 'snapshot_v2'
$script:PollMs = 250
$script:SnapshotPollMs = 2000
$script:ApiRoot = "https://api.cloudflare.com/client/v4/accounts/$AccountId/devices/registrations"

function Stop-MishProbe {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_REGISTRATION_RECOVERY_FAILURE|$Classification|$Message"
}

function Get-MishProperty {
    param(
        $Object,
        [Parameter(Mandatory)][string] $Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Invoke-MishProcess {
    param(
        [Parameter(Mandatory)][string] $FilePath,
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 30
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { [void]$start.ArgumentList.Add($argument) }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        return [pscustomobject]@{ ExitCode = -1; StdOut = ''; StdErr = 'process start failed'; TimedOut = $false }
    }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            try { [void]$process.WaitForExit(2000) } catch { }
            return [pscustomobject]@{
                ExitCode = -1
                StdOut = ''
                StdErr = 'bounded subprocess timeout'
                TimedOut = $true
            }
        }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            StdOut = $stdoutTask.GetAwaiter().GetResult()
            StdErr = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $false
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-MishAdb {
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 10
    )
    Invoke-MishProcess -FilePath $AdbPath -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
}

function New-MishHttpClient {
    param([Parameter(Mandatory)][string] $Token)
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($ApiTimeoutSeconds)
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $Token)
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/json')
    return $client
}

function Invoke-MishCloudflare {
    param(
        [Parameter(Mandatory)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory)][ValidateSet('GET','POST')][string] $Method,
        [Parameter(Mandatory)][string] $Uri
    )

    try {
        if ($Method -ceq 'GET') {
            $response = $Client.GetAsync($Uri).GetAwaiter().GetResult()
        }
        else {
            $content = [Net.Http.StringContent]::new('')
            try { $response = $Client.PostAsync($Uri, $content).GetAwaiter().GetResult() }
            finally { $content.Dispose() }
        }
        try {
            $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            $json = $null
            try { $json = $body | ConvertFrom-Json } catch { }
            return [pscustomobject]@{
                HttpStatus = [int]$response.StatusCode
                SuccessStatus = [bool]$response.IsSuccessStatusCode
                Json = $json
                TransportError = $null
            }
        }
        finally { $response.Dispose() }
    }
    catch {
        return [pscustomobject]@{
            HttpStatus = 0
            SuccessStatus = $false
            Json = $null
            TransportError = $_.Exception.Message
        }
    }
}

function Get-MishRegistration {
    param(
        [Parameter(Mandatory)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory)][string] $Id
    )
    $escaped = [Uri]::EscapeDataString($Id)
    $response = Invoke-MishCloudflare -Client $Client -Method GET -Uri "$($script:ApiRoot)/$escaped?include=policy"
    if (-not $response.SuccessStatus -or $null -eq $response.Json -or -not [bool](Get-MishProperty $response.Json 'success')) {
        return $null
    }
    return Get-MishProperty $response.Json 'result'
}

function Get-MishRegistrations {
    param([Parameter(Mandatory)][Net.Http.HttpClient] $Client)
    $response = Invoke-MishCloudflare -Client $Client -Method GET -Uri "$($script:ApiRoot)?status=all&per_page=100&include=policy"
    if (-not $response.SuccessStatus -or $null -eq $response.Json -or -not [bool](Get-MishProperty $response.Json 'success')) {
        return $null
    }
    return @(Get-MishProperty $response.Json 'result')
}

function Test-MishRegistrationActive {
    param($Registration)
    if ($null -eq $Registration) { return $false }
    return $null -eq (Get-MishProperty $Registration 'revoked_at') -and $null -eq (Get-MishProperty $Registration 'deleted_at')
}

function Test-MishRegistrationRevoked {
    param($Registration)
    if ($null -eq $Registration) { return $false }
    return $null -ne (Get-MishProperty $Registration 'revoked_at') -and $null -eq (Get-MishProperty $Registration 'deleted_at')
}

function Invoke-MishRegistrationMutation {
    param(
        [Parameter(Mandatory)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory)][ValidateSet('revoke','unrevoke')][string] $Action
    )
    $escaped = [Uri]::EscapeDataString($RegistrationId)
    $response = Invoke-MishCloudflare -Client $Client -Method POST -Uri "$($script:ApiRoot)/$Action?id=$escaped"
    return ($response.SuccessStatus -and $null -ne $response.Json -and [bool](Get-MishProperty $response.Json 'success'))
}

function Wait-MishRegistrationState {
    param(
        [Parameter(Mandatory)][Net.Http.HttpClient] $Client,
        [Parameter(Mandatory)][ValidateSet('active','revoked')][string] $State,
        [ValidateRange(1, 60)][int] $TimeoutSeconds = 20
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    do {
        $registration = Get-MishRegistration -Client $Client -Id $RegistrationId
        if ($State -ceq 'active' -and (Test-MishRegistrationActive $registration)) { return $registration }
        if ($State -ceq 'revoked' -and (Test-MishRegistrationRevoked $registration)) { return $registration }
        Start-Sleep -Milliseconds 500
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    return $null
}

function Test-MishIpv4InCidr {
    param(
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Cidr
    )
    try {
        $parts = $Cidr.Split('/')
        if ($parts.Count -ne 2) { return $false }
        $addressBytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
        $networkBytes = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $prefix = [int]$parts[1]
        if ($addressBytes.Length -ne 4 -or $networkBytes.Length -ne 4 -or $prefix -lt 0 -or $prefix -gt 32) { return $false }
        for ($index = 0; $index -lt 4; $index++) {
            $remaining = $prefix - ($index * 8)
            $bits = [Math]::Min(8, [Math]::Max(0, $remaining))
            if ($bits -eq 0) { continue }
            $mask = (0xff -shl (8 - $bits)) -band 0xff
            if ((([int]$addressBytes[$index]) -band $mask) -ne (([int]$networkBytes[$index]) -band $mask)) { return $false }
        }
        return $true
    }
    catch { return $false }
}

function Get-MishMeshAddresses {
    $result = Invoke-MishAdb -Arguments @('shell', 'ip', '-o', '-4', 'addr', 'show') -TimeoutSeconds 3
    if ($result.TimedOut -or $result.ExitCode -ne 0) {
        return [pscustomobject]@{ Available = $false; TimedOut = [bool]$result.TimedOut; Addresses = @() }
    }
    $addresses = @(
        [regex]::Matches($result.StdOut, '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/\d+') |
            ForEach-Object { $_.Groups['ip'].Value } |
            Where-Object { Test-MishIpv4InCidr -Address $_ -Cidr $MeshCidr } |
            Sort-Object -Unique
    )
    return [pscustomobject]@{ Available = $true; TimedOut = $false; Addresses = $addresses }
}

function Read-MishSnapshot {
    $result = Invoke-MishAdb -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    ) -TimeoutSeconds $SnapshotTimeoutSeconds
    if ($result.TimedOut) {
        return [pscustomobject]@{ Available = $false; TimedOut = $true; Value = $null }
    }
    if ($result.ExitCode -ne 0) {
        return [pscustomobject]@{ Available = $false; TimedOut = $false; Value = $null }
    }
    $match = [regex]::Match($result.StdOut, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) {
        return [pscustomobject]@{ Available = $false; TimedOut = $false; Value = $null }
    }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        $value = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
        return [pscustomobject]@{ Available = $true; TimedOut = $false; Value = $value }
    }
    catch {
        return [pscustomobject]@{ Available = $false; TimedOut = $false; Value = $null }
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function New-MishObservation {
    param(
        [Parameter(Mandatory)][Diagnostics.Stopwatch] $Watch,
        $SnapshotResult,
        [Parameter(Mandatory)] $MeshResult,
        [Parameter(Mandatory)][bool] $SnapshotFresh
    )
    $snapshot = if ($null -ne $SnapshotResult -and $SnapshotResult.Available) { $SnapshotResult.Value } else { $null }
    return [pscustomobject][ordered]@{
        elapsed_ms = [int64]$Watch.ElapsedMilliseconds
        mesh_observation_available = [bool]$MeshResult.Available
        mesh_observation_timeout = [bool]$MeshResult.TimedOut
        mesh_addresses = @($MeshResult.Addresses)
        snapshot_fresh = $SnapshotFresh
        snapshot_available = ($null -ne $snapshot)
        snapshot_timeout = if ($null -ne $SnapshotResult) { [bool]$SnapshotResult.TimedOut } else { $false }
        cellular_admitted = if ($null -ne $snapshot) { [bool]$snapshot.cellular.admitted } else { $null }
        mesh_admitted = if ($null -ne $snapshot) { [bool]$snapshot.mesh.admitted } else { $null }
        mesh_epoch_present = if ($null -ne $snapshot) { [bool]$snapshot.mesh.epoch_present } else { $null }
        mesh_ingress_running = if ($null -ne $snapshot) { [bool]$snapshot.mesh.ingress_running } else { $null }
        mesh_active_sessions = if ($null -ne $snapshot) { [int64]$snapshot.mesh.active_sessions } else { $null }
        readiness = if ($null -ne $snapshot) { [string]$snapshot.readiness.state } else { $null }
    }
}

function Wait-MishOwnerState {
    param(
        [Parameter(Mandatory)][ValidateSet('lost','ready')][string] $State,
        [Parameter(Mandatory)][int] $TimeoutSeconds,
        [Parameter(Mandatory)][Collections.Generic.List[object]] $Observations
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $lastSnapshot = $null
    $nextSnapshotMs = 0L
    $lastMeshCount = -1

    do {
        $mesh = Get-MishMeshAddresses
        $snapshotFresh = $false
        $needSnapshot = $watch.ElapsedMilliseconds -ge $nextSnapshotMs
        if ($mesh.Available -and $lastMeshCount -ge 0 -and @($mesh.Addresses).Count -ne $lastMeshCount) { $needSnapshot = $true }
        if ($mesh.Available) { $lastMeshCount = @($mesh.Addresses).Count }

        if ($needSnapshot) {
            $lastSnapshot = Read-MishSnapshot
            $snapshotFresh = $true
            $nextSnapshotMs = $watch.ElapsedMilliseconds + $script:SnapshotPollMs
        }

        $observation = New-MishObservation -Watch $watch -SnapshotResult $lastSnapshot -MeshResult $mesh -SnapshotFresh $snapshotFresh
        $Observations.Add($observation)

        if ($null -ne $lastSnapshot -and $lastSnapshot.Available) {
            $snapshot = $lastSnapshot.Value
            if (
                $State -ceq 'lost' -and
                [bool]$snapshot.consistent -and
                -not [bool]$snapshot.mesh.admitted -and
                -not [bool]$snapshot.mesh.epoch_present -and
                -not [bool]$snapshot.mesh.ingress_running -and
                [int64]$snapshot.mesh.active_sessions -eq 0
            ) {
                return [pscustomobject]@{ Observation = $observation; ElapsedMs = [int64]$watch.ElapsedMilliseconds }
            }
            if (
                $State -ceq 'ready' -and
                [bool]$snapshot.consistent -and
                [bool]$snapshot.cellular.admitted -and
                [bool]$snapshot.mesh.admitted -and
                [bool]$snapshot.mesh.epoch_present -and
                [bool]$snapshot.mesh.ingress_running -and
                [string]$snapshot.readiness.state -ceq 'READY' -and
                $mesh.Available -and @($mesh.Addresses).Count -eq 1
            ) {
                return [pscustomobject]@{ Observation = $observation; ElapsedMs = [int64]$watch.ElapsedMilliseconds }
            }
        }

        Start-Sleep -Milliseconds $script:PollMs
    } while ($watch.Elapsed.TotalSeconds -lt $TimeoutSeconds)

    return $null
}

function Compare-MishNonTargetRegistrations {
    param(
        [Parameter(Mandatory)][object[]] $Before,
        [Parameter(Mandatory)][object[]] $After
    )
    $beforeMap = @{}
    foreach ($item in $Before) {
        $id = [string](Get-MishProperty $item 'id')
        if ($id -cne $RegistrationId) {
            $beforeMap[$id] = [pscustomobject]@{
                revoked_at = Get-MishProperty $item 'revoked_at'
                deleted_at = Get-MishProperty $item 'deleted_at'
            }
        }
    }
    foreach ($item in $After) {
        $id = [string](Get-MishProperty $item 'id')
        if ($id -ceq $RegistrationId -or -not $beforeMap.ContainsKey($id)) { continue }
        $beforeState = $beforeMap[$id]
        if ([string]$beforeState.revoked_at -cne [string](Get-MishProperty $item 'revoked_at')) { return $false }
        if ([string]$beforeState.deleted_at -cne [string](Get-MishProperty $item 'deleted_at')) { return $false }
        $beforeMap.Remove($id)
    }
    return $beforeMap.Count -eq 0
}

function Invoke-MishGuaranteedUnrevoke {
    param([Parameter(Mandatory)][Net.Http.HttpClient] $Client)
    $mutationOk = Invoke-MishRegistrationMutation -Client $Client -Action unrevoke
    $active = Wait-MishRegistrationState -Client $Client -State active -TimeoutSeconds 30
    return [pscustomobject]@{
        mutation_success = $mutationOk
        active_confirmed = ($null -ne $active)
        registration = $active
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishProbe 'LAB_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

$token = [Environment]::GetEnvironmentVariable($ApiTokenEnvironmentVariable)
if ([string]::IsNullOrWhiteSpace($token)) {
    Stop-MishProbe 'LAB_CLOUDFLARE_TOKEN_MISSING' "Cloudflare API token is unavailable in the required environment variable."
}

$client = $null
$registrationMayBeRevoked = $false
$cleanupEvidence = [ordered]@{ attempted = $false; mutation_success = $false; active_confirmed = $false }
$acceptanceResult = 'FAIL'
$classification = 'LAB_REGISTRATION_RECOVERY_NOT_COMPLETED'
$primaryClassification = $classification
$baselineEvidence = [ordered]@{}
$lossEvidence = [ordered]@{}
$recoveryEvidence = [ordered]@{}
$scopeEvidence = [ordered]@{}
$lossObservations = [Collections.Generic.List[object]]::new()
$recoveryObservations = [Collections.Generic.List[object]]::new()
$registrationsBefore = @()

try {
    $client = New-MishHttpClient -Token $token

    $registrationsBefore = @(Get-MishRegistrations -Client $client)
    if ($registrationsBefore.Count -ne $ExpectedRegistrationCount) {
        Stop-MishProbe 'LAB_REGISTRATION_SCOPE_MISMATCH' 'Cloudflare registration count does not match the explicit LAB safety guard.'
    }
    $targetMatches = @($registrationsBefore | Where-Object { [string](Get-MishProperty $_ 'id') -ceq $RegistrationId })
    if ($targetMatches.Count -ne 1) {
        Stop-MishProbe 'LAB_TARGET_REGISTRATION_AMBIGUOUS' 'Exact Android registration was not resolved uniquely.'
    }
    $target = $targetMatches[0]
    $device = Get-MishProperty $target 'device'
    $policy = Get-MishProperty $target 'policy'
    if (
        [string](Get-MishProperty $device 'client_version') -cne $ExpectedClientVersion -or
        [string](Get-MishProperty $policy 'name') -cne $ExpectedPolicyName -or
        [string](Get-MishProperty $target 'registration_type') -cne 'warp' -or
        [string](Get-MishProperty $target 'tunnel_type') -cne 'masque' -or
        -not (Test-MishRegistrationActive $target)
    ) {
        Stop-MishProbe 'LAB_TARGET_REGISTRATION_IDENTITY_MISMATCH' 'Exact registration identity/policy/tunnel state does not match the guarded Android target.'
    }

    $scopeEvidence = [ordered]@{
        registration_id = $RegistrationId
        total_registrations_before = $registrationsBefore.Count
        target_match_count = $targetMatches.Count
        client_version = [string](Get-MishProperty $device 'client_version')
        policy = [string](Get-MishProperty $policy 'name')
        registration_type = [string](Get-MishProperty $target 'registration_type')
        tunnel_type = [string](Get-MishProperty $target 'tunnel_type')
        non_target_registrations_unchanged = $false
    }

    $airplane = Invoke-MishAdb -Arguments @('shell','cmd','connectivity','airplane-mode') -TimeoutSeconds 5
    $vpnPid = Invoke-MishAdb -Arguments @('shell','pidof','com.cloudflare.cloudflareoneagent') -TimeoutSeconds 5
    $meshBefore = Get-MishMeshAddresses
    $snapshotBefore = Read-MishSnapshot
    if (
        $airplane.TimedOut -or $airplane.ExitCode -ne 0 -or $airplane.StdOut.Trim() -cne 'disabled' -or
        $vpnPid.TimedOut -or $vpnPid.ExitCode -ne 0 -or $vpnPid.StdOut.Trim() -notmatch '^\d+$' -or
        -not $meshBefore.Available -or @($meshBefore.Addresses).Count -ne 1 -or
        -not $snapshotBefore.Available -or
        -not [bool]$snapshotBefore.Value.consistent -or
        -not [bool]$snapshotBefore.Value.cellular.admitted -or
        -not [bool]$snapshotBefore.Value.mesh.admitted -or
        -not [bool]$snapshotBefore.Value.mesh.epoch_present -or
        -not [bool]$snapshotBefore.Value.mesh.ingress_running -or
        [string]$snapshotBefore.Value.readiness.state -cne 'READY'
    ) {
        Stop-MishProbe 'LAB_PRECONDITION_NOT_READY' 'DEVICE-1/PRODUCT baseline is not healthy enough for targeted registration mutation.'
    }

    $baselineEvidence = [ordered]@{
        registration_active = $true
        airplane_disabled = $true
        cloudflare_process_present = $true
        mesh_present = $true
        mesh_admitted = $true
        mesh_epoch_present = $true
        mesh_ingress_running = $true
        readiness = 'READY'
    }

    # Mark cleanup-required before the request: an HTTP timeout can occur after Cloudflare applied the mutation.
    $registrationMayBeRevoked = $true
    if (-not (Invoke-MishRegistrationMutation -Client $client -Action revoke)) {
        Stop-MishProbe 'LAB_TARGET_REVOKE_REQUEST_FAILED' 'Exact registration revoke request did not return Cloudflare success.'
    }
    $revoked = Wait-MishRegistrationState -Client $client -State revoked -TimeoutSeconds 20
    if ($null -eq $revoked) {
        Stop-MishProbe 'LAB_TARGET_REVOKE_NOT_CONFIRMED' 'Cloudflare control plane did not confirm exact registration revocation.'
    }

    $registrationsAfterRevoke = @(Get-MishRegistrations -Client $client)
    if ($registrationsAfterRevoke.Count -eq 0 -or -not (Compare-MishNonTargetRegistrations -Before $registrationsBefore -After $registrationsAfterRevoke)) {
        Stop-MishProbe 'LAB_REVOKE_SCOPE_VIOLATION' 'A non-target registration changed during the targeted revoke experiment.'
    }
    $scopeEvidence.non_target_registrations_unchanged = $true

    $lossState = Wait-MishOwnerState -State lost -TimeoutSeconds $LossWindowSeconds -Observations $lossObservations
    $lossEvidence.control_plane_revoked = $true
    $lossEvidence.owner_revoke_observed = ($null -ne $lossState)
    $lossEvidence.mesh_address_removed = @($lossObservations | Where-Object { $_.mesh_observation_available -and $_.mesh_addresses.Count -eq 0 }).Count -gt 0
    $lossEvidence.revoke_to_owner_loss_ms = if ($null -ne $lossState) { [int64]$lossState.ElapsedMs } else { $null }
    $lossEvidence.snapshot_timeout_count = @($lossObservations | Where-Object { $_.snapshot_fresh -and $_.snapshot_timeout }).Count
    $lossEvidence.mesh_observation_timeout_count = @($lossObservations | Where-Object { $_.mesh_observation_timeout }).Count

    $successfulLossSnapshots = @(
        $lossObservations |
            Where-Object {
                $_.snapshot_fresh -and
                $_.snapshot_available
            }
    )

    $lossEvidence.successful_authoritative_snapshots =
        $successfulLossSnapshots.Count

    $lossEvidence.first_successful_snapshot_ms =
        if ($successfulLossSnapshots.Count -gt 0) {
            [int64]$successfulLossSnapshots[0].elapsed_ms
        }
        else {
            $null
        }

    $lossEvidence.last_successful_snapshot_ms =
        if ($successfulLossSnapshots.Count -gt 0) {
            [int64]$successfulLossSnapshots[
                $successfulLossSnapshots.Count - 1
            ].elapsed_ms
        }
        else {
            $null
        }

    $maxSnapshotGapMs = 0L

    for (
        $index = 1;
        $index -lt $successfulLossSnapshots.Count;
        $index++
    ) {
        $gap = (
            [int64]$successfulLossSnapshots[$index].elapsed_ms -
            [int64]$successfulLossSnapshots[$index - 1].elapsed_ms
        )

        if ($gap -gt $maxSnapshotGapMs) {
            $maxSnapshotGapMs = $gap
        }
    }

    $lossEvidence.max_snapshot_gap_ms =
        if ($successfulLossSnapshots.Count -gt 0) {
            $maxSnapshotGapMs
        }
        else {
            $null
        }

    $unrevoke = Invoke-MishGuaranteedUnrevoke -Client $client
    $cleanupEvidence.attempted = $true
    $cleanupEvidence.mutation_success = [bool]$unrevoke.mutation_success
    $cleanupEvidence.active_confirmed = [bool]$unrevoke.active_confirmed
    if (-not $unrevoke.active_confirmed) {
        Stop-MishProbe 'LAB_TARGET_UNREVOKE_CONTROL_PLANE_FAILED' 'Exact registration could not be restored to active state.'
    }
    $registrationMayBeRevoked = $false

    if ($null -eq $lossState) {
        $minimumCoverageEndMs =
            [Math]::Max(
                0,
                ($LossWindowSeconds * 1000) - 10000
            )

        $coverageAdequate = (
            $successfulLossSnapshots.Count -ge 3 -and
            [int64]$successfulLossSnapshots[0].elapsed_ms -le 10000 -and
            [int64]$successfulLossSnapshots[
                $successfulLossSnapshots.Count - 1
            ].elapsed_ms -ge $minimumCoverageEndMs -and
            $maxSnapshotGapMs -le 10000
        )

        $lossEvidence.authoritative_observation_coverage_adequate =
            $coverageAdequate

        if (-not $coverageAdequate) {
            Stop-MishProbe `
                'LAB_OWNER_OBSERVATION_COVERAGE_INSUFFICIENT' `
                'No owner loss was observed, but fresh authoritative PRODUCT snapshot coverage was insufficient for a conclusive no-loss result.'
        }

        Stop-MishProbe 'LAB_REGISTRATION_REVOKE_NO_OWNER_LOSS_WITHIN_WINDOW' 'Registration revoke did not produce natural Mesh owner revocation inside the bounded loss window.'
    }

    $recoveryState = Wait-MishOwnerState -State ready -TimeoutSeconds $RecoveryWindowSeconds -Observations $recoveryObservations
    $recoveryEvidence.control_plane_active = $true
    $recoveryEvidence.owner_recovery_observed = ($null -ne $recoveryState)
    $recoveryEvidence.unrevoke_to_ready_ms = if ($null -ne $recoveryState) { [int64]$recoveryState.ElapsedMs } else { $null }
    $recoveryEvidence.snapshot_timeout_count = @($recoveryObservations | Where-Object { $_.snapshot_fresh -and $_.snapshot_timeout }).Count
    $recoveryEvidence.mesh_observation_timeout_count = @($recoveryObservations | Where-Object { $_.mesh_observation_timeout }).Count

    if ($null -eq $recoveryState) {
        Stop-MishProbe 'LAB_REGISTRATION_UNREVOKE_AUTORECOVERY_NOT_OBSERVED' 'Active registration did not yield autonomous Mesh owner recovery inside the bounded recovery window.'
    }

    & (Join-Path $PSScriptRoot 'collect-device-diagnostic.ps1') `
        -AdbPath $AdbPath `
        -PackageName $PackageName `
        -EvidencePath $PostRecoveryDiagnosticPath | Out-Host
    $diagnostic = Get-Content -Raw -LiteralPath $PostRecoveryDiagnosticPath | ConvertFrom-Json
    $recoveryEvidence.post_recovery_diagnostic = [string]$diagnostic.classification
    $recoveryEvidence.post_recovery_mesh_e2e = [string]$diagnostic.external.mesh_proxy_e2e.result
    if ([string]$diagnostic.classification -cne 'PASS' -or [string]$diagnostic.external.mesh_proxy_e2e.result -cne 'PASS') {
        Stop-MishProbe 'U2_REGISTRATION_RECOVERY_E2E_FAILED' 'Natural owner recovery occurred but canonical post-recovery diagnostic/Mesh E2E was not PASS.'
    }

    $registrationsFinal = @(Get-MishRegistrations -Client $client)
    if ($registrationsFinal.Count -ne $ExpectedRegistrationCount -or -not (Compare-MishNonTargetRegistrations -Before $registrationsBefore -After $registrationsFinal)) {
        Stop-MishProbe 'LAB_FINAL_REGISTRATION_SCOPE_MISMATCH' 'Final control-plane scope differs from the guarded baseline.'
    }
    $finalTarget = @($registrationsFinal | Where-Object { [string](Get-MishProperty $_ 'id') -ceq $RegistrationId })
    if ($finalTarget.Count -ne 1 -or -not (Test-MishRegistrationActive $finalTarget[0])) {
        Stop-MishProbe 'LAB_FINAL_TARGET_NOT_ACTIVE' 'The exact Android registration is not active at final verification.'
    }

    $acceptanceResult = 'PASS'
    $classification = 'LAB_REGISTRATION_REVOKE_UNREVOKE_TRIGGER_PASS'
    $primaryClassification = $classification
}
catch {
    $message = $_.Exception.Message
    if ($message -match '^MISH_REGISTRATION_RECOVERY_FAILURE\|(?<classification>[A-Z0-9_]+)\|') {
        $classification = $Matches['classification']
    }
    else {
        $classification = 'LAB_REGISTRATION_RECOVERY_UNEXPECTED_FAILURE'
    }
    $primaryClassification = $classification
}
finally {
    if ($null -ne $client -and $registrationMayBeRevoked) {
        $cleanupEvidence.attempted = $true
        try {
            $cleanup = Invoke-MishGuaranteedUnrevoke -Client $client
            $cleanupEvidence.mutation_success = [bool]$cleanup.mutation_success
            $cleanupEvidence.active_confirmed = [bool]$cleanup.active_confirmed
            if (-not $cleanup.active_confirmed) {
                $classification = 'LAB_TARGET_UNREVOKE_CLEANUP_FAILED'
                $acceptanceResult = 'FAIL'
            }
        }
        catch {
            $cleanupEvidence.active_confirmed = $false
            $classification = 'LAB_TARGET_UNREVOKE_CLEANUP_FAILED'
            $acceptanceResult = 'FAIL'
        }
    }

    if ($null -ne $client) { $client.Dispose() }
    $token = $null

    $evidence = [ordered]@{
        schema = $script:Schema
        collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        acceptance_result = $acceptanceResult
        classification = $classification
        primary_classification = $primaryClassification
        target = [ordered]@{
            account_id = $AccountId
            registration_id = $RegistrationId
            expected_client_version = $ExpectedClientVersion
            expected_policy = $ExpectedPolicyName
        }
        scope = $scopeEvidence
        baseline = $baselineEvidence
        loss = $lossEvidence
        loss_observations = @($lossObservations)
        recovery = $recoveryEvidence
        recovery_observations = @($recoveryObservations)
        cleanup = $cleanupEvidence
        lab_effects = [ordered]@{
            cloudflare_registration_revoke = $true
            cloudflare_registration_unrevoke = $true
            physical_device_revoke = $false
            global_warp_disconnect = $false
            cloudflare_app_force_stop = $false
            cloudflare_ui_used = $false
            airplane_mode_mutated = $false
            product_routes_or_iptables_mutated_by_lab = $false
        }
    }

    $fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $fullEvidencePath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullEvidencePath,
        (($evidence | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

Write-Host "MISH_REGISTRATION_RECOVERY_ACCEPTANCE=$acceptanceResult"
Write-Host "MISH_REGISTRATION_RECOVERY_CLASSIFICATION=$classification"
Write-Host "MISH_REGISTRATION_RECOVERY_EVIDENCE=$([IO.Path]::GetFullPath($EvidencePath))"
if ($acceptanceResult -cne 'PASS') {
    throw "MISH_REGISTRATION_RECOVERY_RESULT|$acceptanceResult|$classification"
}
