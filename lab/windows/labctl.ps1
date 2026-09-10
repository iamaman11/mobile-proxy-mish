[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('host', 'release', 'android', 'evidence')]
    [string]$Area,

    [Parameter(Position = 1, Mandatory)]
    [string]$Action,

    [string]$Tag,
    [string]$ExpectedSourceCommit,
    [string]$ExpectedApkSha256,
    [string]$ExpectedSigningCertificateSha256,
    [string]$Directory,
    [string]$ReceiptPath,
    [string]$VerificationReceipt,
    [string]$InputPath,
    [string]$EvidencePath,
    [string]$AdbPath = 'adb',
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
    [switch]$PhysicalLab,
    [switch]$RequireNoDevice
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Labctl.psm1') -Force

try {
    $result = Invoke-Labctl @PSBoundParameters
    $result | ConvertTo-Json -Depth 8 -Compress
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($message -notmatch '^MISH_LABCTL_FAILURE\|') {
        $message = 'MISH_LABCTL_FAILURE|UNEXPECTED_FAILURE|labctl failed unexpectedly.'
    }
    [Console]::Error.WriteLine($message)
    exit 2
}
