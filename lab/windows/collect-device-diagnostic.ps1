[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [string] $ProbeUrl = 'https://example.com/',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-device-diagnostic-v2.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AndroidSchema = 'mish.diagnostics/v2'
$script:EvidenceSchema = 'mish.lab.diagnostic/v2'
$script:SnapshotMethod = 'snapshot_v2'
$script:TcpTimeoutMs = 3000
$script:HttpTimeoutSeconds = 15

Import-Module (Join-Path $PSScriptRoot 'DeviceDiagnosticClassification.psm1') -Force

function Stop-MishDiagnostic {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_DIAGNOSTIC_FAILURE|$Category|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $output = @(& $AdbPath @Arguments 2>$null)
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        Stop-MishDiagnostic 'ADB_FAILED' "ADB command failed with exit code $exitCode."
    }
    return ($output -join "`n").Trim()
}

function Test-MishIpv4InCidr {
    param(
        [Parameter(Mandatory)][string] $Address,
        [Parameter(Mandatory)][string] $Cidr
    )
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { return $false }
    try {
        $addressBytes = [Net.IPAddress]::Parse($Address).GetAddressBytes()
        $networkBytes = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $prefix = [int]$parts[1]
    }
    catch { return $false }
    if ($addressBytes.Length -ne 4 -or $networkBytes.Length -ne 4 -or $prefix -lt 0 -or $prefix -gt 32) {
        return $false
    }
    for ($index = 0; $index -lt 4; $index++) {
        $remaining = $prefix - ($index * 8)
        $bits = [Math]::Min(8, [Math]::Max(0, $remaining))
        if ($bits -eq 0) { continue }
        $mask = (0xff -shl (8 - $bits)) -band 0xff
        if ((([int]$addressBytes[$index]) -band $mask) -ne (([int]$networkBytes[$index]) -band $mask)) {
            return $false
        }
    }
    return $true
}

function Test-MishTcp {
    param(
        [Parameter(Mandatory)][string] $HostName,
        [Parameter(Mandatory)][int] $Port
    )
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait($script:TcpTimeoutMs)) { return $false }
        return $client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Invoke-MishHttpProxyProbe {
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)][int] $ProxyPort,
        [Parameter(Mandatory)] $Lease
    )
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $handler = $null
    $client = $null
    $response = $null
    try {
        $proxy = [Net.WebProxy]::new("http://${ProxyHost}:$ProxyPort")
        $proxy.Credentials = [Net.NetworkCredential]::new(
            [string]$Lease.ProxyUserName,
            [Security.SecureString]$Lease.ProxyPassword
        )
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $true
        $handler.Proxy = $proxy
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [TimeSpan]::FromSeconds($script:HttpTimeoutSeconds)
        $response = $client.GetAsync($ProbeUrl).GetAwaiter().GetResult()
        $result = if ($response.IsSuccessStatusCode) { 'PASS' } else { 'FAIL' }
        $reason = if ($response.IsSuccessStatusCode) { 'NONE' } else { "HTTP_$([int]$response.StatusCode)" }
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        $result = 'FAIL'
        $reason = 'TIMEOUT'
    }
    catch {
        $text = $_.Exception.ToString()
        $result = 'FAIL'
        $reason = if ($text -match '407|proxy authentication') {
            'AUTHENTICATION_FAILED'
        } elseif ($text -match 'certificate|SSL|TLS|AuthenticationException') {
            'TLS_FAILED'
        } else {
            'TRANSPORT_FAILED'
        }
    }
    finally {
        $stopwatch.Stop()
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        elseif ($null -ne $handler) { $handler.Dispose() }
    }
    return [ordered]@{
        result = $result
        reason = $reason
        elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
    }
}

