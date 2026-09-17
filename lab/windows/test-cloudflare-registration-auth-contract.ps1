$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$probePath = Join-Path $PSScriptRoot 'test-cloudflare-registration-auth.ps1'

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'Cloudflare registration auth preflight must parse under PowerShell.'
}

$source = Get-Content -Raw -LiteralPath $probePath
foreach ($required in @(
    "`$ApiTokenEnvironmentVariable = 'MISH_CF_REGISTRATION_TOKEN'",
    'devices/registrations?status=all&per_page=100&include=policy',
    "AuthenticationHeaderValue]::new('Bearer', `$token)",
    "StartsWith('Bearer ', [StringComparison]::OrdinalIgnoreCase)",
    'System.Security.SecureString',
    'LAB_CLOUDFLARE_TOKEN_MATERIALIZATION_INVALID',
    'LAB_CLOUDFLARE_AUTH_REJECTED',
    'LAB_CLOUDFLARE_AUTH_PREFLIGHT_PASS',
    'CLOUDFLARE_AUTH_PREFLIGHT_CREDENTIAL_SHAPE='
)) {
    if (-not $source.Contains($required)) {
        throw "Cloudflare auth preflight lost required safe-read contract: $required"
    }
}

foreach ($forbidden in @(
    '-X POST',
    "-Method POST",
    '/revoke',
    '/unrevoke',
    '/physical-devices/',
    '/devices/resilience/disconnect',
    "'shell'",
    'Invoke-RestMethod',
    'Write-Host $token',
    'Write-Output $token'
)) {
    if ($source.Contains($forbidden)) {
        throw "Cloudflare auth preflight must remain read-only and secret-safe: $forbidden"
    }
}

if ($source -match '(?i)Bearer\s+[A-Za-z0-9._~-]{20,}') {
    throw 'Cloudflare auth preflight must never contain a literal bearer token.'
}

Write-Host 'CLOUDFLARE_REGISTRATION_AUTH_CONTRACT=PASS'
exit 0
