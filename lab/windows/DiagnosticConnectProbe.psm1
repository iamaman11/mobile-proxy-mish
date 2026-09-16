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

function Read-MishExactBytes {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][ValidateRange(1, 4096)][int] $Count
    )

    $buffer = [byte[]]::new($Count)
    $offset = 0
    while ($offset -lt $Count) {
        $read = $Stream.Read($buffer, $offset, $Count - $offset)
        if ($read -le 0) {
            throw [System.IO.EndOfStreamException]::new('Stream closed before the bounded reply was complete.')
        }
        $offset += $read
    }
    return ,$buffer
}

function Read-MishHttpHeaderRemainder {
    param([Parameter(Mandatory)][System.IO.Stream] $Stream)

    for ($lineNumber = 0; $lineNumber -lt 64; $lineNumber++) {
        $line = Read-MishProxyStatusLine -Stream $Stream -MaxBytes 4096
        if ($null -eq $line) {
            throw [System.IO.EndOfStreamException]::new('HTTP header closed before the blank terminator.')
        }
        if ($line.Length -eq 0) {
            return
        }
    }
    throw [System.IO.InvalidDataException]::new('HTTP header exceeded the bounded line count.')
}

function Get-MishRelayHttpStatusCode {
    param([AllowNull()][string] $StatusLine)

    if ($null -eq $StatusLine) { return $null }
    $match = [regex]::Match($StatusLine.Trim(), '^HTTP/1\.[01]\s+(?<code>\d{3})(?:\s|$)')
    if (-not $match.Success) { return $null }
    $code = [int]$match.Groups['code'].Value
    if ($code -lt 100 -or $code -gt 599) { return $null }
    return $code
}

