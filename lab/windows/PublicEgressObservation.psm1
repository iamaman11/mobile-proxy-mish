Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Endpoint = 'https://checkip.amazonaws.com/'

Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force

function Invoke-MishPublicEgressAdbCapture {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $AdbPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) {
            throw 'MISH_PUBLIC_EGRESS_OBSERVATION|ADB_START_FAILED'
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill($true) } catch {}
            throw 'MISH_PUBLIC_EGRESS_OBSERVATION|ADB_TIMEOUT'
        }
        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Text = (($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult()) |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n"
        }
    }
    finally {
        $process.Dispose()
    }
}

function New-MishPublicEgressObservationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PackageName
    )

    $tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) {
        $env:RUNNER_TEMP
    } else {
        $env:TEMP
    }
    if ([string]::IsNullOrWhiteSpace($tempRoot)) {
        throw 'MISH_PUBLIC_EGRESS_OBSERVATION|TEMP_UNAVAILABLE'
    }

    $credentialStore = Join-Path $tempRoot (
        'mish-public-egress-observation-' + [Guid]::NewGuid().ToString('N') + '.dpapi'
    )
    $forwardPort = $null
    try {
        [void](Invoke-MishExternalProxyCredentialProvisioning `
            -AdbPath $AdbPath `
            -PackageName $PackageName `
            -StorePath $credentialStore)
        $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStore
        if ($null -eq $lease) {
            throw 'MISH_PUBLIC_EGRESS_OBSERVATION|CREDENTIAL_LEASE_UNAVAILABLE'
        }

        $forward = Invoke-MishPublicEgressAdbCapture `
            -AdbPath $AdbPath `
            -Arguments @('forward', 'tcp:0', 'tcp:3128')
        $text = [string]$forward.Text
        if ($forward.ExitCode -ne 0 -or $text.Trim() -notmatch '^\d+$') {
            throw 'MISH_PUBLIC_EGRESS_OBSERVATION|ADB_FORWARD_FAILED'
        }
        $forwardPort = [int]$text.Trim()

        return [pscustomobject]@{
            AdbPath = $AdbPath
            StorePath = [IO.Path]::GetFullPath($credentialStore)
            ProxyPort = $forwardPort
            Lease = $lease
        }
    }
    catch {
        if ($null -ne $forwardPort) {
            try {
                [void](Invoke-MishPublicEgressAdbCapture `
                    -AdbPath $AdbPath `
                    -Arguments @('forward', '--remove', "tcp:$forwardPort"))
            } catch {}
        }
        if (Test-Path -LiteralPath $credentialStore -PathType Leaf) {
            Remove-Item -LiteralPath $credentialStore -Force -ErrorAction SilentlyContinue
        }
        throw
    }
}

function Invoke-MishExternalPublicIpObservation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [ValidateRange(5, 30)][int] $TimeoutSeconds = 15
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $plainPassword = $null
    $handler = $null
    $client = $null
    $response = $null
    $stream = $null
    try {
        if ($null -eq $Context.Lease -or [int]$Context.ProxyPort -le 0) {
            throw 'MISH_PUBLIC_EGRESS_OBSERVATION|CONTEXT_INVALID'
        }
        $plainPassword = [Net.NetworkCredential]::new(
            '',
            [Security.SecureString]$Context.Lease.ProxyPassword
        ).Password
        $proxy = [Net.WebProxy]::new("http://127.0.0.1:$([int]$Context.ProxyPort)")
        $proxy.Credentials = [Net.NetworkCredential]::new(
            [string]$Context.Lease.ProxyUserName,
            $plainPassword
        )

        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $true
        $handler.Proxy = $proxy

        $client = [Net.Http.HttpClient]::new($handler, $true)
        $handler = $null
        $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

        $response = $client.GetAsync(
            $script:Endpoint,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200) {
            throw 'MISH_PUBLIC_EGRESS_OBSERVATION|HTTP_FAILED'
        }

        $stream = $response.Content.ReadAsStream()
        $buffer = [byte[]]::new(65)
        $count = 0
        while ($count -lt $buffer.Length) {
            $read = $stream.Read($buffer, $count, $buffer.Length - $count)
            if ($read -le 0) { break }
            $count += $read
        }
        if ($count -eq 0 -or $count -gt 64) {
            throw 'MISH_PUBLIC_EGRESS_OBSERVATION|RESPONSE_INVALID'
        }

        $value = [Text.Encoding]::ASCII.GetString($buffer, 0, $count).Trim()
        $parsed = $null
        if (
            [string]::IsNullOrWhiteSpace($value) -or
            $value -match '\s' -or
            -not [Net.IPAddress]::TryParse($value, [ref]$parsed)
        ) {
            throw 'MISH_PUBLIC_EGRESS_OBSERVATION|RESPONSE_INVALID'
        }

        return [pscustomobject]@{
            Address = $parsed.ToString()
            ElapsedMs = [int64]$watch.ElapsedMilliseconds
        }
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        throw 'MISH_PUBLIC_EGRESS_OBSERVATION|TIMEOUT'
    }
    catch [System.Net.Http.HttpRequestException] {
        throw 'MISH_PUBLIC_EGRESS_OBSERVATION|REQUEST_FAILED'
    }
    finally {
        $plainPassword = $null
        if ($null -ne $stream) { $stream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
        $watch.Stop()
    }
}

function Close-MishPublicEgressObservationContext {
    [CmdletBinding()]
    param([AllowNull()] $Context)

    if ($null -eq $Context) { return }

    $port = [int]$Context.ProxyPort
    if ($port -gt 0) {
        try {
            [void](Invoke-MishPublicEgressAdbCapture `
                -AdbPath ([string]$Context.AdbPath) `
                -Arguments @('forward', '--remove', "tcp:$port"))
        } catch {}
    }
    $Context.Lease = $null
    if (
        -not [string]::IsNullOrWhiteSpace([string]$Context.StorePath) -and
        (Test-Path -LiteralPath ([string]$Context.StorePath) -PathType Leaf)
    ) {
        Remove-Item -LiteralPath ([string]$Context.StorePath) -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function @(
    'New-MishPublicEgressObservationContext',
    'Invoke-MishExternalPublicIpObservation',
    'Close-MishPublicEgressObservationContext'
)
