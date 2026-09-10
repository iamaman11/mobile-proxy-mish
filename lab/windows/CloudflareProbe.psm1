Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Repository = 'iamaman11/mobile-proxy-mish'
$script:EvidenceSchema = 'mish.lab.evidence/v1'
$script:WarpCliDefault = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe'
$script:WarpDaemonDefault = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-svc.exe'
$script:WarpAdapterName = 'CloudflareWARP'
$script:WarpAdapterDescription = 'Cloudflare WARP Interface Tunnel'

function Stop-CloudflareProbe {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )
    throw "MISH_LABCTL_FAILURE|$Category|$Message"
}

function Write-CloudflareJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if ($parent) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($full, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    return $full
}

function Invoke-CloudflareProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 300)][int]$TimeoutSeconds = 30
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Stop-CloudflareProbe 'PROCESS_FAILED' 'Cloudflare One Client command could not be started.'
    }
    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            try { $process.WaitForExit(5000) | Out-Null } catch { }
            Stop-CloudflareProbe 'TIMEOUT' 'Cloudflare One Client command exceeded its bounded timeout.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Get-CloudflareStringHash {
    param([Parameter(Mandatory)][string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([Convert]::ToHexString($sha.ComputeHash($bytes))).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-Ipv4CidrNetworkAddress {
    param([Parameter(Mandatory)][string]$Cidr)

    $parts = $Cidr.Split('/')
    if ($parts.Count -ne 2) {
        Stop-CloudflareProbe 'INPUT_INVALID' 'MeshDeviceCidr must be IPv4 CIDR notation.'
    }
    try {
        $ip = [Net.IPAddress]::Parse($parts[0])
        $prefix = [int]$parts[1]
    }
    catch {
        Stop-CloudflareProbe 'INPUT_INVALID' 'MeshDeviceCidr must be a valid IPv4 CIDR.'
    }
    if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or $prefix -lt 0 -or $prefix -gt 32) {
        Stop-CloudflareProbe 'INPUT_INVALID' 'MeshDeviceCidr must be a valid IPv4 CIDR.'
    }

    $source = $ip.GetAddressBytes()
    $network = [byte[]]::new(4)
    $remaining = $prefix
    for ($i = 0; $i -lt 4; $i++) {
        if ($remaining -ge 8) {
            $mask = 255
        }
        elseif ($remaining -le 0) {
            $mask = 0
        }
        else {
            $mask = 256 - [int][Math]::Pow(2, 8 - $remaining)
        }
        $network[$i] = [byte]([int]$source[$i] -band $mask)
        $remaining -= 8
    }
    return ([Net.IPAddress]::new($network)).ToString()
}

function ConvertFrom-WarpSettingsText {
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$MeshDeviceCidr
    )

    [void](Get-Ipv4CidrNetworkAddress $MeshDeviceCidr)

    $modeMatches = [regex]::Matches($Text, '(?im)^\s*(?:\([^)]+\)\s*)?Mode:\s*([^\s]+)\s*$')
    $modes = @($modeMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($modes.Count -ne 1) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'warp-cli settings did not expose exactly one client mode.'
    }

    $protocolMatches = [regex]::Matches($Text, '(?im)^\s*(?:\([^)]+\)\s*)?(?:WARP\s+)?tunnel protocol:\s*(MASQUE|WireGuard)\s*$')
    $protocols = @($protocolMatches | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($protocols.Count -ne 1) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'warp-cli settings did not expose exactly one WARP tunnel protocol.'
    }

    $includeMode = [regex]::IsMatch($Text, '(?im)^\s*(?:\([^)]+\)\s*)?Include mode, with hosts/ips:\s*$')
    $cidrPattern = '(?im)^\s*(?:\([^)]+\)\s*)?' + [regex]::Escape($MeshDeviceCidr) + '(?:\s+\([^\r\n]*\))?\s*$'
    $meshCidrIncluded = [regex]::IsMatch($Text, $cidrPattern)
    $organizationConfigured = [regex]::IsMatch($Text, '(?im)^\s*(?:\([^)]+\)\s*)?Organization:\s*\S.+$')
    $profileApplied = [regex]::IsMatch($Text, '(?im)^\s*(?:\([^)]+\)\s*)?Profile ID:\s*\S.+$')

    if ($modes[0] -ne 'TunnelOnly') {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Cloudflare One Client mode must be TunnelOnly for CF-2.'
    }
    if ($protocols[0] -ne 'MASQUE') {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Cloudflare One Client tunnel protocol must be MASQUE for CF-2 unless a separate fallback disposition exists.'
    }
    if (-not $includeMode -or -not $meshCidrIncluded) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Split Tunnel Include must contain the accepted Mesh/device CIDR.'
    }
    if (-not $organizationConfigured -or -not $profileApplied) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Cloudflare Zero Trust organization/profile application could not be proven from supported settings read-back.'
    }

    return [pscustomobject]@{
        Mode = $modes[0]
        Protocol = $protocols[0]
        SplitTunnelMode = 'Include'
        MeshDeviceCidrIncluded = $true
        OrganizationConfigured = $true
        ProfileApplied = $true
    }
}

