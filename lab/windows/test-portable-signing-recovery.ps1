$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$tool = Join-Path $PSScriptRoot 'portable-signing-recovery.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('mish-portable-recovery-test-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $root 'original-state'
$destination = Join-Path $root 'restored-state'
$conflict = Join-Path $root 'conflicting-state'
$external = Join-Path $root 'independent-vault-fixture'
$archivePath = Join-Path $external 'signing.mishvault'
$key = ConvertTo-SecureString ('a' * 64) -AsPlainText -Force
$wrong = ConvertTo-SecureString ('b' * 64) -AsPlainText -Force

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw "RECOVERY_TEST_FAILED|$Message" }
}

function Expect-Failure {
    param([scriptblock] $Test, [string] $Code)
    $failure = ''
    try { & $Test | Out-Null }
    catch { $failure = $_.Exception.Message }
    if ($failure -notlike "MISH_PORTABLE_RECOVERY_FAILURE|$Code|*") {
        throw "RECOVERY_TEST_FAILED|Expected $Code, observed $failure"
    }
}

New-Item -ItemType Directory -Force -Path $source, $external, $conflict | Out-Null
try {
    $plaintext = New-Object byte[] 4096
    [Security.Cryptography.RandomNumberGenerator]::Fill($plaintext)
    $original = Join-Path $source 'device-candidate.p12'
    [IO.File]::WriteAllBytes($original, $plaintext)
    $hash = (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash.ToLowerInvariant()

    $protected = @(& $tool -Action Protect -StateRoot $source -BackupPath $archivePath -RecoveryCode $key)
    Assert-True (($protected -join ',') -like '*MISH_PORTABLE_RECOVERY=PROTECTED*') 'Protection did not succeed'
    Assert-True (Test-Path -LiteralPath $archivePath -PathType Leaf) 'External archive missing'

    $rawArchive = Get-Content -Raw -LiteralPath $archivePath
    $envelope = $rawArchive | ConvertFrom-Json
    Assert-True ($envelope.schema -ceq 'mish.lab.portable-signing-recovery/v1') 'Unexpected vault schema'
    Assert-True ($envelope.algorithm -ceq 'AES-256-GCM') 'Wrong vault encryption'
    Assert-True ($envelope.key_sha256 -ceq $hash) 'Missing source digest'
    Assert-True (-not $rawArchive.Contains(('a' * 64))) 'Recovery code leaked to archive'

    $verified = @(& $tool -Action Verify -StateRoot $destination -BackupPath $archivePath -RecoveryCode $key)
    Assert-True (($verified -join ',') -like "*KEY_SHA256=$hash*") 'Independent archive verification failed'
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'Verify wrote into destination'

    Expect-Failure -Code 'BACKUP_ALREADY_EXISTS' -Test {
        & $tool -Action Protect -StateRoot $source -BackupPath $archivePath -RecoveryCode $key
    }
    Assert-True ((Get-FileHash $original -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $hash) 'Original mutated during protect'

    Expect-Failure -Code 'ARCHIVE_AUTHENTICATION_FAILED' -Test {
        & $tool -Action Restore -StateRoot $destination -BackupPath $archivePath -RecoveryCode $wrong
    }
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'Wrong recovery code created a destination'

    $tampered = Join-Path $external 'tampered.mishvault'
    $modified = $rawArchive | ConvertFrom-Json
    $bytes = [Convert]::FromBase64String([string]$modified.ciphertext)
    $bytes[0] = $bytes[0] -bxor 1
    $modified.ciphertext = [Convert]::ToBase64String($bytes)
    $modified | ConvertTo-Json -Compress | Set-Content -Encoding utf8NoBOM -LiteralPath $tampered
    Expect-Failure -Code 'ARCHIVE_AUTHENTICATION_FAILED' -Test {
        & $tool -Action Restore -StateRoot $destination -BackupPath $tampered -RecoveryCode $key
    }
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'Tampered vault created a destination'

    Expect-Failure -Code 'BACKUP_MISSING' -Test {
        & $tool -Action Restore -StateRoot $destination -BackupPath (Join-Path $external 'missing.mishvault') -RecoveryCode $key
    }
    Assert-True (-not (Test-Path -LiteralPath $destination)) 'Missing vault created a destination'

    $restored = @(& $tool -Action Restore -StateRoot $destination -BackupPath $archivePath -RecoveryCode $key)
    Assert-True (($restored -join ',') -match 'MISH_PORTABLE_RECOVERY=RESTORED') 'Restore did not succeed'
    $restoredFile = Join-Path $destination 'device-candidate.p12'
    Assert-True ((Get-FileHash $restoredFile -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $hash) 'Independent exact-byte roundtrip failed'
    $again = @(& $tool -Action Restore -StateRoot $destination -BackupPath $archivePath -RecoveryCode $key)
    Assert-True (($again -join ',') -match 'MISH_PORTABLE_RECOVERY=ALREADY_RESTORED') 'Idempotent same-key restore refused'

    $existing = Join-Path $conflict 'device-candidate.p12'
    [IO.File]::WriteAllBytes($existing, ([Text.Encoding]::UTF8.GetBytes('other-private-identity')))
    $existingHash = (Get-FileHash $existing -Algorithm SHA256).Hash
    Expect-Failure -Code 'SIGNING_IDENTITY_CONFLICT' -Test {
        & $tool -Action Restore -StateRoot $conflict -BackupPath $archivePath -RecoveryCode $key
    }
    Assert-True ((Get-FileHash $existing -Algorithm SHA256).Hash -ceq $existingHash) 'Conflicting key was overwritten'

    Expect-Failure -Code 'BACKUP_LOCATION_UNSAFE' -Test {
        & $tool -Action Protect -StateRoot $source -BackupPath 'C:\mish-lab\unsafe.mishvault' -RecoveryCode $key
    }
    $newState = Join-Path $root 'fresh-enrollment'
    Expect-Failure -Code 'FRESH_DEVICE_REQUIRED' -Test {
        & $tool -Action Initialize -StateRoot $newState -BackupPath (Join-Path $external 'new.mishvault') -RecoveryCode $key
    }
    Assert-True (-not (Test-Path -LiteralPath $newState)) 'Unacknowledged initialization wrote a key'

    $keytool = Get-Command keytool -ErrorAction SilentlyContinue
    if ($null -ne $keytool) {
        $enrollVault = Join-Path $external 'enrolled.mishvault'
        $enrolled = @(& $tool -Action Initialize -StateRoot $newState -BackupPath $enrollVault -RecoveryCode $key -FreshAndroidInstallAcknowledged -KeytoolPath $keytool.Source)
        Assert-True (($enrolled -join ',') -like '*MISH_PORTABLE_RECOVERY=ENROLLED*') 'Fresh identity enrollment failed'
        $initKey = Join-Path $newState 'device-candidate.p12'
        Assert-True ((Test-Path $initKey) -and (Test-Path $enrollVault)) 'Key and independent vault were not both created'
        $enrollHash = (Get-FileHash $initKey -Algorithm SHA256).Hash
        $testRestored = Join-Path $root 'enrolled-restored'
        & $tool -Action Restore -StateRoot $testRestored -BackupPath $enrollVault -RecoveryCode $key | Out-Null
        Assert-True ((Get-FileHash (Join-Path $testRestored 'device-candidate.p12') -Algorithm SHA256).Hash -ceq $enrollHash) 'Enrolled key failed independent restore'
        Expect-Failure -Code 'SIGNING_IDENTITY_PRESENT' -Test {
            & $tool -Action Initialize -StateRoot $newState -BackupPath (Join-Path $external 'second.mishvault') -RecoveryCode $key -FreshAndroidInstallAcknowledged -KeytoolPath $keytool.Source
        }
    }
    else {
        Write-Warning 'keytool unavailable on this host: encryption/restore negative tests passed, positive initialize test requires the canonical JDK.'
    }

    $installer = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'install-device-candidate.ps1')
    Assert-True ($installer.Contains('SIGNING_RECOVERY_NOT_ENROLLED')) 'Unescrowed install guard missing'
    Assert-True (-not $installer.Contains("'-genkeypair',")) 'Installer still silently generates an unescrowed signing key'

    Write-Output 'MISH_PORTABLE_RECOVERY_TEST=PASS'
}
finally { Remove-Item -Recurse -Force -LiteralPath $root -ErrorAction SilentlyContinue }
