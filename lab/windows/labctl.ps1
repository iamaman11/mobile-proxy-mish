[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('host', 'release', 'android', 'evidence', 'cloudflare', 'e3', 'e4')]
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
    [string]$HarnessVerificationReceipt,
    [long]$HarnessRunId,
    [long]$HarnessArtifactId,
    [string]$ExpectedHarnessZipSha256,
    [string]$ExpectedTestApkSha256,
    [string]$HarnessDirectory,
    [string]$RunMetadataPath,
    [string]$ArtifactMetadataPath,
    [string]$AndroidObservationPath,
    [string]$InputPath,
    [string]$EvidencePath,
    [string]$MeshDeviceCidr,
    [string]$SessionReceipt,
    [string]$ObservationPath,
    [string]$ExternalFixturePath,
    [string]$E3AcceptancePath,
    [string]$AdbPath = 'adb',
    [string]$E3Host = 'checkip.amazonaws.com',
    [ValidateRange(1, 65535)][int]$E3Port = 80,
    [string]$E3Path = '/',
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
    elseif ($Area -eq 'e3') {
        if ($Action -eq 'accept') {
            Import-Module (Join-Path $PSScriptRoot 'E3Acceptance.psm1') -Force
            if (-not $VerificationReceipt -or -not $HarnessVerificationReceipt -or -not $InputPath -or -not $EvidencePath) {
                throw 'MISH_LABCTL_FAILURE|INPUT_INVALID|E3 accept requires exact release/harness verification, execution result, and evidence path.'
            }
            $result = Invoke-E3AcceptanceProjection `
                -ReleaseVerificationReceipt $VerificationReceipt `
                -HarnessVerificationReceipt $HarnessVerificationReceipt `
                -ExecutionResultPath $InputPath `
                -EvidencePath $EvidencePath
        }
        else {
            Import-Module (Join-Path $PSScriptRoot 'E3Harness.psm1') -Force
            switch ($Action) {
                'verify' {
                    foreach ($value in @($VerificationReceipt, $ExpectedHarnessZipSha256, $ExpectedTestApkSha256, $HarnessDirectory, $ReceiptPath)) {
                        if (-not $value) { throw 'MISH_LABCTL_FAILURE|INPUT_INVALID|E3 verify requires release verification, exact harness identity/digests, directory, and receipt path.' }
                    }
                    if ($HarnessRunId -le 0 -or $HarnessArtifactId -le 0) { throw 'MISH_LABCTL_FAILURE|INPUT_INVALID|E3 verify requires positive run/artifact IDs.' }
                    $result = Invoke-E3Domain -Action verify `
                        -ReleaseVerificationReceipt $VerificationReceipt `
                        -HarnessRunId $HarnessRunId `
                        -HarnessArtifactId $HarnessArtifactId `
                        -ExpectedHarnessZipSha256 $ExpectedHarnessZipSha256 `
                        -ExpectedTestApkSha256 $ExpectedTestApkSha256 `
                        -HarnessDirectory $HarnessDirectory `
                        -ReceiptPath $ReceiptPath `
                        -RunMetadataPath $RunMetadataPath `
                        -ArtifactMetadataPath $ArtifactMetadataPath
                }
                'ready' {
                    if (-not $VerificationReceipt -or -not $HarnessVerificationReceipt -or -not $AndroidObservationPath -or -not $EvidencePath) {
                        throw 'MISH_LABCTL_FAILURE|INPUT_INVALID|E3 ready requires release/harness verification, Android observation, and evidence path.'
                    }
                    $result = Invoke-E3Domain -Action ready `
                        -ReleaseVerificationReceipt $VerificationReceipt `
                        -HarnessVerificationReceipt $HarnessVerificationReceipt `
                        -AndroidObservationPath $AndroidObservationPath `
                        -EvidencePath $EvidencePath
                }
                'execute' {
                    if (-not $VerificationReceipt -or -not $HarnessVerificationReceipt -or -not $AdbPath) {
                        throw 'MISH_LABCTL_FAILURE|INPUT_INVALID|E3 execute requires exact release/harness verification and ADB.'
                    }
                    $result = Invoke-E3Domain -Action execute `
                        -ReleaseVerificationReceipt $VerificationReceipt `
                        -HarnessVerificationReceipt $HarnessVerificationReceipt `
                        -AdbPath $AdbPath `
                        -E3Host $E3Host `
                        -E3Port $E3Port `
                        -E3Path $E3Path `
                        -TimeoutSeconds $TimeoutSeconds
                }
                default { throw "MISH_LABCTL_FAILURE|INPUT_INVALID|Unsupported command: $Area $Action" }
            }
        }
    }
    elseif ($Area -eq 'e4') {
        Import-Module (Join-Path $PSScriptRoot 'E4Harness.psm1') -Force
        Import-Module (Join-Path $PSScriptRoot 'E4E3Binding.psm1') -Force
        switch ($Action) {
            'plan' {
                if (-not $VerificationReceipt -or -not $E3AcceptancePath -or -not $ReceiptPath) {
                    throw 'MISH_LABCTL_FAILURE|INPUT_INVALID|E4 plan requires exact release verification, exact E3 acceptance, and receipt path.'
                }
                if (-not $ExternalFixturePath) {
                    $ExternalFixturePath = Join-Path $PSScriptRoot 'external-client-fixture.json'
                }
                $result = Invoke-E4Domain -Action plan `
                    -ReleaseVerificationReceipt $VerificationReceipt `
                    -ExternalFixturePath $ExternalFixturePath `
                    -ReceiptPath $ReceiptPath
                $binding = Add-E4E3Binding -SessionReceipt $ReceiptPath -E3AcceptancePath $E3AcceptancePath
                $result | Add-Member -NotePropertyName e3_acceptance_sha256 -NotePropertyValue ([string]$binding.e3_acceptance_sha256) -Force
            }
            'finalize' {
                if (-not $SessionReceipt -or -not $ObservationPath -or -not $EvidencePath) {
                    throw 'MISH_LABCTL_FAILURE|INPUT_INVALID|E4 finalize requires exact session, physical observations, and evidence path.'
                }
                $binding = Assert-E4E3Binding -SessionReceipt $SessionReceipt
                $result = Invoke-E4Domain -Action finalize `
                    -SessionReceipt $SessionReceipt `
                    -ObservationPath $ObservationPath `
                    -EvidencePath $EvidencePath
                [void](Add-E4E3EvidenceProjection -EvidencePath $EvidencePath -Binding $binding)
            }
            default { throw "MISH_LABCTL_FAILURE|INPUT_INVALID|Unsupported command: $Area $Action" }
        }
    }
    else {
        Import-Module (Join-Path $PSScriptRoot 'Labctl.psm1') -Force
        $result = Invoke-Labctl @PSBoundParameters
    }

    $result | ConvertTo-Json -Depth 8 -Compress
    if ([string]$result.result -eq 'BLOCKED') {
        exit 3
    }
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
