[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8g-clean-client-preflight-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-MishU8G {
    param([Parameter(Mandatory)][string] $Classification, [Parameter(Mandatory)][string] $Message)
    throw "MISH_U8G_PREFLIGHT_FAILURE|$Classification|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments, [string] $Operation = 'adb')
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        Stop-MishU8G 'LAB_ADB_FAILED' "ADB operation '$Operation' failed."
    }
    return ($rows -join [Environment]::NewLine).Trim()
}

function Read-MishProductSnapshot {
    $raw = Invoke-MishAdbText -Operation 'product_snapshot' -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', 'snapshot_v2'
    )
    $match = [regex]::Match($raw, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) {
        Stop-MishU8G 'LAB_DIAGNOSTIC_PAYLOAD_MISSING' 'PRODUCT diagnostics returned no payload.'
    }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch {
        Stop-MishU8G 'LAB_DIAGNOSTIC_PAYLOAD_INVALID' 'PRODUCT diagnostics payload is invalid.'
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Test-MishIpv4InCidr {
    param([Parameter(Mandatory)][string] $Address, [Parameter(Mandatory)][string] $Cidr)
    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) { return $false }
    try {
        $a = [Net.IPAddress]::Parse($Address).GetAddressBytes()
        $n = [Net.IPAddress]::Parse($parts[0]).GetAddressBytes()
        $prefix = [int]$parts[1]
    } catch { return $false }
    if ($a.Length -ne 4 -or $n.Length -ne 4 -or $prefix -lt 0 -or $prefix -gt 32) { return $false }
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $prefix - (8 * $i)))
        if ($bits -eq 0) { continue }
        $mask = (0xff -shl (8 - $bits)) -band 0xff
        if ((([int]$a[$i]) -band $mask) -ne (([int]$n[$i]) -band $mask)) { return $false }
    }
    return $true
}

function Get-MishAndroidMeshAddress {
    $raw = Invoke-MishAdbText -Operation 'mesh_address' -Arguments @('shell', 'ip', '-o', '-4', 'addr', 'show')
    $addresses = @(
        [regex]::Matches($raw, '\binet\s+(?<ip>\d{1,3}(?:\.\d{1,3}){3})/\d+') |
            ForEach-Object { $_.Groups['ip'].Value } |
            Where-Object { Test-MishIpv4InCidr -Address $_ -Cidr $MeshCidr } |
            Sort-Object -Unique
    )
    if ($addresses.Count -ne 1) {
        Stop-MishU8G 'LAB_MESH_ENDPOINT_AMBIGUOUS' 'Exactly one Android Mesh endpoint is required.'
    }
    return [string]$addresses[0]
}

function Test-MishTcpPort {
    param([Parameter(Mandatory)][string] $HostName, [Parameter(Mandatory)][int] $Port)
    $client = [Net.Sockets.TcpClient]::new()
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        if (-not $task.Wait(5000)) { return $false }
        return [bool]$client.Connected
    }
    catch { return $false }
    finally { $client.Dispose() }
}

function Find-MishExecutable {
    param([Parameter(Mandatory)][string[]] $Candidates)
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $true }
    }
    return $false
}