function Write-MishAscii {
    param(
        [Parameter(Mandatory)][System.IO.Stream] $Stream,
        [Parameter(Mandatory)][string] $Text
    )

    $bytes = [Text.Encoding]::ASCII.GetBytes($Text)
    try {
        $Stream.Write($bytes, 0, $bytes.Length)
        $Stream.Flush()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
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

function Invoke-MishDiagnosticHttpRelayProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)][int] $ProxyPort,
        [Parameter(Mandatory)][string] $ProxyUserName,
        [Parameter(Mandatory)][Security.SecureString] $ProxyPassword,
        [string] $TargetHost = 'example.com',
        [ValidateRange(1, 65535)][int] $TargetPort = 80,
        [ValidateRange(250, 15000)][int] $TimeoutMs = 5000,
        [switch] $ExpectAuthRejection
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $plainPassword = $null
    $authorization = $null
    $phase = 'LISTENER_CONNECT'
    try {
        $connectTask = $client.ConnectAsync($ProxyHost, $ProxyPort)
        if (-not $connectTask.Wait($TimeoutMs) -or -not $client.Connected) {
            return [ordered]@{ result = 'FAIL'; reason = 'LISTENER_CONNECT_FAILED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        $phase = 'HTTP_AUTH'
        $plainPassword = [Net.NetworkCredential]::new('', $ProxyPassword).Password
        if ($ExpectAuthRejection) {
            $plainPassword = "${plainPassword}__mish_invalid_auth__"
        }
        $credentialBytes = [Text.Encoding]::UTF8.GetBytes("${ProxyUserName}:$plainPassword")
        try {
            $authorization = [Convert]::ToBase64String($credentialBytes)
        }
        finally {
            [Array]::Clear($credentialBytes, 0, $credentialBytes.Length)
        }
        $authority = "${TargetHost}:$TargetPort"
        Write-MishAscii -Stream $stream -Text (
            "CONNECT $authority HTTP/1.1`r`n" +
            "Host: $authority`r`n" +
            "Proxy-Authorization: Basic $authorization`r`n" +
            "Proxy-Connection: keep-alive`r`n`r`n"
        )
        $authorization = $null
        $plainPassword = $null

        $statusLine = Read-MishProxyStatusLine -Stream $stream -MaxBytes 1024
        if ($null -eq $statusLine -or $statusLine.Length -eq 0) {
            return [ordered]@{ result = 'FAIL'; reason = 'PROXY_CLOSED_BEFORE_STATUS'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        $classified = Convert-MishProxyStatusLine -StatusLine $statusLine
        if ($ExpectAuthRejection) {
            if ([string]$classified.reason -ceq 'AUTHENTICATION_FAILED') {
                return [ordered]@{ result = 'PASS'; reason = 'AUTH_REJECTED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
            }
            return [ordered]@{ result = 'FAIL'; reason = 'INVALID_AUTH_NOT_REJECTED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        if ([string]$classified.result -cne 'PASS') {
            return [ordered]@{ result = 'FAIL'; reason = "CONNECT_$([string]$classified.reason)"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }

        $phase = 'HTTP_RELAY'
        Read-MishHttpHeaderRemainder -Stream $stream
        Write-MishAscii -Stream $stream -Text (
            "GET / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: close`r`n`r`n"
        )
        $relayStatusLine = Read-MishProxyStatusLine -Stream $stream -MaxBytes 1024
        $relayStatusCode = Get-MishRelayHttpStatusCode -StatusLine $relayStatusLine
        if ($null -eq $relayStatusCode) {
            return [ordered]@{ result = 'FAIL'; reason = 'RELAY_RESPONSE_INVALID'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        return [ordered]@{
            result = 'PASS'
            reason = 'RELAY_CONFIRMED'
            target_status_code = [int]$relayStatusCode
            elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
        }
    }
    catch [System.AggregateException] {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    catch [System.IO.IOException] {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    catch [Net.Sockets.SocketException] {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
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

function Invoke-MishDiagnosticSocks5RelayProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ProxyHost,
        [Parameter(Mandatory)][int] $ProxyPort,
        [Parameter(Mandatory)][string] $ProxyUserName,
        [Parameter(Mandatory)][Security.SecureString] $ProxyPassword,
        [string] $TargetHost = 'example.com',
        [ValidateRange(1, 65535)][int] $TargetPort = 80,
        [ValidateRange(250, 15000)][int] $TimeoutMs = 5000,
        [switch] $ExpectAuthRejection
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $client = [Net.Sockets.TcpClient]::new()
    $stream = $null
    $plainPassword = $null
    $passwordBytes = $null
    $phase = 'LISTENER_CONNECT'
    try {
        $connectTask = $client.ConnectAsync($ProxyHost, $ProxyPort)
        if (-not $connectTask.Wait($TimeoutMs) -or -not $client.Connected) {
            return [ordered]@{ result = 'FAIL'; reason = 'LISTENER_CONNECT_FAILED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutMs
        $stream.WriteTimeout = $TimeoutMs

        $phase = 'SOCKS_METHOD'
        [byte[]]$greeting = @(0x05, 0x01, 0x02)
        $stream.Write($greeting, 0, $greeting.Length)
        $stream.Flush()
        $methodReply = Read-MishExactBytes -Stream $stream -Count 2
        if ($methodReply[0] -ne 0x05 -or $methodReply[1] -ne 0x02) {
            return [ordered]@{ result = 'FAIL'; reason = 'SOCKS_AUTH_METHOD_REJECTED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }

        $phase = 'SOCKS_AUTH'
        $plainPassword = [Net.NetworkCredential]::new('', $ProxyPassword).Password
        if ($ExpectAuthRejection) {
            $plainPassword = "${plainPassword}__mish_invalid_auth__"
        }
        $userBytes = [Text.Encoding]::UTF8.GetBytes($ProxyUserName)
        $passwordBytes = [Text.Encoding]::UTF8.GetBytes($plainPassword)
        if ($userBytes.Length -lt 1 -or $userBytes.Length -gt 255 -or $passwordBytes.Length -lt 1 -or $passwordBytes.Length -gt 255) {
            return [ordered]@{ result = 'FAIL'; reason = 'CREDENTIAL_LENGTH_INVALID'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        [byte[]]$authRequest = @([byte]0x01, [byte]$userBytes.Length) + $userBytes + @([byte]$passwordBytes.Length) + $passwordBytes
        try {
            $stream.Write($authRequest, 0, $authRequest.Length)
            $stream.Flush()
        }
        finally {
            [Array]::Clear($authRequest, 0, $authRequest.Length)
            [Array]::Clear($userBytes, 0, $userBytes.Length)
            [Array]::Clear($passwordBytes, 0, $passwordBytes.Length)
            $passwordBytes = $null
            $plainPassword = $null
        }
        $authReply = Read-MishExactBytes -Stream $stream -Count 2
        if ($authReply[0] -ne 0x01) {
            return [ordered]@{ result = 'FAIL'; reason = 'SOCKS_AUTH_REPLY_INVALID'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        if ($ExpectAuthRejection) {
            if ($authReply[1] -ne 0x00) {
                return [ordered]@{ result = 'PASS'; reason = 'AUTH_REJECTED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
            }
            return [ordered]@{ result = 'FAIL'; reason = 'INVALID_AUTH_NOT_REJECTED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        if ($authReply[1] -ne 0x00) {
            return [ordered]@{ result = 'FAIL'; reason = 'AUTHENTICATION_FAILED'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }

        $phase = 'SOCKS_CONNECT'
        $targetBytes = [Text.Encoding]::ASCII.GetBytes($TargetHost)
        if ($targetBytes.Length -lt 1 -or $targetBytes.Length -gt 255) {
            return [ordered]@{ result = 'FAIL'; reason = 'TARGET_HOST_LENGTH_INVALID'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        [byte[]]$connectRequest = @([byte]0x05, [byte]0x01, [byte]0x00, [byte]0x03, [byte]$targetBytes.Length) +
            $targetBytes +
            @([byte](($TargetPort -shr 8) -band 0xff), [byte]($TargetPort -band 0xff))
        $stream.Write($connectRequest, 0, $connectRequest.Length)
        $stream.Flush()
        $connectReply = Read-MishExactBytes -Stream $stream -Count 4
        if ($connectReply[0] -ne 0x05 -or $connectReply[1] -ne 0x00) {
            return [ordered]@{ result = 'FAIL'; reason = "SOCKS_CONNECT_REPLY_$([int]$connectReply[1])"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        switch ([int]$connectReply[3]) {
            1 { [void](Read-MishExactBytes -Stream $stream -Count 4) }
            3 {
                $length = Read-MishExactBytes -Stream $stream -Count 1
                if ($length[0] -gt 0) { [void](Read-MishExactBytes -Stream $stream -Count ([int]$length[0])) }
            }
            4 { [void](Read-MishExactBytes -Stream $stream -Count 16) }
            default { return [ordered]@{ result = 'FAIL'; reason = 'SOCKS_BOUND_ADDRESS_INVALID'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds } }
        }
        [void](Read-MishExactBytes -Stream $stream -Count 2)

        $phase = 'SOCKS_RELAY'
        Write-MishAscii -Stream $stream -Text (
            "GET / HTTP/1.1`r`nHost: $TargetHost`r`nConnection: close`r`n`r`n"
        )
        $relayStatusLine = Read-MishProxyStatusLine -Stream $stream -MaxBytes 1024
        $relayStatusCode = Get-MishRelayHttpStatusCode -StatusLine $relayStatusLine
        if ($null -eq $relayStatusCode) {
            return [ordered]@{ result = 'FAIL'; reason = 'RELAY_RESPONSE_INVALID'; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
        }
        return [ordered]@{
            result = 'PASS'
            reason = 'RELAY_CONFIRMED'
            target_status_code = [int]$relayStatusCode
            elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds
        }
    }
    catch [System.AggregateException] {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    catch [System.IO.IOException] {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    catch [Net.Sockets.SocketException] {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    catch {
        return [ordered]@{ result = 'FAIL'; reason = "${phase}_FAILED"; elapsed_ms = [int64]$stopwatch.ElapsedMilliseconds }
    }
    finally {
        $plainPassword = $null
        if ($null -ne $passwordBytes) { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
        if ($null -ne $stream) { $stream.Dispose() }
        $client.Dispose()
        $stopwatch.Stop()
    }
}

Export-ModuleMember -Function Convert-MishProxyStatusLine, Invoke-MishDiagnosticProxyConnectProbe, Invoke-MishDiagnosticHttpRelayProbe, Invoke-MishDiagnosticSocks5RelayProbe