function New-MishNotRunProbe {
    param([Parameter(Mandatory)][string] $Reason)
    return [ordered]@{
        result = 'NOT_RUN'
        reason = $Reason
        elapsed_ms = 0
    }
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishDiagnostic 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

$pidBefore = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
if ([string]::IsNullOrWhiteSpace($pidBefore) -or $pidBefore -match '\s') {
    Stop-MishDiagnostic 'PRODUCT_PROCESS_NOT_RUNNING' 'Exactly one already-running PRODUCT process is required.'
}

$contentOutput = Invoke-MishAdbText -Arguments @(
    'shell', 'content', 'call',
    '--uri', "content://$PackageName.diagnostics",
    '--method', $script:SnapshotMethod
)
$payloadMatch = [regex]::Match($contentOutput, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
if (-not $payloadMatch.Success) {
    Stop-MishDiagnostic 'SNAPSHOT_INVALID' 'Android diagnostics bridge returned no V2 payload.'
}
$payloadBytes = $null
try {
    $payloadBytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
    $androidJson = [Text.Encoding]::UTF8.GetString($payloadBytes)
    $android = $androidJson | ConvertFrom-Json
}
catch {
    Stop-MishDiagnostic 'SNAPSHOT_INVALID' 'Android diagnostics V2 payload is malformed.'
}
finally {
    if ($null -ne $payloadBytes) { [Array]::Clear($payloadBytes, 0, $payloadBytes.Length) }
}
if ([string]$android.schema -cne $script:AndroidSchema -or [string]$android.application_id -cne $PackageName) {
    Stop-MishDiagnostic 'SNAPSHOT_IDENTITY_MISMATCH' 'Android diagnostics schema/package identity mismatch.'
}

$pidAfter = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidAfter -ceq $pidBefore

$addressOutput = Invoke-MishAdbText -Arguments @('shell', 'ip', '-o', '-4', 'addr', 'show')
$meshAddresses = @(
    [regex]::Matches($addressOutput, '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/\d+') |
        ForEach-Object { $_.Groups['ip'].Value } |
        Where-Object { Test-MishIpv4InCidr -Address $_ -Cidr $MeshCidr } |
        Sort-Object -Unique
)
$meshEndpointCount = $meshAddresses.Count
$meshAddress = if ($meshEndpointCount -eq 1) { [string]$meshAddresses[0] } else { $null }

$routePresent = $false
$tcp1080 = $false
$tcp1081 = $false
$tcp3128 = $false
if ($null -ne $meshAddress) {
    try {
        $route = Find-NetRoute -RemoteIPAddress $meshAddress -ErrorAction Stop
        $routePresent = $null -ne $route
    }
    catch { $routePresent = $false }
    $tcp1080 = Test-MishTcp -HostName $meshAddress -Port 1080
    $tcp1081 = Test-MishTcp -HostName $meshAddress -Port 1081
    $tcp3128 = Test-MishTcp -HostName $meshAddress -Port 3128
}

$lease = $null
$credentialLeaseStatus = 'NOT_ATTEMPTED'
$credentialStorePath = $null
if ([string]$android.proxy.state -ceq 'RUNNING' -and [bool]$android.credential.active) {
    Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
    $credentialTempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
    if ([string]::IsNullOrWhiteSpace($credentialTempRoot)) {
        $credentialLeaseStatus = 'PROVISIONING_FAILED'
    } else {
        $credentialStorePath = Join-Path ([IO.Path]::GetFullPath($credentialTempRoot)) ('mish-diagnostic-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
        try {
            [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStorePath)
        }
        catch {
            $credentialLeaseStatus = 'PROVISIONING_FAILED'
        }
        if ($credentialLeaseStatus -ceq 'NOT_ATTEMPTED') {
            try {
                $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStorePath
                if ($null -eq $lease) { throw 'Credential lease was not returned.' }
                $credentialLeaseStatus = 'AVAILABLE'
            }
            catch {
                $credentialLeaseStatus = 'OPEN_FAILED'
            }
        }
    }
}
$credentialLeaseAvailable = $credentialLeaseStatus -ceq 'AVAILABLE'

$adbForwardPort = $null
$loopbackProbe = New-MishNotRunProbe -Reason 'PRODUCT_NOT_SERVING_OR_CREDENTIAL_UNAVAILABLE'
$meshProbe = New-MishNotRunProbe -Reason 'PRODUCT_NOT_SERVING_OR_MESH_UNAVAILABLE'
try {
    if ($credentialLeaseAvailable) {
        $forwardOutput = @(& $AdbPath forward 'tcp:0' 'tcp:3128' 2>$null)
        $forwardExit = $LASTEXITCODE
        $forwardText = ($forwardOutput -join "`n").Trim()
        if ($forwardExit -eq 0 -and $forwardText -match '^\d+$') {
            $adbForwardPort = [int]$forwardText
            $loopbackProbe = Invoke-MishHttpProxyProbe -ProxyHost '127.0.0.1' -ProxyPort $adbForwardPort -Lease $lease
        }
        if ($null -ne $meshAddress) {
            $meshProbe = Invoke-MishHttpProxyProbe -ProxyHost $meshAddress -ProxyPort 3128 -Lease $lease
        }
    }
}
finally {
    if ($null -ne $adbForwardPort) {
        & $AdbPath forward --remove "tcp:$adbForwardPort" 2>$null | Out-Null
    }
    $lease = $null
    if ($null -ne $credentialStorePath -and (Test-Path -LiteralPath $credentialStorePath -PathType Leaf)) {
        Remove-Item -LiteralPath $credentialStorePath -Force -ErrorAction SilentlyContinue
    }
}

$pidFinal = Invoke-MishAdbText -Arguments @('shell', 'pidof', $PackageName)
$pidStable = $pidStable -and ($pidFinal -ceq $pidBefore)

$classification = Get-MishDeviceDiagnosticClassification `
    -PidStable $pidStable `
    -AndroidConsistent ([bool]$android.consistent) `
    -CellularState ([string]$android.cellular.state) `
    -CellularReason ([string]$android.cellular.reason) `
    -CellularAdmitted ([bool]$android.cellular.admitted) `
    -RootAuthorityObservation ([string]$android.root.authority_observation) `
    -RootPolicyAuthorized ([bool]$android.root.policy_authorized) `
    -ProxyState ([string]$android.proxy.state) `
    -ProxyFailure ([string]$android.proxy.failure) `
    -CredentialActive ([bool]$android.credential.active) `
    -CredentialLeaseStatus $credentialLeaseStatus `
    -LoopbackResult ([string]$loopbackProbe.result) `
    -LoopbackReason ([string]$loopbackProbe.reason) `
    -ReadinessState ([string]$android.readiness.state) `
    -MeshIngressRunning ([bool]$android.mesh.ingress_running) `
    -MeshIngressFailure ([string]$android.mesh.ingress_failure) `
    -MeshEndpointCount $meshEndpointCount `
    -RoutePresent $routePresent `
    -Tcp3128 $tcp3128 `
    -MeshProbeResult ([string]$meshProbe.result) `
    -MeshProbeReason ([string]$meshProbe.reason)

$evidence = [ordered]@{
    schema = $script:EvidenceSchema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    collection_result = 'PASS'
    package = $PackageName
    pid_stable = $pidStable
    android = $android
    external = [ordered]@{
        mesh_endpoint_count = $meshEndpointCount
        route_present = $routePresent
        tcp = [ordered]@{
            port_1080 = $tcp1080
            port_1081 = $tcp1081
            port_3128 = $tcp3128
        }
        credential_lease_available = $credentialLeaseAvailable
        credential_lease_status = $credentialLeaseStatus
        credential_source = 'bounded_package_provisioning'
        adb_loopback_proxy_e2e = $loopbackProbe
        mesh_proxy_e2e = $meshProbe
    }
    classification = $classification
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_DIAGNOSTIC_COLLECTION=PASS'
Write-Host "MISH_DIAGNOSTIC_CLASSIFICATION=$classification"
Write-Host "MISH_DIAGNOSTIC_PID_STABLE=$pidStable"
Write-Host "MISH_DIAGNOSTIC_CELLULAR=$([string]$android.cellular.state)/$([string]$android.cellular.reason)"
Write-Host "MISH_DIAGNOSTIC_ROOT_AUTHORITY=$([string]$android.root.authority_observation)"
Write-Host "MISH_DIAGNOSTIC_ROOT_POLICY_AUTHORIZED=$([bool]$android.root.policy_authorized)"
Write-Host "MISH_DIAGNOSTIC_PROXY=$([string]$android.proxy.state)"
Write-Host "MISH_DIAGNOSTIC_ANDROID_READINESS=$([string]$android.readiness.state)"
Write-Host "MISH_DIAGNOSTIC_MESH_INGRESS=$([bool]$android.mesh.ingress_running)"
Write-Host "MISH_DIAGNOSTIC_CREDENTIAL_LEASE=$credentialLeaseStatus"
Write-Host "MISH_DIAGNOSTIC_LOOPBACK_E2E=$([string]$loopbackProbe.result)"
Write-Host "MISH_DIAGNOSTIC_MESH_E2E=$([string]$meshProbe.result)"
Write-Host "MISH_DIAGNOSTIC_EVIDENCE=$fullEvidencePath"
