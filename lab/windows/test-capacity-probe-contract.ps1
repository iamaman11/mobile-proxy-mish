$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$sourcePath = Join-Path $PSScriptRoot 'diagnose-capacity-resources.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
    $sourcePath,
    [ref]$tokens,
    [ref]$errors
)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'Capacity/resource probe PowerShell parse failed.'
}

$source = Get-Content -Raw -LiteralPath $sourcePath
foreach ($required in @(
    'function Read-MishConnectHeaders',
    '[Net.Security.SslStream]::new($stream, $false)',
    '$tlsStream.AuthenticateAsClient($TargetHost)',
    "HeldProtocol = 'TLS'",
    "held_session_protocol = 'TLS'",
    'Wait-MishOwnerCounts -ExpectedMesh 64 -ExpectedProxy 64',
    'Test-MishOverflowRejected'
)) {
    if (-not $source.Contains($required)) {
        throw "Capacity/resource probe lost deterministic held-session semantics: $required"
    }
}

$authenticate = $source.IndexOf('$tlsStream.AuthenticateAsClient($TargetHost)', [StringComparison]::Ordinal)
$returnHeld = $source.IndexOf("HeldProtocol = 'TLS'", [StringComparison]::Ordinal)
if ($authenticate -lt 0 -or $returnHeld -lt 0 -or $authenticate -gt $returnHeld) {
    throw 'A capacity session must complete TLS before it can be returned as held.'
}

Write-Host 'CAPACITY_PROBE_CONTRACT=PASS'
