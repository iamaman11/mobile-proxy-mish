[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [ValidateRange(10, 30)][int] $NavigationTimeoutSeconds = 20,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8g-final-clean-client-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.u8g-final-clean-client/v1'
$script:DnsProofUrls = @(
    'https://example.com/',
    'https://example.org/',
    'https://example.net/',
    'https://www.iana.org/'
)
$script:EgressUrls = @(
    'https://example.com/',
    'https://checkip.amazonaws.com/',
    'https://api.ipify.org/'
)
$script:PublicIpUrls = @(
    'https://checkip.amazonaws.com/',
    'https://api.ipify.org/'
)

function Stop-MishU8GFinal {
    param([Parameter(Mandatory)][string] $Classification, [Parameter(Mandatory)][string] $Message)
    throw "MISH_U8G_FINAL_FAILURE|$Classification|$Message"
}

function Invoke-MishAdbText {
    param([Parameter(Mandatory)][string[]] $Arguments, [string] $Operation = 'adb')
    $rows = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) { Stop-MishU8GFinal 'LAB_ADB_FAILED' "ADB operation '$Operation' failed." }
    return ($rows -join [Environment]::NewLine).Trim()
}

function Read-MishProductSnapshot {
    $raw = Invoke-MishAdbText -Operation 'product_snapshot' -Arguments @(
        'shell', 'content', 'call', '--uri', "content://$PackageName.diagnostics", '--method', 'snapshot_v2'
    )
    $match = [regex]::Match($raw, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { Stop-MishU8GFinal 'LAB_DIAGNOSTIC_PAYLOAD_MISSING' 'PRODUCT diagnostics returned no payload.' }
    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch { Stop-MishU8GFinal 'LAB_DIAGNOSTIC_PAYLOAD_INVALID' 'PRODUCT diagnostics payload is invalid.' }
    finally { if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) } }
}

function Test-MishProductReady {
    param([Parameter(Mandatory)] $Snapshot)
    return (
        [bool]$Snapshot.consistent -and
        [bool]$Snapshot.runtime.running -and
        [bool]$Snapshot.cellular.admitted -and
        [bool]$Snapshot.root.policy_authorized -and
        [string]$Snapshot.proxy.state -ceq 'RUNNING' -and
        [bool]$Snapshot.proxy.healthy -and
        [bool]$Snapshot.credential.active -and
        [bool]$Snapshot.mesh.admitted -and
        [bool]$Snapshot.mesh.ingress_running -and
        [string]$Snapshot.readiness.state -ceq 'READY'
    )
}

function Get-MishDnsObservation {
    param([Parameter(Mandatory)] $Snapshot)
    if ($null -eq $Snapshot.cellular -or $null -eq $Snapshot.cellular.dns -or -not [bool]$Snapshot.cellular.dns.available) {
        Stop-MishU8GFinal 'PRODUCT_DNS_OBSERVATION_UNAVAILABLE' 'Typed PRODUCT DNS diagnostics are unavailable.'
    }
    $dns = $Snapshot.cellular.dns
    return [ordered]@{
        started = [int64]$dns.started
        completed = [int64]$dns.completed
        accepted_current = [int64]$dns.accepted_current
        resolver_failed = [int64]$dns.resolver_failed
        discarded_after_deadline = [int64]$dns.discarded_after_deadline
        discarded_stale = [int64]$dns.discarded_stale
        authority_validation_failed = [int64]$dns.authority_validation_failed
        unusable_result = [int64]$dns.unusable_result
    }
}

function New-MishDnsDelta {
    param([Parameter(Mandatory)] $Before, [Parameter(Mandatory)] $After)
    return [ordered]@{
        started = [int64]$After.started - [int64]$Before.started
        completed = [int64]$After.completed - [int64]$Before.completed
        accepted_current = [int64]$After.accepted_current - [int64]$Before.accepted_current
        resolver_failed = [int64]$After.resolver_failed - [int64]$Before.resolver_failed
        discarded_after_deadline = [int64]$After.discarded_after_deadline - [int64]$Before.discarded_after_deadline
        discarded_stale = [int64]$After.discarded_stale - [int64]$Before.discarded_stale
        authority_validation_failed = [int64]$After.authority_validation_failed - [int64]$Before.authority_validation_failed
        unusable_result = [int64]$After.unusable_result - [int64]$Before.unusable_result
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
    }
    catch { return $false }
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
    if ($addresses.Count -ne 1) { Stop-MishU8GFinal 'LAB_MESH_ENDPOINT_AMBIGUOUS' 'Exactly one Android Mesh endpoint is required.' }
    return [string]$addresses[0]
}