function Test-WarpConnectedText {
    param([Parameter(Mandatory)][string]$Text)
    return [regex]::IsMatch($Text, '(?im)^\s*Status update:\s*Connected\s*$')
}

function Resolve-WarpCli {
    if (-not (Test-Path -LiteralPath $script:WarpDaemonDefault -PathType Leaf)) {
        Stop-CloudflareProbe 'HOST_PREREQUISITE_MISSING' 'Official Cloudflare One Client daemon is not installed at its supported Windows path.'
    }
    if (Test-Path -LiteralPath $script:WarpCliDefault -PathType Leaf) {
        return $script:WarpCliDefault
    }
    $command = Get-Command 'warp-cli.exe' -CommandType Application -ErrorAction SilentlyContinue
    if (-not $command) {
        Stop-CloudflareProbe 'HOST_PREREQUISITE_MISSING' 'warp-cli is unavailable; install the official Cloudflare One Client.'
    }
    return $command.Source
}

function Get-WarpVersion {
    param([Parameter(Mandatory)][string]$WarpCli)
    $result = Invoke-CloudflareProcess $WarpCli @('--version') 20
    if ($result.ExitCode -ne 0) {
        Stop-CloudflareProbe 'PROCESS_FAILED' 'warp-cli --version failed.'
    }
    $match = [regex]::Match($result.StdOut, '\b\d{4}\.\d+\.\d+\.\d+\b')
    if (-not $match.Success) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Cloudflare One Client version could not be parsed.'
    }
    return $match.Value
}

function Assert-WarpRegistration {
    param([Parameter(Mandatory)][string]$WarpCli)
    $result = Invoke-CloudflareProcess $WarpCli @('registration', 'show') 30
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.StdOut)) {
        Stop-CloudflareProbe 'HOST_PREREQUISITE_MISSING' 'Cloudflare Zero Trust registration is not available to the supported client CLI.'
    }
    if ($result.StdOut -match '(?i)(not registered|no registration|registration[^\r\n]*(missing|not found))') {
        Stop-CloudflareProbe 'HOST_PREREQUISITE_MISSING' 'Cloudflare Zero Trust registration is missing.'
    }
    return $true
}

function Get-WarpSettingsProjection {
    param(
        [Parameter(Mandatory)][string]$WarpCli,
        [Parameter(Mandatory)][string]$MeshDeviceCidr
    )
    $result = Invoke-CloudflareProcess $WarpCli @('settings') 30
    if ($result.ExitCode -ne 0) {
        Stop-CloudflareProbe 'PROCESS_FAILED' 'warp-cli settings failed.'
    }
    return ConvertFrom-WarpSettingsText $result.StdOut $MeshDeviceCidr
}

function Get-WarpConnected {
    param([Parameter(Mandatory)][string]$WarpCli)
    $result = Invoke-CloudflareProcess $WarpCli @('status') 20
    if ($result.ExitCode -ne 0) {
        Stop-CloudflareProbe 'PROCESS_FAILED' 'warp-cli status failed.'
    }
    return (Test-WarpConnectedText $result.StdOut)
}

function Wait-WarpConnectionState {
    param(
        [Parameter(Mandatory)][string]$WarpCli,
        [Parameter(Mandatory)][bool]$Connected,
        [ValidateRange(1, 120)][int]$TimeoutSeconds = 45
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if ((Get-WarpConnected $WarpCli) -eq $Connected) {
            return
        }
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    Stop-CloudflareProbe 'TIMEOUT' 'Cloudflare One Client did not reach the required connection state.'
}

function Get-WarpAdapter {
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object {
        $_.Name -eq $script:WarpAdapterName -or $_.InterfaceDescription -eq $script:WarpAdapterDescription
    })
    $unique = @($adapters | Sort-Object -Property ifIndex -Unique)
    if ($unique.Count -ne 1) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Exactly one Cloudflare WARP tunnel interface must be observable on Windows.'
    }
    return $unique[0]
}

