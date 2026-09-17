[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{32}$')][string] $AccountId,
    [string] $ApiTokenEnvironmentVariable = 'MISH_CF_REGISTRATION_TOKEN',
    [ValidateRange(1, 30)][int] $ApiTimeoutSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$classification = 'LAB_CLOUDFLARE_AUTH_PREFLIGHT_NOT_COMPLETED'
$result = 'FAIL'
$httpStatus = 0
$cloudflareErrorCodes = @()
$registrationCount = $null
$credentialShape = 'UNKNOWN'

$rawToken = [Environment]::GetEnvironmentVariable($ApiTokenEnvironmentVariable)
$token = $null
$client = $null

try {
    if ([string]::IsNullOrWhiteSpace($rawToken)) {
        throw 'LAB_CLOUDFLARE_TOKEN_MISSING'
    }

    $token = $rawToken.Trim()
    if ($token.StartsWith('Bearer ', [StringComparison]::OrdinalIgnoreCase)) {
        $token = $token.Substring(7).Trim()
        $credentialShape = 'BEARER_PREFIX_NORMALIZED'
    }
    else {
        $credentialShape = 'RAW_TOKEN'
    }

    if (
        [string]::IsNullOrWhiteSpace($token) -or
        $token -ceq 'System.Security.SecureString' -or
        $token -match '^<.+>$' -or
        $token -match '[\r\n]'
    ) {
        throw 'LAB_CLOUDFLARE_TOKEN_MATERIALIZATION_INVALID'
    }

    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromSeconds($ApiTimeoutSeconds)
    $client.DefaultRequestHeaders.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $client.DefaultRequestHeaders.Accept.ParseAdd('application/json')

    $uri = "https://api.cloudflare.com/client/v4/accounts/$AccountId/devices/registrations?status=all&per_page=100&include=policy"
    $response = $client.GetAsync($uri).GetAwaiter().GetResult()
    try {
        $httpStatus = [int]$response.StatusCode
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $json = $null
        try { $json = $body | ConvertFrom-Json } catch { }

        if ($null -ne $json -and $null -ne $json.PSObject.Properties['errors']) {
            $cloudflareErrorCodes = @(
                $json.errors |
                    ForEach-Object { if ($null -ne $_.PSObject.Properties['code']) { [int]$_.code } } |
                    Where-Object { $null -ne $_ }
            )
        }

        if ($httpStatus -in @(401, 403) -or $cloudflareErrorCodes -contains 10000) {
            $classification = 'LAB_CLOUDFLARE_AUTH_REJECTED'
        }
        elseif (-not $response.IsSuccessStatusCode) {
            $classification = 'LAB_CLOUDFLARE_AUTH_PREFLIGHT_HTTP_FAILED'
        }
        elseif ($null -eq $json -or -not [bool]$json.success -or $null -eq $json.result) {
            $classification = 'LAB_CLOUDFLARE_AUTH_PREFLIGHT_RESPONSE_INVALID'
        }
        else {
            $registrationCount = @($json.result).Count
            $classification = 'LAB_CLOUDFLARE_AUTH_PREFLIGHT_PASS'
            $result = 'PASS'
        }
    }
    finally {
        $response.Dispose()
    }
}
catch {
    if ($_.Exception.Message -in @(
        'LAB_CLOUDFLARE_TOKEN_MISSING',
        'LAB_CLOUDFLARE_TOKEN_MATERIALIZATION_INVALID'
    )) {
        $classification = $_.Exception.Message
    }
    elseif ($classification -ceq 'LAB_CLOUDFLARE_AUTH_PREFLIGHT_NOT_COMPLETED') {
        $classification = 'LAB_CLOUDFLARE_AUTH_PREFLIGHT_TRANSPORT_FAILED'
    }
}
finally {
    if ($null -ne $client) { $client.Dispose() }
    $token = $null
    $rawToken = $null
}

Write-Host "CLOUDFLARE_AUTH_PREFLIGHT_RESULT=$result"
Write-Host "CLOUDFLARE_AUTH_PREFLIGHT_CLASSIFICATION=$classification"
Write-Host "CLOUDFLARE_AUTH_PREFLIGHT_HTTP_STATUS=$httpStatus"
Write-Host "CLOUDFLARE_AUTH_PREFLIGHT_ERROR_CODES=$($cloudflareErrorCodes -join ',')"
Write-Host "CLOUDFLARE_AUTH_PREFLIGHT_CREDENTIAL_SHAPE=$credentialShape"
if ($null -ne $registrationCount) {
    Write-Host "CLOUDFLARE_AUTH_PREFLIGHT_REGISTRATION_COUNT=$registrationCount"
}

if ($result -cne 'PASS') {
    throw "CLOUDFLARE_AUTH_PREFLIGHT_RESULT|$result|$classification"
}