function Test-MishLocalPort {
    param([Parameter(Mandatory)][int] $Port)
    return Test-MishTcpPort -HostName '127.0.0.1' -Port $Port
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishU8G 'LAB_ADB_MISSING' 'Canonical ADB is unavailable.'
}
$devices = @(& $AdbPath devices | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {
    Stop-MishU8G 'DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.'
}

$product = Read-MishProductSnapshot
$productReady = (
    [bool]$product.consistent -and
    [bool]$product.runtime.running -and
    [bool]$product.cellular.admitted -and
    [bool]$product.root.policy_authorized -and
    [string]$product.proxy.state -ceq 'RUNNING' -and
    [bool]$product.mesh.admitted -and
    [bool]$product.mesh.ingress_running -and
    [string]$product.readiness.state -ceq 'READY'
)
if (-not $productReady) {
    Stop-MishU8G 'PRODUCT_NOT_READY' 'PRODUCT baseline is not READY.'
}

$meshAddress = Get-MishAndroidMeshAddress
$meshPorts = [ordered]@{
    mixed_1080 = Test-MishTcpPort -HostName $meshAddress -Port 1080
    socks5_1081 = Test-MishTcpPort -HostName $meshAddress -Port 1081
    connect_3128 = Test-MishTcpPort -HostName $meshAddress -Port 3128
}

$warpCliCandidates = @(
    (Get-Command 'warp-cli.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'
)
$warpCli = $warpCliCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
$warpStatusKnown = $false
$warpConnected = $false
$warpHealthy = $false
if ($warpCli) {
    $warpRows = @(& $warpCli status 2>&1 | ForEach-Object { [string]$_ })
    if ($LASTEXITCODE -eq 0) {
        $warpStatusKnown = $true
        $warpText = $warpRows -join [Environment]::NewLine
        $warpConnected = $warpText -match '(?i)\bConnected\b'
        $warpHealthy = $warpText -match '(?i)NetworkHealthy|healthy'
    }
}

$adapters = @(Get-NetAdapter -ErrorAction SilentlyContinue)
$warpAdapters = @($adapters | Where-Object {
    $_.Status -eq 'Up' -and (
        [string]$_.Name -match '(?i)cloudflare|warp' -or
        [string]$_.InterfaceDescription -match '(?i)cloudflare|warp'
    )
})
$otherTunnelAdapters = @($adapters | Where-Object {
    $_.Status -eq 'Up' -and
    -not (
        [string]$_.Name -match '(?i)cloudflare|warp' -or
        [string]$_.InterfaceDescription -match '(?i)cloudflare|warp'
    ) -and (
        [string]$_.Name -match '(?i)tun|tap|vpn|wireguard|wintun' -or
        [string]$_.InterfaceDescription -match '(?i)tun|tap|vpn|wireguard|wintun'
    )
})

$singBoxRunning = @(
    Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue
).Count -gt 0

$dnsBindings = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue)
$dnsClassCounts = [ordered]@{
    warp_interfaces_with_dns = @($dnsBindings | Where-Object {
        $_.ServerAddresses.Count -gt 0 -and [string]$_.InterfaceAlias -match '(?i)cloudflare|warp'
    }).Count
    other_tunnel_interfaces_with_dns = @($dnsBindings | Where-Object {
        $_.ServerAddresses.Count -gt 0 -and
        [string]$_.InterfaceAlias -notmatch '(?i)cloudflare|warp' -and
        [string]$_.InterfaceAlias -match '(?i)tun|tap|vpn|wireguard|wintun'
    }).Count
    non_tunnel_interfaces_with_dns = @($dnsBindings | Where-Object {
        $_.ServerAddresses.Count -gt 0 -and
        [string]$_.InterfaceAlias -notmatch '(?i)cloudflare|warp|tun|tap|vpn|wireguard|wintun'
    }).Count
}

$programFiles = [Environment]::GetFolderPath('ProgramFiles')
$programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')

$firefoxAvailable = Find-MishExecutable -Candidates @(
    (Join-Path $programFiles 'Mozilla Firefox\firefox.exe'),
    (Join-Path $programFilesX86 'Mozilla Firefox\firefox.exe')
)
$chromeAvailable = Find-MishExecutable -Candidates @(
    (Join-Path $programFiles 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $programFilesX86 'Google\Chrome\Application\chrome.exe'),
    (Join-Path $localAppData 'Google\Chrome\Application\chrome.exe')
)
$edgeAvailable = Find-MishExecutable -Candidates @(
    (Join-Path $programFilesX86 'Microsoft\Edge\Application\msedge.exe'),
    (Join-Path $programFiles 'Microsoft\Edge\Application\msedge.exe')
)
$kameleoApiAvailable = Test-MishLocalPort -Port 5050

$camoufoxAvailable = $false
$camoufoxManifestPath = Join-Path $PSScriptRoot 'u8g-camoufox-toolchain.json'
if (Test-Path -LiteralPath $camoufoxManifestPath -PathType Leaf) {
    try {
        $camoufoxManifest = Get-Content -Raw -LiteralPath $camoufoxManifestPath | ConvertFrom-Json
        $camoufoxRoot = [IO.Path]::GetFullPath([string]$camoufoxManifest.browser.install_root)
        $camoufoxMarkerPath = Join-Path $camoufoxRoot '.mish-u8g-browser.json'
        $camoufoxPropertiesPath = Join-Path $camoufoxRoot 'properties.json'
        if (
            (Test-Path -LiteralPath $camoufoxMarkerPath -PathType Leaf) -and
            (Test-Path -LiteralPath $camoufoxPropertiesPath -PathType Leaf)
        ) {
            $camoufoxMarker = Get-Content -Raw -LiteralPath $camoufoxMarkerPath | ConvertFrom-Json
            $camoufoxExe = Join-Path $camoufoxRoot ([string]$camoufoxMarker.executable_relative_path)
            $camoufoxAvailable = (
                [string]$camoufoxMarker.schema -ceq 'mish.lab.u8g-camoufox-browser/v1' -and
                [string]$camoufoxMarker.identity_source -ceq 'official_archive_sha256' -and
                [string]$camoufoxMarker.version -ceq [string]$camoufoxManifest.browser.version -and
                (Test-Path -LiteralPath $camoufoxExe -PathType Leaf)
            )
        }
    }
    catch {
        $camoufoxAvailable = $false
    }
}

$browserFixtureAvailable = (
    $camoufoxAvailable -or $kameleoApiAvailable -or
    $firefoxAvailable -or $chromeAvailable -or $edgeAvailable
)
$parallelDnsPathPresent = $singBoxRunning -and $otherTunnelAdapters.Count -gt 0
$meshReachable = (
    [bool]$meshPorts.mixed_1080 -and
    [bool]$meshPorts.socks5_1081 -and
    [bool]$meshPorts.connect_3128
)

$classification = if (-not $meshReachable) {
    'BLOCKED_MESH_PEER_UNREACHABLE'
} elseif (-not $browserFixtureAvailable) {
    'BLOCKED_NO_BROWSER_FIXTURE'
} elseif ($parallelDnsPathPresent) {
    'READY_REQUIRES_PROFILE_DNS_ISOLATION'
} else {
    'READY_FOR_CLEAN_PROFILE_ACCEPTANCE'
}

$evidence = [ordered]@{
    schema = 'mish.lab.u8-external-privacy-preflight/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    classification = $classification
    product = [ordered]@{
        ready = $productReady
        runtime_generation = [int64]$product.runtime.generation
        credential_version = if ($null -eq $product.credential.version) { $null } else { [int64]$product.credential.version }
        raw_addresses_persisted = $false
    }
    mesh = [ordered]@{
        route_identity_persisted = $false
        ports = $meshPorts
        all_required_ports_reachable = $meshReachable
    }
    warp = [ordered]@{
        cli_available = [bool]$warpCli
        status_known = $warpStatusKnown
        connected = $warpConnected
        healthy = $warpHealthy
        up_adapter_count = $warpAdapters.Count
    }
    parallel_dns_path = [ordered]@{
        sing_box_running = $singBoxRunning
        non_warp_tunnel_adapter_count = $otherTunnelAdapters.Count
        present = $parallelDnsPathPresent
        raw_dns_servers_persisted = $false
        dns_interface_classes = $dnsClassCounts
    }
    fixtures = [ordered]@{
        camoufox_available = $camoufoxAvailable
        kameleo_local_api_available = $kameleoApiAvailable
        firefox_available = $firefoxAvailable
        chrome_available = $chromeAvailable
        edge_available = $edgeAvailable
        any_browser_fixture_available = $browserFixtureAvailable
        user_paths_persisted = $false
    }
    mutation = [ordered]@{
        process_stopped = $false
        service_restarted = $false
        adapter_changed = $false
        route_changed = $false
        firewall_changed = $false
        browser_profile_changed = $false
        product_changed = $false
    }
    secrets_persisted = $false
    raw_public_private_or_dns_addresses_persisted = $false
}

$fullPath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullPath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullPath,
    (($evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Host "MISH_U8G_PREFLIGHT_CLASSIFICATION=$classification"
Write-Host "MISH_U8G_PREFLIGHT_PRODUCT_READY=$productReady"
Write-Host "MISH_U8G_PREFLIGHT_MESH_REACHABLE=$meshReachable"
Write-Host "MISH_U8G_PREFLIGHT_PARALLEL_DNS_PATH=$parallelDnsPathPresent"
Write-Host "MISH_U8G_PREFLIGHT_CAMOUFOX=$camoufoxAvailable"
Write-Host "MISH_U8G_PREFLIGHT_KAMELEO_API=$kameleoApiAvailable"
Write-Host "MISH_U8G_PREFLIGHT_FIREFOX=$firefoxAvailable"
Write-Host "MISH_U8G_PREFLIGHT_EVIDENCE=$fullPath"
