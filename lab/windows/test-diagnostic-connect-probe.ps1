Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'DiagnosticConnectProbe.psm1') -Force

function Assert-Equal {
    param(
        [Parameter(Mandatory)] $Actual,
        [Parameter(Mandatory)] $Expected,
        [Parameter(Mandatory)][string] $Label
    )
    if ($Actual -cne $Expected) {
        throw "$Label expected '$Expected' but got '$Actual'."
    }
}

$ok = Convert-MishProxyStatusLine -StatusLine 'HTTP/1.1 200 Connection established'
Assert-Equal $ok.result 'PASS' '2xx result'
Assert-Equal $ok.reason 'NONE' '2xx reason'

$auth = Convert-MishProxyStatusLine -StatusLine 'HTTP/1.1 407 Proxy Authentication Required'
Assert-Equal $auth.result 'FAIL' '407 result'
Assert-Equal $auth.reason 'AUTHENTICATION_FAILED' '407 reason'

$upstream = Convert-MishProxyStatusLine -StatusLine 'HTTP/1.1 502 Bad Gateway'
Assert-Equal $upstream.result 'FAIL' '502 result'
Assert-Equal $upstream.reason 'HTTP_502' '502 reason'

$malformed = Convert-MishProxyStatusLine -StatusLine 'not-http'
Assert-Equal $malformed.result 'FAIL' 'malformed result'
Assert-Equal $malformed.reason 'MALFORMED_PROXY_RESPONSE' 'malformed reason'

# Reserve then release an ephemeral loopback port so the transport path executes without
# requiring any external service. Nothing listening there must be classified at the listener phase.
$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$listener.Start()
$closedPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
$listener.Stop()
$password = ConvertTo-SecureString 'synthetic-secret' -AsPlainText -Force
$closed = Invoke-MishDiagnosticProxyConnectProbe `
    -ProxyHost '127.0.0.1' `
    -ProxyPort $closedPort `
    -ProxyUserName 'synthetic-user' `
    -ProxyPassword $password `
    -TimeoutMs 1000
Assert-Equal $closed.result 'FAIL' 'closed listener result'
if ([string]$closed.reason -notin @('LISTENER_CONNECT_FAILED', 'LISTENER_CONNECT_TIMEOUT')) {
    throw "Closed listener must fail at the listener phase, got '$([string]$closed.reason)'."
}

$serialized = $closed | ConvertTo-Json -Compress
if ($serialized.Contains('synthetic-user') -or $serialized.Contains('synthetic-secret')) {
    throw 'Diagnostic result must never expose proxy credentials.'
}

Write-Host 'Diagnostic CONNECT attribution regression test passed.'
