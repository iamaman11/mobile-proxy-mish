[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [string] $ProbeUrl = 'https://example.com/',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-device-diagnostic-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:AndroidSchema = 'mish.diagnostics/v1'
$script:EvidenceSchema = 'mish.lab.diagnostic/v1'
$script:SnapshotMethod = 'snapshot_v1'
$script:TcpTimeoutMs = 3000
$script:HttpTimeoutSeconds = 15

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
    Stop-MishDiagnostic 'SNAPSHOT_INVALID' 'Android diagnostics bridge returned no V1 payload.'
}
try {
    $payloadBytes = [Convert]::FromBase64String($payloadMatch.Groups['payload'].Value)
    $androidJson = [Text.Encoding]::UTF8.GetString($payloadBytes)
    $android = $androidJson | ConvertFrom-Json
}
catch {
    Stop-MishDiagnostic 'SNAPSHOT_INVALID' 'Android diagnostics V1 payload is malformed.'
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
$credentialLeaseAvailable = $false
try {
    Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
    $lease = Open-MishExternalProxyCredentialLease
    $credentialLeaseAvailable = $null -ne $lease
}
catch {
    $credentialLeaseAvailable = $false
}

$adbForwardPort = $null
$loopbackProbe = New-MishNotRunProbe -Reason 'CREDENTIAL_OR_FORWARD_UNAVAILABLE'
$meshProbe = New-MishNotRunProbe -Reason 'CREDENTIAL_OR_MESH_ENDPOINT_UNAVAILABLE'
try {
    if ($credentialLeaseAvailable) {
        $forwardOutput = @(& $AdbPath forward 'tcp:0' 'tcp:3128' 2>$null)
        $forwardExit = $LASTEXITCODE
        $forwardText = ($forwardOutput -join "`n").Trim()
        if ($forwardExit -eq 0 -and $forwardText -match '^\d+$') {
            $adbForwardPort = [int]$forwardText
            $loopbackProbe = Invoke-MishHttpProxyProbe `
                -ProxyHost '127.0.0.1' `
                -ProxyPort $adbForwardPort `
                -Lease $lease
        }
        if ($null -ne $meshAddress) {
            $meshProbe = Invoke-MishHttpProxyProbe `
                -ProxyHost $meshAddress `
                -ProxyPort 3128 `
                -Lease $lease
        }
    }
}
finally {
    if ($null -ne $adbForwardPort) {
        & $AdbPath forward --remove "tcp:$adbForwardPort" 2>$null | Out-Null
    }
    $lease = $null
}

$classification = switch ($true) {
    (-not $pidStable) { 'INVALID_PROCESS_CHANGED_DURING_CAPTURE'; break }
    (-not [bool]$android.consistent) { 'INVALID_ANDROID_SNAPSHOT_CHANGED_DURING_CAPTURE'; break }
    (-not $credentialLeaseAvailable) { 'CREDENTIAL_LEASE_UNAVAILABLE'; break }
    ([string]$loopbackProbe.result -ne 'PASS') { "PRODUCT_LOOPBACK_E2E_$([string]$loopbackProbe.reason)"; break }
    ([string]$android.readiness.state -ne 'READY') { 'READINESS_INTERNAL_PROBE_MISMATCH'; break }
    (-not [bool]$android.mesh.ingress_running) { "MESH_INGRESS_$([string]$android.mesh.ingress_failure)"; break }
    ($meshEndpointCount -ne 1) { 'MESH_ENDPOINT_CARDINALITY_INVALID'; break }
    (-not $routePresent) { 'WINDOWS_MESH_ROUTE_UNAVAILABLE'; break }
    (-not $tcp3128) { 'WINDOWS_MESH_TCP_3128_UNREACHABLE'; break }
    ([string]$meshProbe.result -ne 'PASS') { "WINDOWS_MESH_PROXY_E2E_$([string]$meshProbe.reason)"; break }
    default { 'PASS' }
}

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

Write-Host "MISH_DIAGNOSTIC_COLLECTION=PASS"
Write-Host "MISH_DIAGNOSTIC_CLASSIFICATION=$classification"
Write-Host "MISH_DIAGNOSTIC_PID_STABLE=$pidStable"
Write-Host "MISH_DIAGNOSTIC_ANDROID_READINESS=$([string]$android.readiness.state)"
Write-Host "MISH_DIAGNOSTIC_MESH_INGRESS=$([bool]$android.mesh.ingress_running)"
Write-Host "MISH_DIAGNOSTIC_LOOPBACK_E2E=$([string]$loopbackProbe.result)"
Write-Host "MISH_DIAGNOSTIC_MESH_E2E=$([string]$meshProbe.result)"
Write-Host "MISH_DIAGNOSTIC_EVIDENCE=$fullEvidencePath"
