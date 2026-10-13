[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshDeviceCidr = '100.96.0.0/12',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-warp-state-v1.json'),
    [switch] $PhysicalLab,
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Repository = 'iamaman11/mobile-proxy-mish'
$script:EvidenceSchema = 'mish.lab.warp-state/v1'
$script:CloudflareServiceName = 'CloudflareWARP'
$script:TcpTimeoutMs = 3000

function Stop-MishWarpStateDiagnostic {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_WARP_STATE_FAILURE|$Category|$Message"
}

function Get-MishWarpStateClassification {
    param(
        [Parameter(Mandatory)][bool] $Connected,
        [Parameter(Mandatory)][bool] $AdapterUp,
        [Parameter(Mandatory)][bool] $ServiceRunning,
        [Parameter(Mandatory)][bool] $RoutePresent,
        [Parameter(Mandatory)][bool] $RouteCloudflareOwned,
        [Parameter(Mandatory)][bool] $Tcp3128
    )

    if (-not $Connected) { return 'WARP_DISCONNECTED' }
    if (-not $AdapterUp -or -not $ServiceRunning) { return 'WARP_LOCAL_RUNTIME_DEGRADED' }
    if (-not $RoutePresent -or -not $RouteCloudflareOwned) { return 'WARP_MESH_ROUTE_NOT_OWNED' }
    if (-not $Tcp3128) { return 'WARP_MESH_TCP_3128_UNREACHABLE' }
    return 'READY'
}

function Assert-MishWarpStateSelfTest {
    $cases = @(
        @{ Params = @{ Connected = $false; AdapterUp = $true;  ServiceRunning = $true;  RoutePresent = $true;  RouteCloudflareOwned = $true;  Tcp3128 = $true  }; Want = 'WARP_DISCONNECTED' },
        @{ Params = @{ Connected = $true;  AdapterUp = $false; ServiceRunning = $true;  RoutePresent = $true;  RouteCloudflareOwned = $true;  Tcp3128 = $true  }; Want = 'WARP_LOCAL_RUNTIME_DEGRADED' },
        @{ Params = @{ Connected = $true;  AdapterUp = $true;  ServiceRunning = $false; RoutePresent = $true;  RouteCloudflareOwned = $true;  Tcp3128 = $true  }; Want = 'WARP_LOCAL_RUNTIME_DEGRADED' },
        @{ Params = @{ Connected = $true;  AdapterUp = $true;  ServiceRunning = $true;  RoutePresent = $false; RouteCloudflareOwned = $false; Tcp3128 = $true  }; Want = 'WARP_MESH_ROUTE_NOT_OWNED' },
        @{ Params = @{ Connected = $true;  AdapterUp = $true;  ServiceRunning = $true;  RoutePresent = $true;  RouteCloudflareOwned = $false; Tcp3128 = $true  }; Want = 'WARP_MESH_ROUTE_NOT_OWNED' },
        @{ Params = @{ Connected = $true;  AdapterUp = $true;  ServiceRunning = $true;  RoutePresent = $true;  RouteCloudflareOwned = $true;  Tcp3128 = $false }; Want = 'WARP_MESH_TCP_3128_UNREACHABLE' },
        @{ Params = @{ Connected = $true;  AdapterUp = $true;  ServiceRunning = $true;  RoutePresent = $true;  RouteCloudflareOwned = $true;  Tcp3128 = $true  }; Want = 'READY' }
    )
    foreach ($case in $cases) {
        $params = $case.Params
        $actual = Get-MishWarpStateClassification @params
        if ($actual -cne $case.Want) {
            throw "WARP-state classification self-test failed: expected $($case.Want), observed $actual."
        }
    }
    Write-Host 'MISH_WARP_STATE_SELF_TEST=PASS'
}

if ($SelfTest) {
    Assert-MishWarpStateSelfTest
    exit 0
}

if (-not $IsWindows) {
    Stop-MishWarpStateDiagnostic 'IDENTITY_MISMATCH' 'WARP-state physical diagnostics require Windows.'
}
if ($PhysicalLab) {
    if ($env:GITHUB_REPOSITORY -cne $script:Repository -or
        $env:GITHUB_REF -cne 'refs/heads/main' -or
        $env:GITHUB_REF_PROTECTED -cne 'true') {
        Stop-MishWarpStateDiagnostic 'UNTRUSTED_REF' 'Physical WARP-state diagnostics require protected main.'
    }
    if ($env:RUNNER_OS -cne 'Windows' -or $env:RUNNER_ARCH -cne 'X64') {
        Stop-MishWarpStateDiagnostic 'IDENTITY_MISMATCH' 'Physical WARP-state runner identity mismatch.'
    }
}
if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishWarpStateDiagnostic 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $rows = @(& $AdbPath @Arguments 2>$null | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        Stop-MishWarpStateDiagnostic 'ADB_FAILED' "ADB command failed with exit code $exitCode."
    }
    return ($rows -join [Environment]::NewLine).Trim()
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

$addressOutput = Invoke-MishAdbText -Arguments @('shell', 'ip', '-o', '-4', 'addr', 'show')
$meshAddresses = @(
    [regex]::Matches($addressOutput, '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/\d+') |
        ForEach-Object { $_.Groups['ip'].Value } |
        Where-Object { Test-MishIpv4InCidr -Address $_ -Cidr $MeshDeviceCidr } |
        Sort-Object -Unique
)
if ($meshAddresses.Count -ne 1) {
    Stop-MishWarpStateDiagnostic 'MESH_ENDPOINT_COUNT' "Expected exactly one DEVICE Mesh IPv4 endpoint; observed $($meshAddresses.Count)."
}
$meshAddress = [string]$meshAddresses[0]

$modulePath = Join-Path $PSScriptRoot 'CloudflareProbe.psm1'
Import-Module $modulePath -Force
$module = Get-Module CloudflareProbe
if ($null -eq $module) {
    Stop-MishWarpStateDiagnostic 'HOST_PREREQUISITE_MISSING' 'Canonical Cloudflare probe module could not be loaded.'
}

$warp = & $module {
    param($MeshDeviceCidr, $MeshAddress)

    $warpCli = Resolve-WarpCli
    $clientVersion = Get-WarpVersion $warpCli
    [void](Assert-WarpRegistration $warpCli)
    $settings = Get-WarpSettingsProjection $warpCli $MeshDeviceCidr
    $connected = Get-WarpConnected $warpCli
    $adapter = Get-WarpAdapter
    $route = Get-SelectedRouteProjection $MeshAddress

    [pscustomobject]@{
        ClientVersion = [string]$clientVersion
        RegistrationPresent = $true
        Connected = [bool]$connected
        Mode = [string]$settings.Mode
        Protocol = [string]$settings.Protocol
        SplitTunnelMode = [string]$settings.SplitTunnelMode
        MeshDeviceCidrIncluded = [bool]$settings.MeshDeviceCidrIncluded
        OrganizationConfigured = [bool]$settings.OrganizationConfigured
        ProfileApplied = [bool]$settings.ProfileApplied
        AdapterName = [string]$adapter.Name
        AdapterStatus = [string]$adapter.Status
        AdapterInterfaceIndex = [int]$adapter.ifIndex
        RoutePresent = [bool]$route.Present
        RouteInterfaceAlias = [string]$route.InterfaceAlias
    }
} $MeshDeviceCidr $meshAddress

$services = @(Get-Service -Name $script:CloudflareServiceName -ErrorAction SilentlyContinue)
if ($services.Count -ne 1) {
    Stop-MishWarpStateDiagnostic 'HOST_PREREQUISITE_MISSING' 'Exactly one Cloudflare One Client service must be observable.'
}
$service = $services[0]
$adapterUp = [string]$warp.AdapterStatus -ceq 'Up'
$serviceRunning = [string]$service.Status -ceq 'Running'
$routeCloudflareOwned = [bool]$warp.RoutePresent -and ([string]$warp.RouteInterfaceAlias -ceq [string]$warp.AdapterName)
$tcp3128 = Test-MishTcp -HostName $meshAddress -Port 3128

$classification = Get-MishWarpStateClassification `
    -Connected ([bool]$warp.Connected) `
    -AdapterUp $adapterUp `
    -ServiceRunning $serviceRunning `
    -RoutePresent ([bool]$warp.RoutePresent) `
    -RouteCloudflareOwned $routeCloudflareOwned `
    -Tcp3128 $tcp3128

$evidence = [ordered]@{
    schema = $script:EvidenceSchema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    repository = $script:Repository
    git_commit = [string]$env:GITHUB_SHA
    package = $PackageName
    mesh_endpoint_count = 1
    classification = $classification
    cloudflare = [ordered]@{
        client_version = [string]$warp.ClientVersion
        registration_present = [bool]$warp.RegistrationPresent
        connected = [bool]$warp.Connected
        mode = [string]$warp.Mode
        tunnel_protocol = [string]$warp.Protocol
        split_tunnel_mode = [string]$warp.SplitTunnelMode
        mesh_device_cidr_included = [bool]$warp.MeshDeviceCidrIncluded
        organization_configured = [bool]$warp.OrganizationConfigured
        profile_applied = [bool]$warp.ProfileApplied
        provider_write_attempted = $false
    }
    windows = [ordered]@{
        adapter = [ordered]@{
            alias = [string]$warp.AdapterName
            status = [string]$warp.AdapterStatus
            interface_index = [int]$warp.AdapterInterfaceIndex
        }
        service = [ordered]@{
            status = [string]$service.Status
            start_type = [string]$service.StartType
        }
        mesh_route = [ordered]@{
            present = [bool]$warp.RoutePresent
            cloudflare_owned = $routeCloudflareOwned
            interface_alias = [string]$warp.RouteInterfaceAlias
        }
        tcp_3128 = $tcp3128
    }
    mutation_performed = $false
    secrets_persisted_in_evidence = $false
    raw_registration_persisted = $false
    raw_settings_persisted = $false
}

$fullPath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullPath,
    (($evidence | ConvertTo-Json -Depth 10) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host 'MISH_WARP_STATE_COLLECTION=PASS'
Write-Host "MISH_WARP_STATE_CLASSIFICATION=$classification"
Write-Host "MISH_WARP_STATE_CONNECTED=$([bool]$warp.Connected)"
Write-Host "MISH_WARP_STATE_MODE=$([string]$warp.Mode)"
Write-Host "MISH_WARP_STATE_PROTOCOL=$([string]$warp.Protocol)"
Write-Host "MISH_WARP_STATE_MESH_CIDR_INCLUDED=$([bool]$warp.MeshDeviceCidrIncluded)"
Write-Host "MISH_WARP_STATE_ADAPTER=$([string]$warp.AdapterStatus)"
Write-Host "MISH_WARP_STATE_SERVICE=$([string]$service.Status)"
Write-Host "MISH_WARP_STATE_ROUTE_CLOUDFLARE_OWNED=$routeCloudflareOwned"
Write-Host "MISH_WARP_STATE_TCP_3128=$tcp3128"
Write-Host "MISH_WARP_STATE_EVIDENCE=$fullPath"