function Get-SelectedRouteProjection {
    param([Parameter(Mandatory)][string]$RemoteAddress)
    try {
        $route = @(Find-NetRoute -RemoteIPAddress $RemoteAddress -ErrorAction Stop) | Select-Object -Last 1
    }
    catch {
        return [pscustomobject]@{ Present = $false; InterfaceAlias = $null }
    }
    if (-not $route) {
        return [pscustomobject]@{ Present = $false; InterfaceAlias = $null }
    }
    return [pscustomobject]@{ Present = $true; InterfaceAlias = [string]$route.InterfaceAlias }
}

function Get-NonWarpDnsSignature {
    param([Parameter(Mandatory)][string]$WarpInterfaceAlias)
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(Get-DnsClientServerAddress -ErrorAction Stop | Where-Object { $_.InterfaceAlias -ne $WarpInterfaceAlias })) {
        foreach ($server in @($entry.ServerAddresses)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$server)) {
                $rows.Add("$($entry.InterfaceAlias)|$($entry.AddressFamily)|$server")
            }
        }
    }
    $canonical = (@($rows | Sort-Object -Unique) -join "`n")
    return Get-CloudflareStringHash $canonical
}

function Get-WarpRouteSignature {
    param([Parameter(Mandatory)][uint32]$InterfaceIndex)
    $rows = @(Get-NetRoute -InterfaceIndex $InterfaceIndex -ErrorAction Stop | ForEach-Object {
        "$($_.AddressFamily)|$($_.DestinationPrefix)"
    } | Sort-Object -Unique)
    return Get-CloudflareStringHash ($rows -join "`n")
}

function Get-WindowsRouteSnapshot {
    param(
        [Parameter(Mandatory)][string]$WarpInterfaceAlias,
        [Parameter(Mandatory)][string]$MeshProbeAddress
    )

    $ordinaryV4 = Get-SelectedRouteProjection '203.0.113.1'
    if (-not $ordinaryV4.Present) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Windows has no selected ordinary IPv4 route.'
    }
    $mesh = Get-SelectedRouteProjection $MeshProbeAddress
    if (-not $mesh.Present) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Windows has no selected route for the Mesh/device CIDR probe address.'
    }
    $ordinaryV6 = Get-SelectedRouteProjection '2001:db8::1'

    return [pscustomobject]@{
        OrdinaryIpv4InterfaceAlias = $ordinaryV4.InterfaceAlias
        OrdinaryIpv4CloudflareOwned = ($ordinaryV4.InterfaceAlias -eq $WarpInterfaceAlias)
        MeshInterfaceAlias = $mesh.InterfaceAlias
        MeshCloudflareOwned = ($mesh.InterfaceAlias -eq $WarpInterfaceAlias)
        OrdinaryIpv6Present = [bool]$ordinaryV6.Present
        OrdinaryIpv6InterfaceAlias = $ordinaryV6.InterfaceAlias
        OrdinaryIpv6CloudflareOwned = ($ordinaryV6.Present -and $ordinaryV6.InterfaceAlias -eq $WarpInterfaceAlias)
    }
}

function Invoke-WarpAction {
    param(
        [Parameter(Mandatory)][string]$WarpCli,
        [Parameter(Mandatory)][ValidateSet('connect','disconnect')][string]$Action
    )
    $result = Invoke-CloudflareProcess $WarpCli @($Action) 30
    if ($result.ExitCode -ne 0) {
        Stop-CloudflareProbe 'PROCESS_FAILED' "warp-cli $Action failed."
    }
}