function Get-MishDnsCacheNames {
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    try {
        $entries = @(Get-DnsClientCache -ErrorAction Stop)
    }
    catch {
        Stop-MishU8GFinal 'WINDOWS_DNS_CACHE_OBSERVER_UNAVAILABLE' 'Get-DnsClientCache is unavailable to the LAB runner identity.'
    }

    foreach ($entry in $entries) {
        $name = $null
        foreach ($propertyName in @('Entry', 'RecordName', 'Name')) {
            $property = $entry.PSObject.Properties[$propertyName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $name = [string]$property.Value
                break
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            [void]$names.Add($name.Trim().TrimEnd('.'))
        }
    }
    return $names
}

function Select-MishCleanDnsProofUrl {
    param([string] $ExcludeHost)

    $cache = Get-MishDnsCacheNames
    foreach ($url in $script:DnsProofUrls) {
        $hostName = ([Uri]$url).DnsSafeHost
        if (-not [string]::IsNullOrWhiteSpace($ExcludeHost) -and $hostName -ieq $ExcludeHost) {
            continue
        }
        if (-not $cache.Contains($hostName)) {
            return [string]$url
        }
    }
    Stop-MishU8GFinal 'WINDOWS_DNS_CACHE_NO_CLEAN_TARGET' 'No uncached bounded DNS proof target is available.'
}
function Resolve-MishCamoufoxToolchain {
    $manifestPath = Join-Path $PSScriptRoot 'u8g-camoufox-toolchain.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Stop-MishU8GFinal 'CAMOUFOX_MANIFEST_MISSING' 'Canonical Camoufox toolchain manifest is unavailable.' }
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    $venvRoot = [IO.Path]::GetFullPath([string]$manifest.python_env.install_root)
    $browserRoot = [IO.Path]::GetFullPath([string]$manifest.browser.install_root)
    $pythonExe = Join-Path $venvRoot 'Scripts\python.exe'
    $markerPath = Join-Path $browserRoot '.mish-u8g-browser.json'
    if (-not (Test-Path -LiteralPath $pythonExe -PathType Leaf) -or -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        Stop-MishU8GFinal 'CAMOUFOX_TOOLCHAIN_MISSING' 'LAB-owned Camoufox runtime is incomplete.'
    }
    $marker = Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json
    if ([string]$marker.schema -cne 'mish.lab.u8g-camoufox-browser/v1' -or [string]$marker.identity_source -cne 'official_archive_sha256' -or [string]$marker.version -cne [string]$manifest.browser.version) {
        Stop-MishU8GFinal 'CAMOUFOX_TOOLCHAIN_DRIFT' 'LAB-owned Camoufox marker does not match the manifest.'
    }
    $browserExe = Join-Path $browserRoot ([string]$marker.executable_relative_path)
    if (-not (Test-Path -LiteralPath $browserExe -PathType Leaf)) { Stop-MishU8GFinal 'CAMOUFOX_BROWSER_MISSING' 'LAB-owned Camoufox executable is unavailable.' }
    return [pscustomobject]@{ PythonExe = $pythonExe; BrowserExe = $browserExe; BrowserVersion = [string]$manifest.browser.version }
}


function ConvertTo-MishPublicIp {
    param([Parameter(Mandatory)][string] $Value)

    $trimmed = $Value.Trim()
    $parsed = $null
    if (
        [string]::IsNullOrWhiteSpace($trimmed) -or
        $trimmed -match '\s' -or
        -not [Net.IPAddress]::TryParse($trimmed, [ref]$parsed)
    ) {
        Stop-MishU8GFinal 'EXTERNAL_IP_RESPONSE_INVALID' 'External IP observer returned a non-IP body.'
    }
    return $parsed.ToString()
}

function Invoke-MishPublicIpPair {
    param(
        [string] $ProxyServer,
        [string] $ProxyUserName,
        [Security.SecureString] $ProxyPassword
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $client = $null
    $plainPassword = $null
    try {
        if (-not [string]::IsNullOrWhiteSpace($ProxyServer)) {
            if ([string]::IsNullOrWhiteSpace($ProxyUserName) -or $null -eq $ProxyPassword) {
                Stop-MishU8GFinal 'EXTERNAL_IP_PROXY_CREDENTIAL_MISSING' 'Proxy public-IP observation requires credentials.'
            }
            $plainPassword = [Net.NetworkCredential]::new('', $ProxyPassword).Password
            $proxy = [Net.WebProxy]::new($ProxyServer)
            $proxy.Credentials = [Net.NetworkCredential]::new($ProxyUserName, $plainPassword)
            $handler.UseProxy = $true
            $handler.Proxy = $proxy
        }
        else {
            $handler.UseProxy = $false
        }

        $client = [Net.Http.HttpClient]::new($handler, $true)
        $handler = $null
        $client.Timeout = [TimeSpan]::FromSeconds($NavigationTimeoutSeconds)

        $addresses = @()
        foreach ($url in $script:PublicIpUrls) {
            try {
                $body = $client.GetStringAsync($url).GetAwaiter().GetResult()
            }
            catch [System.Threading.Tasks.TaskCanceledException] {
                Stop-MishU8GFinal 'EXTERNAL_IP_TIMEOUT' 'External IP observation exceeded the bounded deadline.'
            }
            catch [System.Net.Http.HttpRequestException] {
                Stop-MishU8GFinal 'EXTERNAL_IP_REQUEST_FAILED' 'External IP observation failed.'
            }
            $addresses += (ConvertTo-MishPublicIp -Value $body)
        }

        if ($addresses.Count -ne 2) {
            Stop-MishU8GFinal 'EXTERNAL_IP_OBSERVER_COUNT' 'Exactly two external IP observers are required.'
        }
        return [pscustomobject]@{
            First = [string]$addresses[0]
            Second = [string]$addresses[1]
            Consensus = ([string]$addresses[0] -ceq [string]$addresses[1])
        }
    }
    finally {
        $plainPassword = $null
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
    }
}

function Get-MishBrowserEgressClassification {
    param(
        [Parameter(Mandatory)][string] $BrowserAddress,
        [Parameter(Mandatory)][string] $ExpectedProxyAddress,
        [Parameter(Mandatory)][string] $HostDefaultAddress
    )

    $matchesExpected = $BrowserAddress -ceq $ExpectedProxyAddress
    $matchesHost = $BrowserAddress -ceq $HostDefaultAddress
    $classification = if ($matchesExpected -and -not $matchesHost) {
        'EXPECTED_PROXY_EGRESS'
    }
    elseif (-not $matchesExpected -and $matchesHost) {
        'HOST_DEFAULT'
    }
    elseif ($matchesExpected -and $matchesHost) {
        'AMBIGUOUS_PROXY_EQUALS_HOST'
    }
    else {
        'UNKNOWN'
    }

    return [pscustomobject]@{
        Classification = $classification
        MatchesExpectedProxy = $matchesExpected
        MatchesHostDefault = $matchesHost
    }
}

function Invoke-MishCamoufoxWindow {
    param(
        [Parameter(Mandatory)] $Toolchain,
        [Parameter(Mandatory)][string] $ProxyServer,
        [Parameter(Mandatory)][string] $ProxyUserName,
        [Parameter(Mandatory)][Security.SecureString] $ProxyPassword,
        [Parameter(Mandatory)][string[]] $Urls,
        [Parameter(Mandatory)][string] $WindowName
    )

    $runtimeBase = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
    $runtimeRoot = Join-Path $runtimeBase ('mish-u8g-final-' + $WindowName + '-' + [guid]::NewGuid().ToString('N'))
    $localAppData = Join-Path $runtimeRoot 'localappdata'
    $appData = Join-Path $runtimeRoot 'appdata'
    $userProfile = Join-Path $runtimeRoot 'userprofile'
    New-Item -ItemType Directory -Force -Path $localAppData, $appData, $userProfile | Out-Null

    $pythonPath = Join-Path $runtimeRoot 'window.py'
    $python = @'
import ipaddress
import json
import os
import re
import sys
import traceback
from camoufox.sync_api import Camoufox

exe = sys.argv[1]
urls = json.loads(os.environ["MISH_U8G_URLS_JSON"])
proxy = {
    "server": os.environ["MISH_U8G_PROXY_SERVER"],
    "username": os.environ["MISH_U8G_PROXY_USER"],
    "password": os.environ["MISH_U8G_PROXY_PASSWORD"],
}
prefs = {
    "network.trr.mode": 5,
    "network.dns.disablePrefetch": True,
    "network.prefetch-next": False,
    "network.predictor.enabled": False,
    "network.http.speculative-parallel-limit": 0,
    "network.http.http3.enable": False,
}
def sanitize_text(value, limit=2048):
    if value is None:
        return None
    text = value if isinstance(value, str) else ""
    for secret in (
        os.environ.get("MISH_U8G_PROXY_PASSWORD", ""),
        os.environ.get("MISH_U8G_PROXY_USER", ""),
        os.environ.get("MISH_U8G_PROXY_SERVER", ""),
        os.environ.get("HOME", ""),
        os.environ.get("USERPROFILE", ""),
        os.environ.get("LOCALAPPDATA", ""),
        os.environ.get("APPDATA", ""),
    ):
        if secret:
            text = text.replace(secret, "<REDACTED>")
    for url in urls:
        text = text.replace(url, "<URL>")
    text = re.sub(r"https?://[^\\s\\]\\[\\)\\(\\\"']+", "<URL>", text, flags=re.IGNORECASE)
    text = re.sub(r"(?<!\\d)(?:\\d{1,3}\\.){3}\\d{1,3}(?!\\d)", "<IP>", text)
    text = re.sub(r"(?i)[A-Z]:\\\\[^\\r\\n\\t]+", "<PATH>", text)
    text = re.sub(r"[\\r\\n\\t]+", " | ", text)
    return text[:limit]

def extract_error_code(exc):
    message = getattr(exc, "message", "") or ""
    match = re.search(r"\b(?:NS_ERROR|SEC_ERROR|MOZILLA_PKIX_ERROR|ERR)_[A-Z0-9_]+\b", message.upper())
    return None if match is None else match.group(0)

def classify_error(exc):
    message = getattr(exc, "message", "") or ""
    value = message.lower()
    rules = [
        (("proxy" in value and "auth" in value) or "407" in value, "PROXY_AUTH"),
        ("proxy" in value and ("connect" in value or "connection" in value), "PROXY_CONNECT"),
        ("ns_error_proxy" in value, "PROXY_CONNECT"),
        ("timed out" in value or "timeout" in value or "ns_error_net_timeout" in value, "TIMEOUT"),
        ("unknown host" in value or "name_not_resolved" in value or "ns_error_unknown_host" in value, "DNS"),
        ("certificate" in value or "ssl" in value or "tls" in value or "sec_error" in value, "TLS"),
        ("connection reset" in value or "net_reset" in value or "ns_error_net_reset" in value, "RESET"),
        ("connection refused" in value or "ns_error_connection_refused" in value, "REFUSED"),
        ("targetclosed" in value or "target closed" in value, "TARGET_CLOSED"),
    ]
    for matched, label in rules:
        if matched:
            return label
    return "PLAYWRIGHT_ERROR_OTHER"

result = {
    "result": "FAIL",    "stage": "LAUNCH",
    "error_class": None,
    "error_category": None,
    "error_code": None,
    "error_message_sanitized": None,
    "error_stack_sanitized": None,
    "request_count": 0,
    "response_count": 0,
    "response_statuses": [],
    "request_failure_present": False,
    "request_failure_code": None,
    "request_failure_message_sanitized": None,
    "browser_connected_after_error": None,
    "page_closed_after_error": None,
    "navigation_pass": False,
    "statuses": [],
    "egress_a": None,
    "egress_b": None,
}
def capture_error(exc):
    result["error_class"] = type(exc).__name__
    result["error_category"] = classify_error(exc)
    result["error_code"] = extract_error_code(exc)
    result["error_message_sanitized"] = sanitize_text(getattr(exc, "message", "") or "")
    result["error_stack_sanitized"] = sanitize_text(
        "".join(traceback.format_exception(type(exc), exc, exc.__traceback__)),
        4096,
    )

try:
    with Camoufox(
        headless=True,
        executable_path=exe,
        ff_version=152,
        geoip=False,
        block_webrtc=True,
        proxy=proxy,
        firefox_user_prefs=prefs,
        i_know_what_im_doing=True,
    ) as browser:
        page = None
        try:
            result["stage"] = "CONTEXT"
            page = browser.new_page()
            def on_request(request):
                result["request_count"] += 1
            def on_response(response):
                result["response_count"] += 1
                result["response_statuses"].append(response.status)
            def on_request_failed(request):
                failure = request.failure or ""
                result["request_failure_present"] = True
                result["request_failure_message_sanitized"] = sanitize_text(failure)
                match = re.search(r"\b(?:NS_ERROR|SEC_ERROR|MOZILLA_PKIX_ERROR|ERR)_[A-Z0-9_]+\b", failure.upper())
                result["request_failure_code"] = None if match is None else match.group(0)
            page.on("request", on_request)
            page.on("response", on_response)
            page.on("requestfailed", on_request_failed)
            for index, url in enumerate(urls):
                result["stage"] = f"NAVIGATION_{index}"
                response = page.goto(url, wait_until="domcontentloaded", timeout=20000)
                status = None if response is None else response.status
                result["statuses"].append(status)
                if response is None or status is None or status < 200 or status >= 400:
                    raise RuntimeError("navigation status outside accepted range")
                if index in (1, 2):
                    result["stage"] = f"EGRESS_PARSE_{index}"
                    value = page.locator("body").inner_text().strip()
                    ipaddress.ip_address(value)
                    if index == 1:
                        result["egress_a"] = value
                    else:
                        result["egress_b"] = value
            result["result"] = "PASS"
            result["stage"] = "COMPLETE"
            result["navigation_pass"] = True
        except BaseException as exc:
            capture_error(exc)
            try:
                result["browser_connected_after_error"] = bool(browser.is_connected())
            except BaseException:
                result["browser_connected_after_error"] = None
            try:
                result["page_closed_after_error"] = None if page is None else bool(page.is_closed())
            except BaseException:
                result["page_closed_after_error"] = None
except BaseException as exc:
    if result["error_class"] is None:
        capture_error(exc)
print(json.dumps(result, separators=(",", ":")))
if result["result"] != "PASS":
    sys.exit(20)
'@
    [IO.File]::WriteAllText($pythonPath, $python, [Text.UTF8Encoding]::new($false))

    $plainPassword = $null
    $previous = @{}
    foreach ($name in @('HOME','USERPROFILE','LOCALAPPDATA','APPDATA','MISH_U8G_PROXY_SERVER','MISH_U8G_PROXY_USER','MISH_U8G_PROXY_PASSWORD','MISH_U8G_URLS_JSON')) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        $plainPassword = [Net.NetworkCredential]::new('', $ProxyPassword).Password
        $env:HOME = $userProfile
        $env:USERPROFILE = $userProfile
        $env:LOCALAPPDATA = $localAppData
        $env:APPDATA = $appData
        $env:MISH_U8G_PROXY_SERVER = $ProxyServer
        $env:MISH_U8G_PROXY_USER = $ProxyUserName
        $env:MISH_U8G_PROXY_PASSWORD = $plainPassword
        $env:MISH_U8G_URLS_JSON = ($Urls | ConvertTo-Json -Compress)

        $raw = (& $Toolchain.PythonExe $pythonPath $Toolchain.BrowserExe 2>&1 | Out-String).Trim()
        $pythonExitCode = if ($null -eq $LASTEXITCODE) { -1 } else { [int]$LASTEXITCODE }
        $jsonLine = @($raw -split '[\r\n]+' | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1)
        if ($jsonLine.Count -ne 1) { Stop-MishU8GFinal 'CAMOUFOX_RESULT_INVALID' "Camoufox $WindowName emitted no unique JSON result." }
        try { $parsed = $jsonLine[0] | ConvertFrom-Json }
        catch { Stop-MishU8GFinal 'CAMOUFOX_RESULT_INVALID' "Camoufox $WindowName result was not valid JSON." }
        $parsed | Add-Member -NotePropertyName python_exit_code -NotePropertyValue $pythonExitCode -Force
        return $parsed
    }
    finally {
        $plainPassword = $null
        foreach ($name in $previous.Keys) {
            $value = $previous[$name]
            if ($null -eq $value) { Remove-Item ('Env:' + $name) -ErrorAction SilentlyContinue }
            else { Set-Item ('Env:' + $name) -Value $value }
        }
        if (Test-Path -LiteralPath $runtimeRoot) { Remove-Item -LiteralPath $runtimeRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-MishDnsWindow {
    param(
        [Parameter(Mandatory)] $Toolchain,
        [Parameter(Mandatory)][string] $ProxyServer,
        [Parameter(Mandatory)] $Lease,
        [Parameter(Mandatory)][string] $DnsProofUrl,
        [Parameter(Mandatory)][string] $WindowName
    )

    $dnsProofHost = ([Uri]$DnsProofUrl).DnsSafeHost
    $cacheBefore = Get-MishDnsCacheNames
    if ($cacheBefore.Contains($dnsProofHost)) {
        Stop-MishU8GFinal 'WINDOWS_DNS_CACHE_TARGET_PREEXISTING' "DNS proof target was already present in Windows cache before $WindowName."
    }

    $snapshotBefore = Read-MishProductSnapshot
    if (-not (Test-MishProductReady -Snapshot $snapshotBefore)) {
        Stop-MishU8GFinal 'PRODUCT_NOT_READY' "PRODUCT is not READY before $WindowName DNS window."
    }
    $dnsBefore = Get-MishDnsObservation -Snapshot $snapshotBefore

    $browser = Invoke-MishCamoufoxWindow `
        -Toolchain $Toolchain `
        -ProxyServer $ProxyServer `
        -ProxyUserName ([string]$Lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$Lease.ProxyPassword) `
        -Urls @($DnsProofUrl) `
        -WindowName $WindowName

    $snapshotAfter = Read-MishProductSnapshot
    if (-not (Test-MishProductReady -Snapshot $snapshotAfter)) {
        Stop-MishU8GFinal 'PRODUCT_NOT_READY' "PRODUCT is not READY after $WindowName DNS window."
    }
    $dnsAfter = Get-MishDnsObservation -Snapshot $snapshotAfter
    $delta = New-MishDnsDelta -Before $dnsBefore -After $dnsAfter
    $cacheAfter = Get-MishDnsCacheNames
    $targetPresentAfter = $cacheAfter.Contains($dnsProofHost)

    $productDnsAdvanced = (
        [int64]$delta.started -gt 0 -and
        [int64]$delta.completed -gt 0 -and
        [int64]$delta.accepted_current -gt 0
    )
    $windowsNoBypass = -not $targetPresentAfter

    return [pscustomobject]@{
        Browser = $browser
        DnsProofHost = $dnsProofHost
        DnsDelta = $delta
        WindowsDns = [ordered]@{
            observer = 'Get-DnsClientCache'
            target_present_before = $false
            target_present_after = $targetPresentAfter
        }
        ProductDnsAdvanced = $productDnsAdvanced
        WindowsNoBypass = $windowsNoBypass
    }
}
if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) { Stop-MishU8GFinal 'LAB_ADB_MISSING' 'Canonical ADB executable is unavailable.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($identity -ine 'NT AUTHORITY\NETWORK SERVICE') {
    Stop-MishU8GFinal 'RUNNER_IDENTITY' 'Final U8-G acceptance must run under the canonical NetworkService Device Cycle runner.'
}
$devices = @(& $AdbPath devices | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) { Stop-MishU8GFinal 'DEVICE_UNAVAILABLE' 'Exactly one authorized DEVICE-1 is required.' }

Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DiagnosticConnectProbe.psm1') -Force

$preSnapshot = Read-MishProductSnapshot
if (-not (Test-MishProductReady -Snapshot $preSnapshot)) { Stop-MishU8GFinal 'PRODUCT_NOT_READY' 'PRODUCT baseline is not READY.' }
$meshAddress = Get-MishAndroidMeshAddress
$proxyServer = 'http://' + $meshAddress + ':3128'
$toolchain = Resolve-MishCamoufoxToolchain

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
$credentialStore = Join-Path $tempRoot ('mish-u8g-final-credential-' + [guid]::NewGuid().ToString('N') + '.dpapi')
$rotationEvidencePath = Join-Path $tempRoot ('mish-u8g-final-rotation-' + [guid]::NewGuid().ToString('N') + '.json')
$lease = $null
$plainPassword = $null
$beforeA = $null
$beforeB = $null
$afterA = $null
$afterB = $null
$beforeExpected = $null
$beforeHostDefault = $null
$afterExpected = $null
$afterHostDefault = $null

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStore)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStore
    if ($null -eq $lease) { Stop-MishU8GFinal 'CREDENTIAL_UNAVAILABLE' 'Bounded external proxy credential lease is unavailable.' }

    $authNegative = Invoke-MishDiagnosticHttpRelayProbe `
        -ProxyHost $meshAddress `
        -ProxyPort 3128 `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000 `
        -ExpectAuthRejection
    $authPositiveAfterNegative = Invoke-MishDiagnosticHttpRelayProbe `
        -ProxyHost $meshAddress `
        -ProxyPort 3128 `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 80 `
        -TimeoutMs 5000
    $authNegativePass = [string]$authNegative.result -ceq 'PASS' -and [string]$authNegative.reason -ceq 'AUTH_REJECTED'
    $validAfterNegativePass = [string]$authPositiveAfterNegative.result -ceq 'PASS'
    if (-not $authNegativePass -or -not $validAfterNegativePass) {
        Stop-MishU8GFinal 'AUTH_REGRESSION' ("Canonical HTTP relay auth probe failed: negative={0}/{1}; positive_after_negative={2}/{3}" -f
            [string]$authNegative.result,
            [string]$authNegative.reason,
            [string]$authPositiveAfterNegative.result,
            [string]$authPositiveAfterNegative.reason)
    }

    $httpsConnect = Invoke-MishDiagnosticProxyConnectProbe `
        -ProxyHost $meshAddress `
        -ProxyPort 3128 `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) `
        -TargetHost 'example.com' `
        -TargetPort 443 `
        -TimeoutMs 5000
    $httpsConnectPass = [string]$httpsConnect.result -ceq 'PASS'
    if (-not $httpsConnectPass) {
        Stop-MishU8GFinal 'HTTPS_CONNECT_REGRESSION' ("Canonical HTTP CONNECT :443 probe failed: result={0}; reason={1}" -f
            [string]$httpsConnect.result,
            [string]$httpsConnect.reason)
    }

    $beforeDnsUrl = Select-MishCleanDnsProofUrl
    $beforeWindow = Invoke-MishDnsWindow -Toolchain $toolchain -ProxyServer $proxyServer -Lease $lease -DnsProofUrl $beforeDnsUrl -WindowName 'before'

    $beforeExpected = Invoke-MishPublicIpPair `
        -ProxyServer $proxyServer `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword)
    $beforeHostDefault = Invoke-MishPublicIpPair
    if (-not [bool]$beforeExpected.Consensus -or -not [bool]$beforeHostDefault.Consensus) {
        Stop-MishU8GFinal 'EXTERNAL_EGRESS_REFERENCE_CONSENSUS_FAILED' 'Canonical proxy or host-default IP observers disagreed before rotation.'
    }

    $beforeEgress = Invoke-MishCamoufoxWindow -Toolchain $toolchain -ProxyServer $proxyServer -ProxyUserName ([string]$lease.ProxyUserName) -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) -Urls $script:EgressUrls -WindowName 'before-egress'
    $beforeA = [string]$beforeEgress.egress_a
    $beforeB = [string]$beforeEgress.egress_b
    $beforeEgressConsensus = (-not [string]::IsNullOrWhiteSpace($beforeA) -and $beforeA -ceq $beforeB)
    $beforeClassification = Get-MishBrowserEgressClassification `
        -BrowserAddress $beforeA `
        -ExpectedProxyAddress ([string]$beforeExpected.First) `
        -HostDefaultAddress ([string]$beforeHostDefault.First)

    if (-not [bool]$beforeWindow.ProductDnsAdvanced -or -not [bool]$beforeWindow.WindowsNoBypass) { Stop-MishU8GFinal 'DNS_NO_BYPASS_NOT_PROVEN' 'Pre-rotation clean-client DNS no-bypass contract was not proven.' }
    if (-not $beforeEgressConsensus) { Stop-MishU8GFinal 'EXTERNAL_EGRESS_CONSENSUS_FAILED' 'Independent browser egress observers disagreed before rotation.' }
    if ([string]$beforeClassification.Classification -cne 'EXPECTED_PROXY_EGRESS') {
        Stop-MishU8GFinal 'BROWSER_EGRESS_PATH_INVALID' ("Camoufox pre-rotation egress classification={0}." -f [string]$beforeClassification.Classification)
    }

    & (Join-Path $PSScriptRoot 'diagnose-u5-rotation.ps1') -AdbPath $AdbPath -PackageName $PackageName -SuccessfulOperations 1 -SkipShutdownRestoreAfterOn -EvidencePath $rotationEvidencePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $rotationEvidencePath -PathType Leaf)) { Stop-MishU8GFinal 'ROTATION_FAILED' 'Existing PRODUCT rotation owner did not produce bounded evidence.' }
    $rotationEvidence = Get-Content -Raw -LiteralPath $rotationEvidencePath | ConvertFrom-Json
    if ([string]$rotationEvidence.acceptance_result -cne 'PASS') { Stop-MishU8GFinal 'ROTATION_FAILED' 'Existing PRODUCT rotation owner did not pass.' }
    $operation = @($rotationEvidence.successful_operations)[0]
    if ($null -eq $operation) { Stop-MishU8GFinal 'ROTATION_EVIDENCE_INVALID' 'Rotation evidence contains no successful operation.' }
    $terminal = [string]$operation.terminal_result
    if ($terminal -notin @('CHANGED','UNCHANGED')) { Stop-MishU8GFinal 'ROTATION_TERMINAL_INVALID' 'Rotation terminal result is invalid.' }

    $beforeDnsHost = ([Uri]$beforeDnsUrl).DnsSafeHost
    $afterDnsUrl = Select-MishCleanDnsProofUrl -ExcludeHost $beforeDnsHost
    $afterWindow = Invoke-MishDnsWindow -Toolchain $toolchain -ProxyServer $proxyServer -Lease $lease -DnsProofUrl $afterDnsUrl -WindowName 'after'

    $afterExpected = Invoke-MishPublicIpPair `
        -ProxyServer $proxyServer `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword)
    $afterHostDefault = Invoke-MishPublicIpPair
    if (-not [bool]$afterExpected.Consensus -or -not [bool]$afterHostDefault.Consensus) {
        Stop-MishU8GFinal 'EXTERNAL_EGRESS_REFERENCE_CONSENSUS_FAILED' 'Canonical proxy or host-default IP observers disagreed after rotation.'
    }

    $afterEgress = Invoke-MishCamoufoxWindow -Toolchain $toolchain -ProxyServer $proxyServer -ProxyUserName ([string]$lease.ProxyUserName) -ProxyPassword ([Security.SecureString]$lease.ProxyPassword) -Urls $script:EgressUrls -WindowName 'after-egress'
    $afterA = [string]$afterEgress.egress_a
    $afterB = [string]$afterEgress.egress_b
    $afterEgressConsensus = (-not [string]::IsNullOrWhiteSpace($afterA) -and $afterA -ceq $afterB)
    $afterClassification = Get-MishBrowserEgressClassification `
        -BrowserAddress $afterA `
        -ExpectedProxyAddress ([string]$afterExpected.First) `
        -HostDefaultAddress ([string]$afterHostDefault.First)

    if (-not [bool]$afterWindow.ProductDnsAdvanced -or -not [bool]$afterWindow.WindowsNoBypass) { Stop-MishU8GFinal 'DNS_NO_BYPASS_NOT_PROVEN' 'Post-rotation clean-client DNS no-bypass contract was not proven.' }
    if (-not $afterEgressConsensus) { Stop-MishU8GFinal 'EXTERNAL_EGRESS_CONSENSUS_FAILED' 'Independent browser egress observers disagreed after rotation.' }
    if ([string]$afterClassification.Classification -cne 'EXPECTED_PROXY_EGRESS') {
        Stop-MishU8GFinal 'BROWSER_EGRESS_PATH_INVALID' ("Camoufox post-rotation egress classification={0}." -f [string]$afterClassification.Classification)
    }

    $externalOutcome = if ([string]$beforeExpected.First -cne [string]$afterExpected.First) { 'CHANGED' } else { 'UNCHANGED' }
    $browserExternalOutcome = if ($beforeA -cne $afterA) { 'CHANGED' } else { 'UNCHANGED' }
    $rotationConsensus = ($terminal -ceq $externalOutcome -and $terminal -ceq $browserExternalOutcome)
    if (-not $rotationConsensus) { Stop-MishU8GFinal 'ROTATION_EXTERNAL_EGRESS_MISMATCH' 'Canonical proxy and Camoufox egress outcomes disagree with PRODUCT rotation terminal result.' }

    $postSnapshot = Read-MishProductSnapshot
    if (-not (Test-MishProductReady -Snapshot $postSnapshot)) { Stop-MishU8GFinal 'PRODUCT_NOT_READY' 'PRODUCT did not finish final U8-G acceptance in READY state.' }

    $evidence = [ordered]@{
        schema = $script:Schema
        collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
        control_sha = if ($env:GITHUB_SHA -match '^[0-9a-f]{40}$') { $env:GITHUB_SHA } else { $null }
        acceptance_result = 'PASS'
        classification = 'U8_G_FINAL_CLEAN_CLIENT_PASS'
        client_fixture = [ordered]@{
            browser = 'camoufox'
            browser_version = [string]$toolchain.BrowserVersion
            browser_mode = 'headless'
            interactive_session = $false
            profile = 'temporary_clean'
            proxy_mode = 'HTTP_CONNECT'
            proxy_port = 3128
            geoip = $false
            hidden_geoip_lookup = 'DISABLED'
            webrtc_blocked = $true
            firefox_doh_mode = 5
            speculative_dns_disabled = $true
        }
        auth = [ordered]@{
            owner = 'DiagnosticConnectProbe.psm1'
            wrong_auth_rejected = $authNegativePass
            wrong_auth_reason = [string]$authNegative.reason
            valid_after_negative = $validAfterNegativePass
            valid_after_negative_reason = [string]$authPositiveAfterNegative.reason
            https_connect_443 = $httpsConnectPass
            https_connect_443_reason = [string]$httpsConnect.reason
        }
        dns_before_rotation = [ordered]@{
            product_delta = $beforeWindow.DnsDelta
            product_dns_advanced = [bool]$beforeWindow.ProductDnsAdvanced
            windows_observer = [string]$beforeWindow.WindowsDns.observer
            clean_target_present_before = [bool]$beforeWindow.WindowsDns.target_present_before
            clean_target_present_after = [bool]$beforeWindow.WindowsDns.target_present_after
            no_bypass = [bool]$beforeWindow.WindowsNoBypass
        }
        egress_before_rotation = [ordered]@{
            browser_observers_agree = $beforeEgressConsensus
            canonical_proxy_observers_agree = [bool]$beforeExpected.Consensus
            host_default_observers_agree = [bool]$beforeHostDefault.Consensus
            matches_expected_proxy_egress = [bool]$beforeClassification.MatchesExpectedProxy
            matches_host_default_egress = [bool]$beforeClassification.MatchesHostDefault
            classification = [string]$beforeClassification.Classification
        }
        rotation = [ordered]@{
            operation_id = [int64]$operation.operation_id
            terminal_result = $terminal
            canonical_proxy_external_outcome = $externalOutcome
            browser_external_outcome = $browserExternalOutcome
            observer_consensus = $rotationConsensus
            requests = 1
        }
        dns_after_rotation = [ordered]@{
            product_delta = $afterWindow.DnsDelta
            product_dns_advanced = [bool]$afterWindow.ProductDnsAdvanced
            windows_observer = [string]$afterWindow.WindowsDns.observer
            clean_target_present_before = [bool]$afterWindow.WindowsDns.target_present_before
            clean_target_present_after = [bool]$afterWindow.WindowsDns.target_present_after
            no_bypass = [bool]$afterWindow.WindowsNoBypass
        }
        egress_after_rotation = [ordered]@{
            browser_observers_agree = $afterEgressConsensus
            canonical_proxy_observers_agree = [bool]$afterExpected.Consensus
            host_default_observers_agree = [bool]$afterHostDefault.Consensus
            matches_expected_proxy_egress = [bool]$afterClassification.MatchesExpectedProxy
            matches_host_default_egress = [bool]$afterClassification.MatchesHostDefault
            classification = [string]$afterClassification.Classification
        }
        post_state = [ordered]@{
            ready = $true
            runtime_generation = [int64]$postSnapshot.runtime.generation
            credential_version = [int64]$postSnapshot.credential.version
        }
        privacy = [ordered]@{
            raw_public_ip_persisted = $false
            raw_private_ip_persisted = $false
            raw_dns_server_persisted = $false
            proxy_credentials_persisted = $false
        }
        mutation = [ordered]@{
            product_code_changed = $false
            cloudflare_policy_changed = $false
            windows_route_changed = $false
            one_product_rotation_requested = $true
        }
    }

    $fullPath = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $fullPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($fullPath, (($evidence | ConvertTo-Json -Depth 16) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

    Write-Host 'MISH_U8G_FINAL_ACCEPTANCE=PASS'
    Write-Host 'MISH_U8G_FINAL_DNS_NO_BYPASS=PASS'
    Write-Host "MISH_U8G_FINAL_ROTATION=$terminal"
    Write-Host 'MISH_U8G_FINAL_EXTERNAL_EGRESS_CONSENSUS=PASS'
    Write-Host 'MISH_U8G_FINAL_RAW_ADDRESSES_PERSISTED=NO'
    Write-Host "MISH_U8G_FINAL_EVIDENCE=$fullPath"
}
finally {
    $plainPassword = $null
    $beforeA = $null
    $beforeB = $null
    $afterA = $null
    $afterB = $null
    $beforeExpected = $null
    $beforeHostDefault = $null
    $afterExpected = $null
    $afterHostDefault = $null
    $lease = $null
    if (Test-Path -LiteralPath $credentialStore -PathType Leaf) { Remove-Item -LiteralPath $credentialStore -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $rotationEvidencePath -PathType Leaf) { Remove-Item -LiteralPath $rotationEvidencePath -Force -ErrorAction SilentlyContinue }
}
