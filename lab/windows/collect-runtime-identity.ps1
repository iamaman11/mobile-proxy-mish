[CmdletBinding()]
param(
    [string] $AdbPath = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-runtime-identity-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$schema = 'mish.lab.runtime-identity/v1'
$runtimePath = 'no_backup/proxy-runtime'

function Stop-RuntimeIdentity {
    param(
        [Parameter(Mandatory)][string] $Category,
        [Parameter(Mandatory)][string] $Message
    )
    throw "MISH_RUNTIME_IDENTITY_FAILURE|$Category|$Message"
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    Stop-RuntimeIdentity 'ADB_MISSING' 'Canonical ADB executable is missing.'
}

$rows = @(& $AdbPath shell ps -A 2>$null)
if ($LASTEXITCODE -ne 0) {
    Stop-RuntimeIdentity 'PROCESS_SNAPSHOT_FAILED' 'Non-root Android process snapshot failed.'
}
$singBoxRows = @($rows | Where-Object { $_ -match '(?i)(?:libsingbox|sing-box)' })
$visibleProcesses = @(
    foreach ($row in $singBoxRows) {
        if ($row -match '^\S+\s+(\d+)\s+(\d+)\s+') {
            [ordered]@{
                pid = [int]$Matches[1]
                ppid = [int]$Matches[2]
            }
        }
    }
)

$manifest = (@(& $AdbPath shell run-as $PackageName cat "$runtimePath/sing-box-current-generation" 2>$null) -join "`n").Trim()
$currentGeneration = $null
if ($LASTEXITCODE -eq 0 -and $manifest -match '^generation=([A-Za-z0-9_-]{24})$') {
    $currentGeneration = $Matches[1]
}

$names = @(& $AdbPath shell run-as $PackageName ls $runtimePath 2>$null)
if ($LASTEXITCODE -ne 0) {
    Stop-RuntimeIdentity 'RUNTIME_DIRECTORY_UNAVAILABLE' 'App-owned proxy runtime directory is unavailable.'
}

$pidFiles = @($names | Where-Object { $_ -match '^sing-box-([A-Za-z0-9_-]{24})\.pid$' })
$recordedPidCount = 0
$recordedPids = @()
$currentRecordedPid = $null
$visibleMatchesAny = $false
$visibleMatchesCurrent = $false
$visibleMatchesNonCurrent = $false

foreach ($pidFile in $pidFiles) {
    if ($pidFile -notmatch '^sing-box-([A-Za-z0-9_-]{24})\.pid$') { continue }
    $generation = $Matches[1]
    $pidText = (@(& $AdbPath shell run-as $PackageName cat "$runtimePath/$pidFile" 2>$null) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0 -or $pidText -notmatch '^\d+$') { continue }
    $recordedPidValue = [int]$pidText
    $recordedPidCount += 1
    $recordedPids += $recordedPidValue
    if ($null -ne $currentGeneration -and $generation -ceq $currentGeneration) {
        $currentRecordedPid = $recordedPidValue
    }
    $escapedPid = [regex]::Escape($pidText)
    $matchesVisible = @($singBoxRows | Where-Object { $_ -match "^\S+\s+$escapedPid\s+" }).Count -eq 1
    if (-not $matchesVisible) { continue }
    $visibleMatchesAny = $true
    if ($null -ne $currentGeneration -and $generation -ceq $currentGeneration) {
        $visibleMatchesCurrent = $true
    }
    else {
        $visibleMatchesNonCurrent = $true
    }
}

$currentRecordedPidIsVisibleParent = $false
if ($null -ne $currentRecordedPid) {
    $currentRecordedPidIsVisibleParent = @(
        $visibleProcesses | Where-Object { [int]$_.ppid -eq [int]$currentRecordedPid }
    ).Count -gt 0
}

$manifestPresent = $names -contains 'sing-box-current-generation'
$cleanupScriptPresent = $names -contains 'sing-box-owned-cleanup.sh'
$currentConfigPresent = $false
$currentPidPresent = $false
$currentLauncherPresent = $false
$currentControlPresent = $false
if ($null -ne $currentGeneration) {
    $currentConfigPresent = $names -contains "sing-box-$currentGeneration.json"
    $currentPidPresent = $names -contains "sing-box-$currentGeneration.pid"
    $currentLauncherPresent = $names -contains "sing-box-$currentGeneration-launch.sh"
    $currentControlPresent = $names -contains "sing-box-$currentGeneration-control.sh"
}
$generationFileCount = @(
    $names | Where-Object { $_ -match '^sing-box-[A-Za-z0-9_-]{24}(?:\.json|\.pid|-launch\.sh|-control\.sh)$' }
).Count

$classification = if ($singBoxRows.Count -eq 0 -and $recordedPidCount -gt 0) {
    'RECORDED_IDENTITY_WITHOUT_VISIBLE_PROCESS'
}
elseif ($singBoxRows.Count -gt 0 -and -not $visibleMatchesAny) {
    'VISIBLE_PROCESS_WITHOUT_RECORDED_IDENTITY'
}
elseif ($visibleMatchesCurrent) {
    'CURRENT_GENERATION_VISIBLE'
}
elseif ($visibleMatchesNonCurrent) {
    'NONCURRENT_GENERATION_VISIBLE'
}
else {
    'NO_RUNTIME_IDENTITY_CONFLICT'
}

$evidence = [ordered]@{
    schema = $schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    package = $PackageName
    visible_sing_box_process_count = $singBoxRows.Count
    visible_sing_box_processes = $visibleProcesses
    recorded_generation_pid_count = $recordedPidCount
    recorded_generation_pids = @($recordedPids)
    current_generation_record_available = $null -ne $currentGeneration
    current_recorded_pid = $currentRecordedPid
    current_recorded_pid_is_visible_parent = $currentRecordedPidIsVisibleParent
    visible_process_has_any_recorded_generation = $visibleMatchesAny
    current_generation_process_match = $visibleMatchesCurrent
    visible_process_matches_noncurrent_recorded_generation = $visibleMatchesNonCurrent
    runtime_manifest_present = $manifestPresent
    current_config_present = $currentConfigPresent
    current_pid_present = $currentPidPresent
    current_launcher_present = $currentLauncherPresent
    current_control_present = $currentControlPresent
    owned_orphan_cleanup_script_present = $cleanupScriptPresent
    generation_runtime_file_count = $generationFileCount
    classification = $classification
}

$fullEvidencePath = [IO.Path]::GetFullPath($EvidencePath)
$parent = Split-Path -Parent $fullEvidencePath
if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $fullEvidencePath,
    (($evidence | ConvertTo-Json -Depth 5) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

$visiblePidSummary = (@($visibleProcesses | ForEach-Object { "$($_.pid):$($_.ppid)" }) -join ',')
$currentRecordedPidText = if ($null -eq $currentRecordedPid) { 'NONE' } else { [string]$currentRecordedPid }
Write-Host 'MISH_RUNTIME_IDENTITY_COLLECTION=PASS'
Write-Host "MISH_RUNTIME_IDENTITY_CLASSIFICATION=$classification"
Write-Host "VISIBLE_SING_BOX_PROCESS_COUNT=$($singBoxRows.Count)"
Write-Host "VISIBLE_SING_BOX_PID_PPID=$visiblePidSummary"
Write-Host "RECORDED_GENERATION_PID_COUNT=$recordedPidCount"
Write-Host "CURRENT_RECORDED_PID=$currentRecordedPidText"
Write-Host "CURRENT_RECORDED_PID_IS_VISIBLE_PARENT=$currentRecordedPidIsVisibleParent"
Write-Host "CURRENT_GENERATION_PROCESS_MATCH=$visibleMatchesCurrent"
Write-Host "MISH_RUNTIME_IDENTITY_EVIDENCE=$fullEvidencePath"
