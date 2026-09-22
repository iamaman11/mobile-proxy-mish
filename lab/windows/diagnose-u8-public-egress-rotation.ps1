[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [ValidateRange(5, 30)][int] $ExternalProbeTimeoutSeconds = 15,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8-public-egress-rotation-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Schema = 'mish.lab.u8-public-egress-rotation/v1'
$script:Endpoint = 'https://checkip.amazonaws.com/'

function Stop-MishU8PublicEgress {
    param(
        [Parameter(Mandatory)][string] $Classification,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_U8_PUBLIC_EGRESS_FAILURE|$Classification|$Message"
}

function Invoke-MishAdbCapture {
    param([Parameter(Mandatory)][string[]] $Arguments)

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
            Stop-MishU8PublicEgress 'LAB_ADB_FAILED' 'ADB did not start.'
        }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) {
            try { $process.Kill($true) } catch {}
            Stop-MishU8PublicEgress 'LAB_ADB_TIMEOUT' 'ADB exceeded the bounded transport deadline.'
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

function New-MishAdbForward {
    $result = Invoke-MishAdbCapture -Arguments @('forward', 'tcp:0', 'tcp:3128')
    $text = [string]$result.Text
    if ($result.ExitCode -ne 0 -or $text.Trim() -notmatch '^\d+$') {
        Stop-MishU8PublicEgress 'LAB_ADB_FORWARD_FAILED' 'Could not expose the existing PRODUCT HTTP CONNECT listener through bounded ADB forwarding.'
    }
    return [int]$text.Trim()
}

function Remove-MishAdbForward {
    param([Parameter(Mandatory)][int] $Port)
    [void](Invoke-MishAdbCapture -Arguments @('forward', '--remove', "tcp:$Port"))
}

function Invoke-MishExternalPublicIpObservation {
    param(
        [Parameter(Mandatory)][int] $ProxyPort,
        [Parameter(Mandatory)][string] $ProxyUserName,
        [Parameter(Mandatory)][Security.SecureString] $ProxyPassword
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $plainPassword = $null
    $handler = $null
    $client = $null
    $response = $null
    $stream = $null
    try {
        $plainPassword = [Net.NetworkCredential]::new('', $ProxyPassword).Password
        $proxy = [Net.WebProxy]::new("http://127.0.0.1:$ProxyPort")
        $proxy.Credentials = [Net.NetworkCredential]::new($ProxyUserName, $plainPassword)

        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.UseProxy = $true
        $handler.Proxy = $proxy

        $client = [Net.Http.HttpClient]::new($handler, $true)
        $handler = $null
        $client.Timeout = [TimeSpan]::FromSeconds($ExternalProbeTimeoutSeconds)

        $response = $client.GetAsync(
            $script:Endpoint,
            [Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -ne 200) {
            Stop-MishU8PublicEgress 'LAB_EXTERNAL_IP_HTTP_FAILED' 'External IP endpoint did not return HTTP 200 through the authenticated PRODUCT proxy.'
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
            Stop-MishU8PublicEgress 'LAB_EXTERNAL_IP_RESPONSE_INVALID' 'External IP response was empty or exceeded the bounded body size.'
        }

        $raw = [Text.Encoding]::ASCII.GetString($buffer, 0, $count)
        $value = $raw.Trim()
        $parsed = $null
        if (
            [string]::IsNullOrWhiteSpace($value) -or
            $value -match '\s' -or
            -not [Net.IPAddress]::TryParse($value, [ref]$parsed)
        ) {
            Stop-MishU8PublicEgress 'LAB_EXTERNAL_IP_RESPONSE_INVALID' 'External IP endpoint returned a non-IP body.'
        }

        return [pscustomobject]@{
            Address = $parsed.ToString()
            ElapsedMs = [int64]$watch.ElapsedMilliseconds
        }
    }
    catch [System.Net.Http.HttpRequestException] {
        Stop-MishU8PublicEgress 'LAB_EXTERNAL_IP_REQUEST_FAILED' 'External IP request failed through the authenticated PRODUCT proxy.'
    }
    catch [System.Threading.Tasks.TaskCanceledException] {
        Stop-MishU8PublicEgress 'LAB_EXTERNAL_IP_TIMEOUT' 'External IP request exceeded the bounded deadline.'
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

function Write-MishEvidence {
    param([Parameter(Mandatory)] $Evidence)
    $full = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $full
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $full,
        (($Evidence | ConvertTo-Json -Depth 12) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "MISH_U8_PUBLIC_EGRESS_EVIDENCE=$full"
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-MishU8PublicEgress 'LAB_ADB_MISSING' 'Canonical ADB executable is unavailable.'
}

Import-Module (Join-Path $PSScriptRoot 'CredentialProvisioning.psm1') -Force

$tempRoot = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { $env:TEMP }
$credentialStore = Join-Path $tempRoot ('mish-u8-egress-credential-' + [Guid]::NewGuid().ToString('N') + '.dpapi')
$rotationEvidencePath = Join-Path $tempRoot ('mish-u8-egress-inner-rotation-' + [Guid]::NewGuid().ToString('N') + '.json')
$forwardPort = $null
$lease = $null
$beforeAddress = $null
$afterAddress = $null
$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'FAIL'
    classification = 'LAB_U8_PUBLIC_EGRESS_UNCLASSIFIED'
    endpoint_host = 'checkip.amazonaws.com'
    path = 'authenticated_PRODUCT_proxy_via_bounded_adb_forward'
    rotation_requests = 1
    product_terminal_result = $null
    product_operation_id = $null
    generation_a = $null
    generation_b = $null
    external_outcome = 'FAILED'
    observer_consensus = $false
    timings = $null
    raw_ip_persisted = $false
    secrets_persisted_in_evidence = $false
}

try {
    [void](Invoke-MishExternalProxyCredentialProvisioning -AdbPath $AdbPath -PackageName $PackageName -StorePath $credentialStore)
    $lease = Open-MishExternalProxyCredentialLease -StorePath $credentialStore
    if ($null -eq $lease) {
        Stop-MishU8PublicEgress 'LAB_CREDENTIAL_LEASE_UNAVAILABLE' 'Bounded proxy credential lease is unavailable.'
    }

    $forwardPort = New-MishAdbForward
    $before = Invoke-MishExternalPublicIpObservation `
        -ProxyPort $forwardPort `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword)
    $beforeAddress = [string]$before.Address

    $rotationError = $null
    try {
        & (Join-Path $PSScriptRoot 'diagnose-u5-rotation.ps1') `
            -AdbPath $AdbPath `
            -PackageName $PackageName `
            -SuccessfulOperations 1 `
            -SkipShutdownRestoreAfterOn `
            -EvidencePath $rotationEvidencePath
    }
    catch {
        $rotationError = [string]$_
    }

    $rotationEvidence = if (Test-Path -LiteralPath $rotationEvidencePath -PathType Leaf) {
        Get-Content -Raw -LiteralPath $rotationEvidencePath | ConvertFrom-Json
    } else {
        $null
    }
    if ($null -eq $rotationEvidence) {
        Stop-MishU8PublicEgress 'LAB_INNER_ROTATION_EVIDENCE_MISSING' 'Single-rotation evidence was not produced.'
    }
    if ($null -ne $rotationError -or [string]$rotationEvidence.acceptance_result -cne 'PASS') {
        $innerClass = [string]$rotationEvidence.classification
        if ($innerClass -notmatch '^[A-Z0-9_]+$') { $innerClass = 'PRODUCT_ROTATION_FAILED' }
        $evidence.classification = $innerClass
        $evidence.product_terminal_result = 'FAILED'
        Write-MishEvidence -Evidence $evidence
        Stop-MishU8PublicEgress $innerClass 'The existing PRODUCT rotation owner did not complete the bounded single-operation contract.'
    }

    $operation = @($rotationEvidence.successful_operations)[0]
    if ($null -eq $operation) {
        Stop-MishU8PublicEgress 'LAB_INNER_ROTATION_EVIDENCE_INVALID' 'Single-rotation evidence contains no operation.'
    }
    $terminal = [string]$operation.terminal_result
    if ($terminal -notin @('CHANGED', 'UNCHANGED')) {
        Stop-MishU8PublicEgress 'PRODUCT_ROTATION_TERMINAL_INVALID' 'PRODUCT terminal result is not CHANGED or UNCHANGED.'
    }

    $after = Invoke-MishExternalPublicIpObservation `
        -ProxyPort $forwardPort `
        -ProxyUserName ([string]$lease.ProxyUserName) `
        -ProxyPassword ([Security.SecureString]$lease.ProxyPassword)
    $afterAddress = [string]$after.Address
    $externalChanged = $beforeAddress -cne $afterAddress
    $externalOutcome = if ($externalChanged) { 'CHANGED' } else { 'UNCHANGED' }
    $consensus = $terminal -ceq $externalOutcome

    $evidence.product_terminal_result = $terminal
    $evidence.product_operation_id = [int64]$operation.operation_id
    $evidence.generation_a = [int64]$operation.generation_a
    $evidence.generation_b = [int64]$operation.generation_b
    $evidence.external_outcome = $externalOutcome
    $evidence.observer_consensus = $consensus
    $evidence.timings = [ordered]@{
        external_before_ms = [int64]$before.ElapsedMs
        external_after_ms = [int64]$after.ElapsedMs
        request_to_airplane_on_ms = [int64]$operation.timings.request_to_airplane_on_ms
        request_to_cellular_loss_ms = [int64]$operation.timings.request_to_cellular_loss_ms
        off_to_fresh_owner_ms = [int64]$operation.timings.off_to_fresh_owner_ms
        off_to_root_policy_authorized_ms = [int64]$operation.timings.off_to_root_policy_authorized_ms
        off_to_readiness_ready_ms = [int64]$operation.timings.off_to_readiness_ready_ms
        off_to_functional_public_ip_ms = [int64]$operation.timings.off_to_functional_public_ip_ms
        total_rotation_ms = [int64]$operation.timings.total_rotation_ms
    }

    if (-not $consensus) {
        $evidence.classification = 'PRODUCT_EXTERNAL_EGRESS_RESULT_MISMATCH'
        Write-MishEvidence -Evidence $evidence
        Stop-MishU8PublicEgress $evidence.classification 'External proxy-observed public egress disagrees with the PRODUCT rotation terminal result.'
    }

    $evidence.acceptance_result = 'PASS'
    $evidence.classification = 'U8_PUBLIC_EGRESS_ROTATION_PASS'
    Write-MishEvidence -Evidence $evidence
    Write-Host 'MISH_U8_PUBLIC_EGRESS_ACCEPTANCE=PASS'
    Write-Host "MISH_U8_PUBLIC_EGRESS_OUTCOME=$externalOutcome"
    Write-Host 'MISH_U8_PUBLIC_EGRESS_OBSERVER_CONSENSUS=true'
    Write-Host 'MISH_U8_PUBLIC_EGRESS_RAW_IP_PERSISTED=false'
}
finally {
    $beforeAddress = $null
    $afterAddress = $null
    $lease = $null
    if ($null -ne $forwardPort) {
        try { Remove-MishAdbForward -Port ([int]$forwardPort) } catch {}
    }
    if (Test-Path -LiteralPath $credentialStore -PathType Leaf) {
        Remove-Item -LiteralPath $credentialStore -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $rotationEvidencePath -PathType Leaf) {
        Remove-Item -LiteralPath $rotationEvidencePath -Force -ErrorAction SilentlyContinue
    }
}
