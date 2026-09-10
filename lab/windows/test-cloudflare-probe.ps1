[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$modulePath = Join-Path $PSScriptRoot 'CloudflareProbe.psm1'
Import-Module $modulePath -Force
$module = Get-Module CloudflareProbe

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

$settings = @'
Merged configuration:
(derived)       Always On: true
(network policy) Mode: TunnelOnly
(network policy) WARP tunnel protocol: MASQUE
(network policy) Include mode, with hosts/ips:
  100.96.0.0/12 (Cloudflare Mesh device range)
(user set)      Organization: example-org
(network policy) Profile ID: 00000000-0000-0000-0000-000000000001
'@

$projection = & $module {
    param($Text)
    ConvertFrom-WarpSettingsText $Text '100.96.0.0/12'
} $settings

Assert-True ($projection.Mode -eq 'TunnelOnly') 'TunnelOnly parser mismatch.'
Assert-True ($projection.Protocol -eq 'MASQUE') 'MASQUE parser mismatch.'
Assert-True ($projection.SplitTunnelMode -eq 'Include') 'Include-mode parser mismatch.'
Assert-True $projection.MeshDeviceCidrIncluded 'Mesh CIDR parser mismatch.'
Assert-True $projection.OrganizationConfigured 'Organization presence was not projected.'
Assert-True $projection.ProfileApplied 'Profile presence was not projected.'

$networkAddress = & $module {
    Get-Ipv4CidrNetworkAddress '100.97.23.4/12'
}
Assert-True ($networkAddress -eq '100.96.0.0') 'IPv4 CIDR network calculation mismatch.'

$connected = & $module {
    Test-WarpConnectedText "Status update: Connected`r`n"
}
Assert-True $connected 'Connected status parser mismatch.'

$disconnected = & $module {
    Test-WarpConnectedText "Status update: Disconnected`r`n"
}
Assert-True (-not $disconnected) 'Disconnected status must not parse as connected.'

$wrongMode = $settings.Replace('Mode: TunnelOnly', 'Mode: WarpWithDnsOverHttps')
$modeRejected = $false
try {
    & $module {
        param($Text)
        ConvertFrom-WarpSettingsText $Text '100.96.0.0/12' | Out-Null
    } $wrongMode
}
catch {
    $modeRejected = $_.Exception.Message -match '^MISH_LABCTL_FAILURE\|OBSERVATION_CONTRADICTION\|'
}
Assert-True $modeRejected 'Traffic-and-DNS mode must fail closed.'

$wireGuard = $settings.Replace('WARP tunnel protocol: MASQUE', 'WARP tunnel protocol: WireGuard')
$protocolRejected = $false
try {
    & $module {
        param($Text)
        ConvertFrom-WarpSettingsText $Text '100.96.0.0/12' | Out-Null
    } $wireGuard
}
catch {
    $protocolRejected = $_.Exception.Message -match '^MISH_LABCTL_FAILURE\|OBSERVATION_CONTRADICTION\|'
}
Assert-True $protocolRejected 'Unapproved WireGuard fallback must fail closed.'

$missingMesh = $settings.Replace('100.96.0.0/12 (Cloudflare Mesh device range)', '10.0.0.0/8')
$meshRejected = $false
try {
    & $module {
        param($Text)
        ConvertFrom-WarpSettingsText $Text '100.96.0.0/12' | Out-Null
    } $missingMesh
}
catch {
    $meshRejected = $_.Exception.Message -match '^MISH_LABCTL_FAILURE\|OBSERVATION_CONTRADICTION\|'
}
Assert-True $meshRejected 'Missing accepted Mesh CIDR must fail closed.'

$secretShaped = $settings + "`nToken: must-not-be-projected`nPassword: must-not-be-projected`n"
$secretProjection = & $module {
    param($Text)
    ConvertFrom-WarpSettingsText $Text '100.96.0.0/12'
} $secretShaped
$projectionText = $secretProjection | ConvertTo-Json -Compress
Assert-True (-not $projectionText.Contains('must-not-be-projected')) 'Parser projection leaked arbitrary settings values.'
Assert-True (-not $projectionText.Contains('Token')) 'Parser projection leaked token-shaped input.'
Assert-True (-not $projectionText.Contains('Password')) 'Parser projection leaked password-shaped input.'

Write-Host 'CLOUDFLARE_WINDOWS_PROBE_TESTS=PASS'
exit 0
