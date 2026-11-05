[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $MeshCidr = '100.96.0.0/12',
    [string] $EvidenceRoot = (Join-Path $env:TEMP 'mish-full-diagnostic'),
    [switch] $PhysicalLab,
    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MishFailureCode {
    param([Parameter(Mandatory)][string] $Message)
    if ($Message -match '^(?:MISH_DIAGNOSTIC_FAILURE|MISH_CONTROL_DIAGNOSTIC_FAILURE|MISH_WARP_STATE_FAILURE)\|(?<code>[A-Z0-9_]+)\|') {
        return [string]$Matches.code
    }
    return 'COLLECTION_FAILED'
}

function Invoke-MishFullStage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $ScriptPath,
        [Parameter(Mandatory)][hashtable] $Arguments,
        [Parameter(Mandatory)][string] $OutputPath
    )
    $classification = 'NOT_RUN'
    $reason = 'COLLECTION_FAILED'
    $passed = $false
    try {
        & $ScriptPath @Arguments
        if (-not (Test-Path -LiteralPath $OutputPath -PathType Leaf)) {
            throw 'MISH_FULL_DIAGNOSTIC|EVIDENCE_MISSING'
        }
        $snapshot = Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json
        switch ($Name) {
            'device' {
                if ([string]$snapshot.schema -cne 'mish.lab.diagnostic/v2') { throw 'INVALID_SCHEMA' }
                $classification = [string]$snapshot.classification
                $passed = $classification -ceq 'PASS'
            }
            'control' {
                if ([string]$snapshot.schema -cne 'mish.lab.control-diagnostic/v1') { throw 'INVALID_SCHEMA' }
                $classification = [string]$snapshot.control.state
                $passed = [bool]$snapshot.pid_stable -and $classification -ceq 'READY'
            }
            'warp' {
                if ([string]$snapshot.schema -cne 'mish.lab.warp-state/v1') { throw 'INVALID_SCHEMA' }
                $classification = [string]$snapshot.classification
                $passed = $classification -ceq 'READY'
            }
        }
        $reason = if ($passed) { 'NONE' } else { 'OWNER_NOT_READY' }
    }
    catch {
        $classification = 'COLLECTION_FAILED'
        $reason = Get-MishFailureCode -Message ([string]$_.Exception.Message)
    }
    [pscustomobject]@{
        result = if ($passed) { 'PASS' } else { 'FAIL' }
        classification = $classification
        reason = $reason
        evidence = if (Test-Path -LiteralPath $OutputPath -PathType Leaf) {
            [IO.Path]::GetFileName($OutputPath)
        } else { $null }
    }
}

if ($SelfTest) {
    foreach ($row in @(
        @{ message='MISH_DIAGNOSTIC_FAILURE|ADB_UNAUTHORIZED|redacted'; expected='ADB_UNAUTHORIZED' },
        @{ message='MISH_CONTROL_DIAGNOSTIC_FAILURE|ADB_OFFLINE|redacted'; expected='ADB_OFFLINE' },
        @{ message='MISH_WARP_STATE_FAILURE|WARP_DISCONNECTED|redacted'; expected='WARP_DISCONNECTED' },
        @{ message='details that may contain sensitive data'; expected='COLLECTION_FAILED' }
    )) {
        if ((Get-MishFailureCode -Message $row.message) -cne $row.expected) {
            throw 'MISH_FULL_DIAGNOSTIC_SELFTEST_FAILED'
        }
    }
    Write-Host 'MISH_FULL_DIAGNOSTIC_SELFTEST=PASS'
    return
}

$fullRoot = [IO.Path]::GetFullPath($EvidenceRoot)
[IO.Directory]::CreateDirectory($fullRoot) | Out-Null
$stages = [ordered]@{}
$specs = @(
    @{
        name = 'device'
        script = 'collect-device-diagnostic.ps1'
        args = @{ AdbPath=$AdbPath; PackageName=$PackageName; MeshCidr=$MeshCidr; EvidencePath=(Join-Path $fullRoot 'device.json') }
    },
    @{
        name = 'control'
        script = 'collect-control-diagnostic.ps1'
        args = @{ AdbPath=$AdbPath; PackageName=$PackageName; EvidencePath=(Join-Path $fullRoot 'control.json') }
    },
    @{
        name = 'warp'
        script = 'collect-warp-state-diagnostic.ps1'
        args = @{ AdbPath=$AdbPath; PackageName=$PackageName; MeshDeviceCidr=$MeshCidr; EvidencePath=(Join-Path $fullRoot 'warp.json'); PhysicalLab=$true }
    }
)
foreach ($spec in $specs) {
    if ($spec.name -ceq 'warp' -and -not $PhysicalLab) {
        $spec.args.Remove('PhysicalLab')
    }
    $name = [string]$spec.name
    $stages[$name] = Invoke-MishFullStage -Name $name `
        -ScriptPath (Join-Path $PSScriptRoot $spec.script) `
        -Arguments $spec.args -OutputPath $spec.args.EvidencePath
    Write-Host "MISH_FULL_STAGE_$($name.ToUpperInvariant())=$($stages[$name].result)/$($stages[$name].reason)"
}
$success = @($stages.Values | Where-Object { $_.result -ne 'PASS' }).Count -eq 0
$report = [ordered]@{
    schema = 'mish.lab.full-diagnostic/v1'
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    classification = if ($success) { 'PASS' } else { 'FAIL' }
    stages = $stages
    mutation_performed = $false
    secrets_persisted_in_summary = $false
}
[IO.File]::WriteAllText(
    (Join-Path $fullRoot 'full.json'),
    (($report | ConvertTo-Json -Depth 9) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)
Write-Host "MISH_FULL_DEVICE_CLASSIFICATION=$($report.classification)"
if (-not $success) { throw 'MISH_FULL_DIAGNOSTIC|CHECK_FAILED|One or more typed component checks failed; see full.json.' }
