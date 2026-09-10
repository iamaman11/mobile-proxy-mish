[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('host', 'release', 'android', 'evidence', 'cloudflare')]
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
    [string]$MeshDeviceCidr,
    [string]$AdbPath = 'adb',
    [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
    [switch]$PhysicalLab,
    [switch]$RequireNoDevice,
    [switch]$Recovery
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

try {
    if ($Area -eq 'cloudflare') {
        Import-Module (Join-Path $PSScriptRoot 'CloudflareProbe.psm1') -Force
        if ($Action -ne 'prove') {
            throw "MISH_LABCTL_FAILURE|INPUT_INVALID|Unsupported command: $Area $Action"
        }
        if (-not $MeshDeviceCidr -or -not $EvidencePath) {
            throw 'MISH_LABCTL_FAILURE|INPUT_INVALID|MeshDeviceCidr and EvidencePath are required for cloudflare prove.'
        }
        $result = Invoke-CloudflareWindowsProof `
            -MeshDeviceCidr $MeshDeviceCidr `
            -EvidencePath $EvidencePath `
            -Recovery:$Recovery `
            -PhysicalLab:$PhysicalLab
    }
    else {
        Import-Module (Join-Path $PSScriptRoot 'Labctl.psm1') -Force
        $result = Invoke-Labctl @PSBoundParameters
    }

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
