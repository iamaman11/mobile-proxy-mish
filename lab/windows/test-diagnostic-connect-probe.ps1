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

# Reserve then release an ephemeral loopback port so every client entry point executes its bounded
# listener-connect path without requiring any external service. Nothing listening there must be
# attributed to the listener phase, never to auth/relay semantics.
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
Assert-Equal $closed.result 'FAIL' 'closed CONNECT listener result'
if ([string]$closed.reason -notin @('LISTENER_CONNECT_FAILED', 'LISTENER_CONNECT_TIMEOUT')) {
    throw "Closed CONNECT listener must fail at the listener phase, got '$([string]$closed.reason)'."
}

$httpRelayClosed = Invoke-MishDiagnosticHttpRelayProbe `
    -ProxyHost '127.0.0.1' `
    -ProxyPort $closedPort `
    -ProxyUserName 'synthetic-user' `
    -ProxyPassword $password `
    -TimeoutMs 1000
Assert-Equal $httpRelayClosed.result 'FAIL' 'closed HTTP relay listener result'
Assert-Equal $httpRelayClosed.reason 'LISTENER_CONNECT_FAILED' 'closed HTTP relay listener reason'

$socksRelayClosed = Invoke-MishDiagnosticSocks5RelayProbe `
    -ProxyHost '127.0.0.1' `
    -ProxyPort $closedPort `
    -ProxyUserName 'synthetic-user' `
    -ProxyPassword $password `
    -TimeoutMs 1000
Assert-Equal $socksRelayClosed.result 'FAIL' 'closed SOCKS relay listener result'
Assert-Equal $socksRelayClosed.reason 'LISTENER_CONNECT_FAILED' 'closed SOCKS relay listener reason'

$serialized = @($closed, $httpRelayClosed, $socksRelayClosed) | ConvertTo-Json -Depth 4 -Compress
if ($serialized.Contains('synthetic-user') -or $serialized.Contains('synthetic-secret')) {
    throw 'Diagnostic result must never expose proxy credentials.'
}

$moduleSource = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'DiagnosticConnectProbe.psm1')
foreach ($required in @(
    'Invoke-MishDiagnosticHttpRelayProbe',
    'Invoke-MishDiagnosticSocks5RelayProbe',
    'INVALID_AUTH_NOT_REJECTED',
    'AUTH_REJECTED',
    'RELAY_CONFIRMED',
    'GET / HTTP/1.1'
)) {
    if (-not $moduleSource.Contains($required)) {
        throw "U2 protocol probe module lost required bounded behavior: $required"
    }
}
foreach ($forbidden in @(
    'ProcessBuilder',
    'su -c',
    'pkill',
    'kill -9'
)) {
    if ($moduleSource.Contains($forbidden)) {
        throw "Diagnostic protocol probe must remain unprivileged and effect-bounded: $forbidden"
    }
}

Write-Host 'Diagnostic CONNECT/protocol attribution regression test passed.'
