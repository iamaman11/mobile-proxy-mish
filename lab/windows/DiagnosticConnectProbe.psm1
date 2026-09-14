Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-MishProxyStatusLine {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $StatusLine)

    $match = [regex]::Match($StatusLine.Trim(), '^HTTP/1\.[01]\s+(?<code>\d{3})(?:\s|$)')
    if (-not $match.Success) {
        return [ordered]@{ result = 'FAIL'; reason = 'MALFORMED_PROXY_RESPONSE' }
    }

    $code = [int]$match.Groups['code'].Value
    if ($code -ge 200 -and $code -le 299) {
        return [ordered]@{ result = 'PASS'; reason = 'NONE' }
    }
    if ($code -eq 407) {
        return [ordered]@{ result = 'FAIL'; reason = 'AUTHENTICATION_FAILED' }
    }
    return [ordered]@{ result = 'FAIL'; reason = "HTTP_$code" }
}

function Read-MishProxyStatusLine {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][int] $MaxBytes
    )

    $bytes = [Collections.Generic.List[byte]]::new()
    while ($bytes.Count -lt $MaxBytes) {
        $value = $Stream.ReadByte()
        if ($value -lt 0) {
            return $null
        }
        $bytes.Add([byte]$value)
        $count = $bytes.Count
        if ($count -ge 2 -and $bytes[$count - 2] -eq 13 -and $bytes[$count - 1] -eq 10) {
            return [Text.Encoding]::ASCII.GetString($bytes.ToArray(), 0, $count - 2)
        }
    }
    return ''
}

function Invoke-MishDiagnosticProxyConnectProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)][int] $ProxyPort,
        [Parameter(Mandatory)][string] $ProxyUserName,
        [Parameter(Mandatory)][Security.SecureString] $ProxyPassword,
        [string] $TargetHost = 'example.com',
        [int] $TargetPort = 443,
        [ValidateRange(250, 15000)][int] $TimeoutMs = 5000
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $phase = 'LISTENER_CONNECT'
    $plainPassword = $null
    $authorization = $null
    try {
        $connectTask = $client.ConnectAsync($ProxyHost, $ProxyPort)
        if (-not $connectTask.Wait($TimeoutMs)) {
            return [ordered]@{ result = 'FAIL'; reason = 'LISTENER_CONNECT_TIMEOUT'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        if (-not $client.Connected) {
            return [ordered]@{ result = 'FAIL'; reason = 'LISTENER_CONNECT_FAILED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }

        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        $phase = 'REQUEST_WRITE'
        $plainPassword = [Net.NetworkCredential]::new('', $ProxyPassword).Password
        $credentialBytes = [Text.Encoding]::UTF8.GetBytes("${ProxyUserName}:$plainPassword")
        try {
            $authorization = [Convert]::ToBase64String($credentialBytes)
        }
        finally {
            [Array]::Clear($credentialBytes, 0, $credentialBytes.Length)
        }
        $authority = "${TargetHost}:$TargetPort"
        $request = "CONNECT $authority HTTP/1.1`r`nHost: $authority`r`nProxy-Authorization: Basic $authorization`r`nProxy-Connection: close`r`n`r`n"
        $requestBytes = [Text.Encoding]::ASCII.GetBytes($request)
        try {
            $stream.Write($requestBytes, 0, $requestBytes.Length)
            $stream.Flush()
        }
        finally {
            [Array]::Clear($requestBytes, 0, $requestBytes.Length)
            $request = $null
            $authorization = $null
            $plainPassword = $null
        }

        $phase = 'RESPONSE_READ'
        $statusLine = Read-MishProxyStatusLine -Stream $stream -MaxBytes 1024
        if ($null -eq $statusLine) {
            return [ordered]@{ result = 'FAIL'; reason = 'PROXY_CLOSED_BEFORE_STATUS'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        if ($statusLine.Length -eq 0) {
            return [ordered]@{ result = 'FAIL'; reason = 'MALFORMED_PROXY_RESPONSE'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        $classified = Convert-MishProxyStatusLine -StatusLine $statusLine
        return [ordered]@{
            result = [string]$classified.result
            reason = [string]$classified.reason
            elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
        }
    }
    catch [System.AggregateException] {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    catch [System.IO.IOException] {
        $reason = if ($_.Exception.InnerException -is [Net.Sockets.SocketException] -and
            $_.Exception.InnerException.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            "${phase}_TIMEOUT"
        } else {
            "${phase}_FAILED"
        }
        return [ordered]@{ result = 'FAIL'; reason = $reason; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    catch [Net.Sockets.SocketException] {
        $reason = if ($_.Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::TimedOut) {
            "${phase}_TIMEOUT"
        } else {
            "${phase}_FAILED"
        }
        return [ordered]@{ result = 'FAIL'; reason = $reason; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    finally {
        $plainPassword = $null
        $authorization = $null
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        $stopwatch.Stop()
    }
}

Export-ModuleMember -Function Convert-MishProxyStatusLine, Invoke-MishDiagnosticProxyConnectProbe
