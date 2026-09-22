[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int] $ExpectedPrNumber,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $ExpectedSourceSha,
    [Parameter(Mandatory)][string] $SignedProductApkPath,
    [Parameter(Mandatory)][string] $InstallReceiptPath,
    [string] $AdbPath = 'C:\\mish-lab\\tools\\android-sdk\\platform-tools\\adb.exe',
    [string] $AndroidSdkRoot = 'C:\\mish-lab\\tools\\android-sdk',
    [string] $PackageName = 'com.mobileproxymish.app.debug',
    [ValidateRange(30, 600)][int] $StartupTimeoutSeconds = 300,
    [ValidateRange(30, 600)][int] $UserUnlockTimeoutSeconds = 300,
    [ValidateRange(60, 420)][int] $RebootTimeoutSeconds = 240,
    [string] $EvidencePath = (Join-Path $env:TEMP 'mish-u8-reboot-install-durability-v1.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Schema = 'mish.lab.u8-reboot-install-durability/v2'
$script:SnapshotMethod = 'snapshot_v2'

function Invoke-MishAdbCapture {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $AdbPath @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = ($lines -join "`n").Trim()
    }
}

function Read-MishSnapshot {
    $result = Invoke-MishAdbCapture -Arguments @(
        'shell', 'content', 'call',
        '--uri', "content://$PackageName.diagnostics",
        '--method', $script:SnapshotMethod
    )
    if ($result.ExitCode -ne 0) { return $null }
    $match = [regex]::Match($result.Text, 'payload_b64=(?<payload>[A-Za-z0-9+/=]+)')
    if (-not $match.Success) { return $null }

    $bytes = $null
    try {
        $bytes = [Convert]::FromBase64String($match.Groups['payload'].Value)
        return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
    }
    catch {
        return $null
    }
    finally {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
}

function Test-MishReadySnapshot {
    param($Snapshot)
    if ($null -eq $Snapshot) { return $false }
    return (
        [bool]$Snapshot.runtime.running -and
        [bool]$Snapshot.cellular.admitted -and
        [bool]$Snapshot.root.policy_authorized -and
        [string]$Snapshot.proxy.state -ceq 'RUNNING' -and
        [bool]$Snapshot.credential.active -and
        [bool]$Snapshot.mesh.admitted -and
        [bool]$Snapshot.mesh.ingress_running -and
        [string]$Snapshot.readiness.state -ceq 'READY' -and
        [bool]$Snapshot.readiness.binding_eligible -and
        [string]$Snapshot.readiness.probe_state -ceq 'SUCCEEDED'
    )
}

function Convert-MishReadyProjection {
    param($Snapshot)
    return [ordered]@{
        runtime_running = [bool]$Snapshot.runtime.running
        runtime_generation = [int64]$Snapshot.runtime.generation
        cellular_state = [string]$Snapshot.cellular.state
        cellular_admitted = [bool]$Snapshot.cellular.admitted
        cellular_owner_sequence = [int64]$Snapshot.cellular.owner_sequence
        root_policy_authorized = [bool]$Snapshot.root.policy_authorized
        root_policy_authorized_generation = [int64]$Snapshot.root.policy_authorized_generation
        root_session_generation = if ($Snapshot.root.PSObject.Properties.Name -contains 'session_generation') { [int64]$Snapshot.root.session_generation } else { $null }
        proxy_state = [string]$Snapshot.proxy.state
        credential_active = [bool]$Snapshot.credential.active
        credential_version = [int64]$Snapshot.credential.version
        mesh_admitted = [bool]$Snapshot.mesh.admitted
        mesh_ingress_running = [bool]$Snapshot.mesh.ingress_running
        readiness_state = [string]$Snapshot.readiness.state
        readiness_binding_eligible = [bool]$Snapshot.readiness.binding_eligible
        readiness_probe_state = [string]$Snapshot.readiness.probe_state
    }
}

function Wait-MishPassiveReady {
    param(
        [Parameter(Mandatory)][string] $Phase,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $firstPidAt = $null
    $lastPid = ''
    $stablePidSamples = 0
    $snapshot = $null
    $milestones = [ordered]@{
        process_observed_ms = $null
        runtime_running_ms = $null
        cellular_admitted_ms = $null
        root_authorized_ms = $null
        proxy_running_ms = $null
        credential_active_ms = $null
        mesh_admitted_ms = $null
        mesh_ingress_running_ms = $null
        readiness_ready_ms = $null
    }

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $pidResult = Invoke-MishAdbCapture -Arguments @('shell', 'pidof', $PackageName)
        $processId = if ($pidResult.ExitCode -eq 0 -and $pidResult.Text -match '^\d+$') { [string]$pidResult.Text } else { '' }

        if (-not [string]::IsNullOrWhiteSpace($processId)) {
            if ($null -eq $firstPidAt) {
                $firstPidAt = [DateTimeOffset]::UtcNow
                $milestones.process_observed_ms = [int64]$watch.ElapsedMilliseconds
            }
            if ($processId -ceq $lastPid) { $stablePidSamples += 1 } else { $stablePidSamples = 1; $lastPid = $processId }

            # Do not touch the diagnostics provider until PRODUCT is independently observable
            # through pidof. This keeps BOOT_COMPLETED / MY_PACKAGE_REPLACED startup evidence passive.
            if ($stablePidSamples -ge 2) {
                $snapshot = Read-MishSnapshot
                if ($null -ne $snapshot) {
                    $elapsed = [int64]$watch.ElapsedMilliseconds
                    if ($null -eq $milestones.runtime_running_ms -and [bool]$snapshot.runtime.running) { $milestones.runtime_running_ms = $elapsed }
                    if ($null -eq $milestones.cellular_admitted_ms -and [bool]$snapshot.cellular.admitted) { $milestones.cellular_admitted_ms = $elapsed }
                    if ($null -eq $milestones.root_authorized_ms -and [bool]$snapshot.root.policy_authorized) { $milestones.root_authorized_ms = $elapsed }
                    if ($null -eq $milestones.proxy_running_ms -and [string]$snapshot.proxy.state -ceq 'RUNNING') { $milestones.proxy_running_ms = $elapsed }
                    if ($null -eq $milestones.credential_active_ms -and [bool]$snapshot.credential.active) { $milestones.credential_active_ms = $elapsed }
                    if ($null -eq $milestones.mesh_admitted_ms -and [bool]$snapshot.mesh.admitted) { $milestones.mesh_admitted_ms = $elapsed }
                    if ($null -eq $milestones.mesh_ingress_running_ms -and [bool]$snapshot.mesh.ingress_running) { $milestones.mesh_ingress_running_ms = $elapsed }
                    if ($null -eq $milestones.readiness_ready_ms -and [string]$snapshot.readiness.state -ceq 'READY') { $milestones.readiness_ready_ms = $elapsed }

                    if (Test-MishReadySnapshot -Snapshot $snapshot) {
                        $watch.Stop()
                        return [pscustomobject]@{
                            Phase = $Phase
                            Pid = [int]$processId
                            PassiveProcessObserved = $true
                            Ready = $true
                            FirstPidAt = $firstPidAt
                            ElapsedMs = [int64]$watch.ElapsedMilliseconds
                            Milestones = $milestones
                            Snapshot = $snapshot
                        }
                    }
                }
            }
        }
        else {
            $lastPid = ''
            $stablePidSamples = 0
        }
        Start-Sleep -Milliseconds 1000
    }

    $watch.Stop()
    return [pscustomobject]@{
        Phase = $Phase
        Pid = if ([string]::IsNullOrWhiteSpace($lastPid)) { $null } else { [int]$lastPid }
        PassiveProcessObserved = $null -ne $firstPidAt
        Ready = $false
        FirstPidAt = $firstPidAt
        ElapsedMs = [int64]$watch.ElapsedMilliseconds
        Milestones = $milestones
        Snapshot = $snapshot
    }
}

function Get-MishPackageUid {
    $result = Invoke-MishAdbCapture -Arguments @('shell', 'dumpsys', 'package', $PackageName)
    if ($result.ExitCode -ne 0) { throw 'LAB_PACKAGE_IDENTITY_UNAVAILABLE' }
    $match = [regex]::Match($result.Text, '(?m)^\s*userId=(?<uid>\d+)\s*$')
    if (-not $match.Success) { throw 'LAB_PACKAGE_UID_UNAVAILABLE' }
    return [int64]$match.Groups['uid'].Value
}

function Get-MishInstalledVerification {
    param([Parameter(Mandatory)][string] $Suffix)
    $path = Join-Path $env:RUNNER_TEMP "mish-u8-installed-verification-$Suffix.json"
    & (Join-Path $PSScriptRoot 'verify-installed-candidate.ps1') `
        -InstallReceiptPath $InstallReceiptPath `
        -AdbPath $AdbPath `
        -AndroidSdkRoot $AndroidSdkRoot `
        -ReceiptPath $path | Out-Host
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'LAB_INSTALL_VERIFICATION_MISSING' }
    return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

function Invoke-MishBoundedReplacementInstall {
    param([ValidateRange(10, 180)][int] $TimeoutSeconds = 90)

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $AdbPath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('install', '-r', $SignedProductApkPath)) {
        [void]$start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'PRODUCT_REPLACEMENT_INSTALL_FAILED' }

    try {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            try { [void]$process.WaitForExit(5000) } catch { }
            return [pscustomobject]@{ TimedOut = $true; ExitCode = -1; Text = '' }
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            TimedOut = $false
            ExitCode = [int]$process.ExitCode
            Text = (($stdout, $stderr | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`n").Trim()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-MishBootId {
    $result = Invoke-MishAdbCapture -Arguments @('shell', 'cat', '/proc/sys/kernel/random/boot_id')
    if ($result.ExitCode -ne 0 -or $result.Text -notmatch '^[0-9a-fA-F-]{36}$') { return '' }
    return $result.Text.ToLowerInvariant()
}

function Get-MishCurrentUserState {
    $result = Invoke-MishAdbCapture -Arguments @('shell', 'dumpsys', 'user')
    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return [pscustomobject]@{ Available = $false; Unlocked = $false; State = 'UNKNOWN' }
    }

    $current = [regex]::Match($result.Text, '(?m)^Current user:\s*(?<id>\d+)\s*$')
    if (-not $current.Success) {
        return [pscustomobject]@{ Available = $false; Unlocked = $false; State = 'UNKNOWN' }
    }

    $currentId = [int]$current.Groups['id'].Value
    $insideCurrent = $false
    foreach ($line in ($result.Text -split "`r?`n")) {
        $user = [regex]::Match($line, '^\s*UserInfo\{(?<id>\d+):')
        if ($user.Success) {
            $insideCurrent = [int]$user.Groups['id'].Value -eq $currentId
            continue
        }
        if ($insideCurrent) {
            $state = [regex]::Match($line, '^\s*State:\s*(?<state>[A-Z_0-9-]+)\s*$')
            if ($state.Success) {
                $value = [string]$state.Groups['state'].Value
                return [pscustomobject]@{
                    Available = $true
                    Unlocked = $value -ceq 'RUNNING_UNLOCKED'
                    State = $value
                }
            }
        }
    }

    return [pscustomobject]@{ Available = $false; Unlocked = $false; State = 'UNKNOWN' }
}

function Wait-MishUserUnlocked {
    param([Parameter(Mandatory)][int] $TimeoutSeconds)

    $watch = [Diagnostics.Stopwatch]::StartNew()
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $lastState = 'UNKNOWN'
    $stateAvailable = $false
    $processBeforeUnlock = $false

    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $user = Get-MishCurrentUserState
        if ([bool]$user.Available) {
            $stateAvailable = $true
            $lastState = [string]$user.State
        }

        $pidResult = Invoke-MishAdbCapture -Arguments @('shell', 'pidof', $PackageName)
        if ($pidResult.ExitCode -eq 0 -and $pidResult.Text -match '^\d+$') {
            $processBeforeUnlock = $true
        }

        if ([bool]$user.Unlocked) {
            $watch.Stop()
            return [pscustomobject]@{
                Observed = $true
                StateAvailable = $stateAvailable
                State = $lastState
                WaitMs = [int64]$watch.ElapsedMilliseconds
                ProcessObservedBeforeUnlock = $processBeforeUnlock
            }
        }
        Start-Sleep -Milliseconds 1000
    }

    $watch.Stop()
    return [pscustomobject]@{
        Observed = $false
        StateAvailable = $stateAvailable
        State = $lastState
        WaitMs = [int64]$watch.ElapsedMilliseconds
        ProcessObservedBeforeUnlock = $processBeforeUnlock
    }
}

function Wait-MishRebootComplete {
    param(
        [Parameter(Mandatory)][string] $BootIdBefore,
        [Parameter(Mandatory)][int] $TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $disconnectObserved = $false
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        $devices = Invoke-MishAdbCapture -Arguments @('devices')
        $rows = @(
            $devices.Text -split "`r?`n" |
                Where-Object { $_ -match '^\S+\s+device\s*$' }
        )
        if ($devices.ExitCode -ne 0 -or $rows.Count -ne 1) {
            $disconnectObserved = $true
            Start-Sleep -Milliseconds 1000
            continue
        }

        $bootComplete = Invoke-MishAdbCapture -Arguments @('shell', 'getprop', 'sys.boot_completed')
        $bootIdAfter = Get-MishBootId
        if (
            $bootComplete.ExitCode -eq 0 -and
            $bootComplete.Text -ceq '1' -and
            -not [string]::IsNullOrWhiteSpace($bootIdAfter) -and
            $bootIdAfter -cne $BootIdBefore
        ) {
            return [pscustomobject]@{
                Complete = $true
                DisconnectObserved = $disconnectObserved
                BootIdChanged = $true
            }
        }
        Start-Sleep -Milliseconds 1500
    }

    return [pscustomobject]@{
        Complete = $false
        DisconnectObserved = $disconnectObserved
        BootIdChanged = $false
    }
}

function Invoke-MishRecoveryAfterFailure {
    $result = [ordered]@{ attempted = $false; succeeded = $false }
    try {
        $devices = Invoke-MishAdbCapture -Arguments @('devices')
        $rows = @($devices.Text -split "`r?`n" | Where-Object { $_ -match '^\S+\s+device\s*$' })
        if ($devices.ExitCode -ne 0 -or $rows.Count -ne 1) { return $result }

        $result.attempted = $true
        $receipt = Join-Path $env:RUNNER_TEMP 'mish-u8-recovery-only-start-v1.json'
        & (Join-Path $PSScriptRoot 'start-device-app.ps1') `
            -AdbPath $AdbPath `
            -PackageName $PackageName `
            -ComponentName "$PackageName/com.mobileproxymish.app.MainActivity" `
            -ReceiptPath $receipt | Out-Host
        $snapshot = Read-MishSnapshot
        $result.succeeded = Test-MishReadySnapshot -Snapshot $snapshot
    }
    catch {
        $result.succeeded = $false
    }
    return $result
}

function Write-MishEvidence {
    param([Parameter(Mandatory)] $Evidence)
    $fullPath = [IO.Path]::GetFullPath($EvidencePath)
    $parent = Split-Path -Parent $fullPath
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullPath,
        (($Evidence | ConvertTo-Json -Depth 14) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
    Write-Host "MISH_U8_REBOOT_INSTALL_EVIDENCE=$fullPath"
}

if (-not (Test-Path -LiteralPath $AdbPath -PathType Leaf)) {
    throw 'MISH_U8_DURABILITY_FAILURE|LAB_ADB_MISSING|Canonical ADB executable is unavailable.'
}
if (-not (Test-Path -LiteralPath $SignedProductApkPath -PathType Leaf)) {
    throw 'MISH_U8_DURABILITY_FAILURE|LAB_SIGNED_CANDIDATE_MISSING|Signed exact PRODUCT APK is unavailable.'
}
if (-not (Test-Path -LiteralPath $InstallReceiptPath -PathType Leaf)) {
    throw 'MISH_U8_DURABILITY_FAILURE|LAB_INSTALL_RECEIPT_MISSING|Canonical install receipt is unavailable.'
}

$installReceipt = Get-Content -Raw -LiteralPath $InstallReceiptPath | ConvertFrom-Json
if (
    [string]$installReceipt.schema -cne 'mish.device-candidate-install/v2' -or
    [int]$installReceipt.pr_number -ne $ExpectedPrNumber -or
    [string]$installReceipt.source_sha -cne $ExpectedSourceSha -or
    [string]$installReceipt.application_id -cne $PackageName
) {
    throw 'MISH_U8_DURABILITY_FAILURE|LAB_INSTALL_RECEIPT_IDENTITY_MISMATCH|Install receipt does not describe the requested exact candidate.'
}
$expectedSignedSha = [string]$installReceipt.lab_signed_product_apk_sha256
$signedSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $SignedProductApkPath).Hash.ToLowerInvariant()
if ($expectedSignedSha -notmatch '^[0-9a-f]{64}$' -or $signedSha -cne $expectedSignedSha) {
    throw 'MISH_U8_DURABILITY_FAILURE|LAB_SIGNED_CANDIDATE_DIGEST_MISMATCH|Replacement APK does not match the canonical install receipt.'
}

$evidence = [ordered]@{
    schema = $script:Schema
    collected_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    acceptance_result = 'FAIL'
    classification = 'LAB_U8_DURABILITY_NOT_COMPLETED'
    source_sha = $ExpectedSourceSha
    pr_number = $ExpectedPrNumber
    replacement_install = [ordered]@{
        adb_install_r_attempts = 0
        timed_out = $false
        timeout_recovered_by_exact_bytes = $false
        uid_before = $null
        uid_after = $null
        uid_stable = $false
        signing_certificate_stable = $false
        exact_installed_bytes_before = $false
        exact_installed_bytes_after = $false
        passive_process_start_observed = $false
        root_authorized_after = $false
        ready_after = $false
    }
    reboot = [ordered]@{
        adb_reboot_attempts = 0
        disconnect_observed = $false
        boot_id_changed = $false
        boot_completed = $false
        passive_process_start_observed = $false
        uid_stable = $false
        signing_certificate_stable = $false
        root_authorized_after = $false
        ready_after = $false
        user_unlock_observed = $false
        user_state_observed = 'UNKNOWN'
        user_unlock_wait_ms = $null
        process_observed_before_unlock = $false
        convergence_elapsed_ms = $null
        convergence_milestones_ms = $null
    }
    secrets_persisted_in_evidence = $false
    raw_public_ip_persisted = $false
    recovery_only = [ordered]@{ attempted = $false; succeeded = $false }
}

$failure = $null
try {
    $baseline = Wait-MishPassiveReady -Phase 'baseline' -TimeoutSeconds 20
    if (-not $baseline.Ready) { throw 'PRODUCT_BASELINE_NOT_READY' }
    $uidBefore = Get-MishPackageUid
    $verifiedBefore = Get-MishInstalledVerification -Suffix 'before'
    $bootIdBefore = Get-MishBootId
    if ([string]::IsNullOrWhiteSpace($bootIdBefore)) { throw 'LAB_BOOT_ID_UNAVAILABLE' }

    $evidence.baseline = [ordered]@{
        pid = [int]$baseline.Pid
        uid = $uidBefore
        signing_certificate_sha256 = [string]$verifiedBefore.signing_certificate_sha256
        ready = Convert-MishReadyProjection -Snapshot $baseline.Snapshot
    }
    $evidence.replacement_install.uid_before = $uidBefore
    $evidence.replacement_install.exact_installed_bytes_before = [bool]$verifiedBefore.exact_installed_bytes_verified

    $evidence.replacement_install.adb_install_r_attempts = 1
    $installResult = Invoke-MishBoundedReplacementInstall
    $evidence.replacement_install.timed_out = [bool]$installResult.TimedOut
    if (
        -not $installResult.TimedOut -and
        ($installResult.ExitCode -ne 0 -or $installResult.Text -notmatch '(?m)^Success\s*$')
    ) {
        throw 'PRODUCT_REPLACEMENT_INSTALL_FAILED'
    }

    $replacementReady = Wait-MishPassiveReady -Phase 'replacement_install' -TimeoutSeconds $StartupTimeoutSeconds
    if (-not $replacementReady.PassiveProcessObserved) { throw 'PRODUCT_REPLACEMENT_AUTOSTART_NOT_OBSERVED' }
    if (-not $replacementReady.Ready) { throw 'PRODUCT_REPLACEMENT_NOT_READY' }

    $uidAfterInstall = Get-MishPackageUid
    $verifiedAfterInstall = Get-MishInstalledVerification -Suffix 'after-install'
    $uidStableAfterInstall = $uidAfterInstall -eq $uidBefore
    $signerStableAfterInstall = [string]$verifiedAfterInstall.signing_certificate_sha256 -ceq [string]$verifiedBefore.signing_certificate_sha256
    if (-not $uidStableAfterInstall) { throw 'PRODUCT_REPLACEMENT_UID_CHANGED' }
    if (-not $signerStableAfterInstall) { throw 'PRODUCT_REPLACEMENT_SIGNER_CHANGED' }
    if (-not [bool]$replacementReady.Snapshot.root.policy_authorized) { throw 'PRODUCT_REPLACEMENT_ROOT_AUTHORITY_NOT_RESTORED' }

    $evidence.replacement_install.uid_after = $uidAfterInstall
    $evidence.replacement_install.uid_stable = $uidStableAfterInstall
    $evidence.replacement_install.signing_certificate_stable = $signerStableAfterInstall
    $evidence.replacement_install.exact_installed_bytes_after = [bool]$verifiedAfterInstall.exact_installed_bytes_verified
    $evidence.replacement_install.timeout_recovered_by_exact_bytes = (
        [bool]$installResult.TimedOut -and [bool]$verifiedAfterInstall.exact_installed_bytes_verified
    )
    $evidence.replacement_install.passive_process_start_observed = [bool]$replacementReady.PassiveProcessObserved
    $evidence.replacement_install.root_authorized_after = [bool]$replacementReady.Snapshot.root.policy_authorized
    $evidence.replacement_install.ready_after = $true
    $evidence.replacement_install.convergence_elapsed_ms = [int64]$replacementReady.ElapsedMs
    $evidence.replacement_install.convergence_milestones_ms = $replacementReady.Milestones
    $evidence.replacement_install.ready = Convert-MishReadyProjection -Snapshot $replacementReady.Snapshot

    $bootIdBeforeReboot = Get-MishBootId
    if ([string]::IsNullOrWhiteSpace($bootIdBeforeReboot)) { throw 'LAB_BOOT_ID_UNAVAILABLE' }

    $evidence.reboot.adb_reboot_attempts = 1
    $rebootRequest = Invoke-MishAdbCapture -Arguments @('reboot')
    if ($rebootRequest.ExitCode -ne 0) { throw 'LAB_REBOOT_REQUEST_FAILED' }

    $reboot = Wait-MishRebootComplete -BootIdBefore $bootIdBeforeReboot -TimeoutSeconds $RebootTimeoutSeconds
    $evidence.reboot.disconnect_observed = [bool]$reboot.DisconnectObserved
    $evidence.reboot.boot_id_changed = [bool]$reboot.BootIdChanged
    $evidence.reboot.boot_completed = [bool]$reboot.Complete
    if (-not $reboot.Complete -or -not $reboot.BootIdChanged) { throw 'LAB_REBOOT_NOT_OBSERVED' }

    $unlock = Wait-MishUserUnlocked -TimeoutSeconds $UserUnlockTimeoutSeconds
    $evidence.reboot.user_unlock_observed = [bool]$unlock.Observed
    $evidence.reboot.user_state_observed = [string]$unlock.State
    $evidence.reboot.user_unlock_wait_ms = [int64]$unlock.WaitMs
    $evidence.reboot.process_observed_before_unlock = [bool]$unlock.ProcessObservedBeforeUnlock
    if (-not $unlock.Observed) { throw 'LAB_REBOOT_USER_UNLOCK_NOT_OBSERVED' }

    $rebootReady = Wait-MishPassiveReady -Phase 'reboot_after_unlock' -TimeoutSeconds $StartupTimeoutSeconds
    $evidence.reboot.convergence_elapsed_ms = [int64]$rebootReady.ElapsedMs
    $evidence.reboot.convergence_milestones_ms = $rebootReady.Milestones
    if (-not $rebootReady.PassiveProcessObserved) { throw 'PRODUCT_REBOOT_AUTOSTART_NOT_OBSERVED' }
    if (-not $rebootReady.Ready) { throw 'PRODUCT_REBOOT_NOT_READY' }

    $uidAfterReboot = Get-MishPackageUid
    $verifiedAfterReboot = Get-MishInstalledVerification -Suffix 'after-reboot'
    $uidStableAfterReboot = $uidAfterReboot -eq $uidBefore
    $signerStableAfterReboot = [string]$verifiedAfterReboot.signing_certificate_sha256 -ceq [string]$verifiedBefore.signing_certificate_sha256
    if (-not $uidStableAfterReboot) { throw 'PRODUCT_REBOOT_UID_CHANGED' }
    if (-not $signerStableAfterReboot) { throw 'PRODUCT_REBOOT_SIGNER_CHANGED' }
    if (-not [bool]$rebootReady.Snapshot.root.policy_authorized) { throw 'PRODUCT_REBOOT_ROOT_AUTHORITY_NOT_RESTORED' }

    $evidence.reboot.passive_process_start_observed = [bool]$rebootReady.PassiveProcessObserved
    $evidence.reboot.uid_stable = $uidStableAfterReboot
    $evidence.reboot.signing_certificate_stable = $signerStableAfterReboot
    $evidence.reboot.root_authorized_after = [bool]$rebootReady.Snapshot.root.policy_authorized
    $evidence.reboot.ready_after = $true
    $evidence.reboot.ready = Convert-MishReadyProjection -Snapshot $rebootReady.Snapshot

    $evidence.acceptance_result = 'PASS'
    $evidence.classification = 'U8_REBOOT_INSTALL_DURABILITY_PASS'
}
catch {
    $text = [string]$_
    $candidate = [regex]::Match($text, '(LAB|PRODUCT)_[A-Z0-9_]+')
    $failure = if ($candidate.Success) { $candidate.Value } else { 'LAB_U8_DURABILITY_UNCLASSIFIED_FAILURE' }
    $evidence.acceptance_result = 'FAIL'
    $evidence.classification = $failure
    $evidence.recovery_only = Invoke-MishRecoveryAfterFailure
}

Write-MishEvidence -Evidence $evidence
Write-Host "MISH_U8_REBOOT_INSTALL_ACCEPTANCE=$([string]$evidence.acceptance_result)"
Write-Host "MISH_U8_REBOOT_INSTALL_CLASSIFICATION=$([string]$evidence.classification)"
Write-Host "MISH_U8_REPLACEMENT_INSTALL_ATTEMPTS=$([int]$evidence.replacement_install.adb_install_r_attempts)"
Write-Host "MISH_U8_REBOOT_ATTEMPTS=$([int]$evidence.reboot.adb_reboot_attempts)"

if ([string]$evidence.acceptance_result -cne 'PASS') {
    throw "MISH_U8_DURABILITY_FAILURE|$([string]$evidence.classification)|U8 reboot/replacement-install durability acceptance failed."
}