function Invoke-CloudflareWindowsProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MeshDeviceCidr,
        [Parameter(Mandatory)][string]$EvidencePath,
        [switch]$Recovery,
        [switch]$PhysicalLab
    )

    $startedAt = [DateTimeOffset]::UtcNow.ToString('o')
    if (-not $IsWindows) {
        Stop-CloudflareProbe 'IDENTITY_MISMATCH' 'CF-2 Windows proof requires Windows.'
    }
    if ($PhysicalLab) {
        if ($env:GITHUB_REPOSITORY -ne $script:Repository -or $env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_REF_PROTECTED -ne 'true') {
            Stop-CloudflareProbe 'UNTRUSTED_REF' 'CF-2 physical proof requires protected main.'
        }
        if ($env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64') {
            Stop-CloudflareProbe 'IDENTITY_MISMATCH' 'CF-2 physical runner identity mismatch.'
        }
    }

    $meshProbeAddress = Get-Ipv4CidrNetworkAddress $MeshDeviceCidr
    $warpCli = Resolve-WarpCli
    $clientVersion = Get-WarpVersion $warpCli
    [void](Assert-WarpRegistration $warpCli)
    $settings = Get-WarpSettingsProjection $warpCli $MeshDeviceCidr

    $initialConnected = Get-WarpConnected $warpCli
    if (-not $initialConnected) {
        Invoke-WarpAction $warpCli 'connect'
        Wait-WarpConnectionState $warpCli $true
    }

    $warpAdapter = Get-WarpAdapter
    $baselineRoutes = Get-WindowsRouteSnapshot ([string]$warpAdapter.Name) $meshProbeAddress
    if ($baselineRoutes.OrdinaryIpv4CloudflareOwned) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Cloudflare WARP unexpectedly owns the ordinary IPv4 route in TunnelOnly Include mode.'
    }
    if (-not $baselineRoutes.MeshCloudflareOwned) {
        Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Mesh/device CIDR does not select the Cloudflare WARP interface while connected.'
    }

    $baselineDns = Get-NonWarpDnsSignature ([string]$warpAdapter.Name)
    $baselineWarpRoutes = Get-WarpRouteSignature ([uint32]$warpAdapter.ifIndex)
    $disconnectedRoutes = $null
    $reconnectedRoutes = $baselineRoutes
    $dnsStable = $true
    $routeSetRestored = $true
    $disconnectObserved = $false
    $reconnectObserved = $true
    $recoveryStarted = $false

    if ($Recovery) {
        try {
            Invoke-WarpAction $warpCli 'disconnect'
            $recoveryStarted = $true
            Wait-WarpConnectionState $warpCli $false
            $disconnectObserved = $true
            $disconnectedRoutes = Get-WindowsRouteSnapshot ([string]$warpAdapter.Name) $meshProbeAddress
            $disconnectedDns = Get-NonWarpDnsSignature ([string]$warpAdapter.Name)

            Invoke-WarpAction $warpCli 'connect'
            Wait-WarpConnectionState $warpCli $true
            $reconnectObserved = $true

            $settingsAfter = Get-WarpSettingsProjection $warpCli $MeshDeviceCidr
            $reconnectedRoutes = Get-WindowsRouteSnapshot ([string]$warpAdapter.Name) $meshProbeAddress
            $reconnectedDns = Get-NonWarpDnsSignature ([string]$warpAdapter.Name)
            $reconnectedWarpRoutes = Get-WarpRouteSignature ([uint32]$warpAdapter.ifIndex)

            if ($reconnectedRoutes.OrdinaryIpv4CloudflareOwned -or -not $reconnectedRoutes.MeshCloudflareOwned) {
                Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Cloudflare route ownership did not recover to the accepted split after reconnect.'
            }
            if ($reconnectedRoutes.OrdinaryIpv4InterfaceAlias -ne $baselineRoutes.OrdinaryIpv4InterfaceAlias) {
                Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Ordinary IPv4 route owner changed across Cloudflare reconnect.'
            }
            if ($settingsAfter.Mode -ne $settings.Mode -or $settingsAfter.Protocol -ne $settings.Protocol -or $settingsAfter.SplitTunnelMode -ne $settings.SplitTunnelMode) {
                Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Cloudflare client settings drifted across reconnect.'
            }

            $dnsStable = ($baselineDns -eq $disconnectedDns -and $baselineDns -eq $reconnectedDns)
            if (-not $dnsStable) {
                Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Non-Cloudflare Windows DNS configuration drifted across disconnect/reconnect.'
            }
            $routeSetRestored = ($baselineWarpRoutes -eq $reconnectedWarpRoutes)
            if (-not $routeSetRestored) {
                Stop-CloudflareProbe 'OBSERVATION_CONTRADICTION' 'Cloudflare WARP route set did not return to its baseline after reconnect.'
            }
        }
        finally {
            if ($recoveryStarted) {
                try {
                    if (-not (Get-WarpConnected $warpCli)) {
                        Invoke-WarpAction $warpCli 'connect'
                        Wait-WarpConnectionState $warpCli $true
                    }
                }
                catch {
                    throw 'MISH_LABCTL_FAILURE|PROCESS_FAILED|Cloudflare One Client could not be restored to connected state after the recovery proof.'
                }
            }
        }
    }

    $ipv6OwnerDiffers = $false
    if ($baselineRoutes.OrdinaryIpv6Present) {
        $ipv6OwnerDiffers = ($baselineRoutes.OrdinaryIpv6InterfaceAlias -ne $baselineRoutes.OrdinaryIpv4InterfaceAlias)
    }

    $evidence = [ordered]@{
        schema = $script:EvidenceSchema
        run_kind = 'cloudflare-windows-prephone'
        repository = $script:Repository
        git_ref = [string]$env:GITHUB_REF
        git_commit = [string]$env:GITHUB_SHA
        run_id = [string]$env:GITHUB_RUN_ID
        started_at_utc = $startedAt
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        result = 'PASS'
        failure = $null
        observations = [ordered]@{
            cloudflare = [ordered]@{
                client_version = $clientVersion
                registration_present = $true
                organization_configured = $settings.OrganizationConfigured
                profile_applied = $settings.ProfileApplied
                mode = $settings.Mode
                tunnel_protocol = $settings.Protocol
                split_tunnel_mode = $settings.SplitTunnelMode
                mesh_device_cidr = $MeshDeviceCidr
                mesh_device_cidr_included = $settings.MeshDeviceCidrIncluded
                initially_connected = $initialConnected
                connected_after_proof = (Get-WarpConnected $warpCli)
                provider_write_attempted = $false
            }
            windows_routes = [ordered]@{
                cloudflare_interface_alias = [string]$warpAdapter.Name
                ordinary_ipv4_interface_alias = $baselineRoutes.OrdinaryIpv4InterfaceAlias
                ordinary_ipv4_cloudflare_owned = $baselineRoutes.OrdinaryIpv4CloudflareOwned
                ordinary_ipv4_owner_claim = 'NON_CLOUDFLARE_OBSERVED'
                mesh_connected_interface_alias = $baselineRoutes.MeshInterfaceAlias
                mesh_connected_cloudflare_owned = $baselineRoutes.MeshCloudflareOwned
                mesh_disconnected_interface_alias = if ($disconnectedRoutes) { $disconnectedRoutes.MeshInterfaceAlias } else { $null }
                mesh_reconnected_interface_alias = $reconnectedRoutes.MeshInterfaceAlias
                mesh_reconnected_cloudflare_owned = $reconnectedRoutes.MeshCloudflareOwned
                warp_route_set_restored = $routeSetRestored
                ordinary_ipv6_present = $baselineRoutes.OrdinaryIpv6Present
                ordinary_ipv6_interface_alias = $baselineRoutes.OrdinaryIpv6InterfaceAlias
                ordinary_ipv6_cloudflare_owned = $baselineRoutes.OrdinaryIpv6CloudflareOwned
                ipv6_owner_differs_from_ipv4 = $ipv6OwnerDiffers
            }
            windows_dns = [ordered]@{
                cloudflare_dns_mode = $false
                non_cloudflare_dns_stable = $dnsStable
            }
            recovery = [ordered]@{
                requested = [bool]$Recovery
                disconnect_observed = $disconnectObserved
                reconnect_observed = $reconnectObserved
            }
            boundaries = [ordered]@{
                android_required = $false
                mesh_peer_required = $false
                e3_claimed = $false
                e4_claimed = $false
                product_ready_claimed = $false
                sing_box_ordinary_ipv4_ownership_proven = $false
            }
        }
    }

    $written = Write-CloudflareJson $evidence $EvidencePath
    return [pscustomobject]@{
        result = 'PASS'
        evidence = $written
        client_version = $clientVersion
        mode = $settings.Mode
        tunnel_protocol = $settings.Protocol
        mesh_device_cidr = $MeshDeviceCidr
        mesh_cloudflare_owned = $baselineRoutes.MeshCloudflareOwned
        ordinary_ipv4_cloudflare_owned = $baselineRoutes.OrdinaryIpv4CloudflareOwned
        sing_box_ordinary_ipv4_ownership_proven = $false
    }
}

Export-ModuleMember -Function Invoke-CloudflareWindowsProof
