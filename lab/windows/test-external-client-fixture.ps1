param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'external-client-fixture.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)] $Actual,
        [Parameter(Mandatory = $true)] $Expected,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if ($Actual -ne $Expected) {
        throw "$Message Expected=[$Expected] Actual=[$Actual]"
    }
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)] [bool] $Condition,
        [Parameter(Mandatory = $true)] [string] $Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "External client fixture manifest is missing: $ManifestPath"
}

$raw = Get-Content -Raw -LiteralPath $ManifestPath
$fixture = $raw | ConvertFrom-Json

Assert-Equal $fixture.schema 'mish.external-client-fixture/v1' 'Unexpected external client fixture schema.'
Assert-Equal $fixture.verified_date '2026-09-13' 'D3 vendor verification date drifted without explicit fixture review.'
Assert-Equal $fixture.m1_transport_contract.product_transport 'tcp-only' 'M1 transport contract must remain TCP-only.'
Assert-Equal ([bool]$fixture.m1_transport_contract.udp_quic_product_support) $false 'M1 must not claim PRODUCT UDP/QUIC support.'
Assert-Equal ([bool]$fixture.m1_transport_contract.phone_wifi_security_invariant) $false 'Phone Wi-Fi state must not become a security invariant.'

$surface = @($fixture.m1_transport_contract.proxy_surface)
Assert-Equal $surface.Count 3 'M1 external fixture must expose exactly three PRODUCT proxy listener contracts.'
Assert-Equal (($surface | ForEach-Object { [int]$_.port }) -join ',') '1080,1081,3128' 'PRODUCT proxy ports drifted.'
foreach ($listener in $surface) {
    Assert-Equal ([string]$listener.transport) 'tcp' "PRODUCT listener $($listener.port) must remain TCP-only in M1."
}

Assert-Equal $fixture.kameleo.engine_version '5.2.1' 'Pinned Kameleo Engine version drifted.'
Assert-Equal $fixture.kameleo.chroma.kernel_release 'Chroma 152' 'Pinned Kameleo Chroma release drifted.'
Assert-Equal $fixture.kameleo.chroma.upstream_version '152.0.7977.54' 'Pinned Kameleo Chromium basis drifted.'
Assert-True (@($fixture.kameleo.chroma.browser_settings.arguments) -contains '--disable-quic') 'Kameleo Chroma fixture must disable QUIC explicitly.'
Assert-Equal $fixture.kameleo.chroma.browser_settings.preferences.'webrtc.ip_handling_policy' 'disable_non_proxied_udp' 'Kameleo Chroma WebRTC must reject non-proxied UDP.'

Assert-Equal $fixture.kameleo.junglefox.kernel_release 'Junglefox 153' 'Pinned Kameleo Junglefox release drifted.'
Assert-Equal $fixture.kameleo.junglefox.upstream_version '153.0' 'Pinned Kameleo Firefox basis drifted.'
Assert-Equal ([bool]$fixture.kameleo.junglefox.browser_settings.preferences.'media.peerconnection.ice.proxy_only') $true 'Kameleo Junglefox WebRTC must be proxy-only.'
Assert-Equal ([bool]$fixture.kameleo.junglefox.browser_settings.preferences.'network.http.http3.enable') $false 'Kameleo Junglefox HTTP/3 must be disabled.'

Assert-Equal $fixture.camoufox.browser_version 'v152.0.4-beta.30' 'Pinned Camoufox browser release drifted.'
Assert-Equal $fixture.camoufox.python_package_version '0.5.6' 'Pinned Camoufox Python package version drifted.'
Assert-Equal ([bool]$fixture.camoufox.launch_settings.block_webrtc) $true 'Camoufox WebRTC must be disabled for the M1 fixture.'
Assert-Equal ([bool]$fixture.camoufox.launch_settings.firefox_user_prefs.'network.http.http3.enable') $false 'Camoufox HTTP/3 must be disabled through Firefox user preferences.'

foreach ($source in @(
    [string]$fixture.kameleo.sources.engine,
    [string]$fixture.kameleo.sources.kernels,
    [string]$fixture.kameleo.sources.webrtc,
    [string]$fixture.kameleo.sources.arguments,
    [string]$fixture.kameleo.sources.blacklist,
    [string]$fixture.camoufox.sources.release,
    [string]$fixture.camoufox.sources.usage,
    [string]$fixture.camoufox.sources.webrtc,
    [string]$fixture.camoufox.sources.playwright_firefox_prefs
)) {
    Assert-True ($source.StartsWith('https://', [System.StringComparison]::Ordinal)) "Fixture source must use HTTPS: $source"
}

foreach ($forbiddenProperty in @('phone_wifi_mode', 'disable_phone_wifi', 'enable_udp', 'udp_associate')) {
    Assert-True (-not ($fixture.m1_transport_contract.PSObject.Properties.Name -contains $forbiddenProperty)) "M1 fixture must not add $forbiddenProperty as a transport/security control."
}

Write-Output 'EXTERNAL_CLIENT_TCP_FIXTURE=PASS'
