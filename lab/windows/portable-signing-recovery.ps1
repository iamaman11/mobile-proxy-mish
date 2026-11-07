[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('GenerateCode', 'Initialize', 'Protect', 'Verify', 'Restore')]
    [string] $Action,
    [string] $BackupPath = '',
    [string] $StateRoot = 'C:\mish-lab\runner\.state\device-candidate',
    [Security.SecureString] $RecoveryCode,
    [string] $KeytoolPath = 'keytool',
    [switch] $FreshAndroidInstallAcknowledged
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$schema = 'mish.lab.portable-signing-recovery/v1'
$maxKeyBytes = 4 * 1024 * 1024
$keystoreName = 'device-candidate.p12'
$signingPassword = 'mish-lab-device-candidate-v1'
$signingAlias = 'mish-lab-device-candidate-v1'
$state = [IO.Path]::GetFullPath($StateRoot)
$keystorePath = Join-Path $state $keystoreName

function Stop-Recovery {
    param([string] $Category, [string] $Description)
    throw "MISH_PORTABLE_RECOVERY_FAILURE|$Category|$Description"
}

function Get-Hash {
    param([byte[]] $Bytes)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-RecoveryKey {
    if ($null -eq $RecoveryCode) {
        if (-not [Environment]::UserInteractive) {
            Stop-Recovery 'RECOVERY_CODE_REQUIRED' 'Supply a SecureString in a local interactive session.'
        }
        $script:RecoveryCode = Read-Host 'Recovery code (64 hex characters; input hidden)' -AsSecureString
    }
    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($script:RecoveryCode)
        $value = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ($value -cnotmatch '^[0-9a-fA-F]{64}$') {
            Stop-Recovery 'INVALID_RECOVERY_CODE' 'A randomly generated 256-bit code is required.'
        }
        return ,([Convert]::FromHexString($value))
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Resolve-BackupPath {
    if (-not [IO.Path]::IsPathFullyQualified($BackupPath)) {
        Stop-Recovery 'BACKUP_LOCATION_INVALID' 'Specify an absolute independent/cloud-synchronized backup file path.'
    }
    $backup = [IO.Path]::GetFullPath($BackupPath)
    $labRoot = [IO.Path]::GetFullPath('C:\mish-lab').TrimEnd('\') + '\'
    if ($backup.StartsWith($labRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $backup -match '(?i)(^|[\\/])\.git([\\/]|$)' -or
        $backup -notmatch '(?i)\.mishvault$') {
        Stop-Recovery 'BACKUP_LOCATION_UNSAFE' 'Archive must be a .mishvault file outside the LAB tree and Git metadata.'
    }
    $parent = Split-Path -Parent $backup
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Stop-Recovery 'BACKUP_DESTINATION_MISSING' 'Create and independently synchronize the external backup directory first.'
    }
    return $backup
}

function Protect-Bytes {
    param([byte[]] $Plaintext, [byte[]] $Key)
    if ($Plaintext.Length -eq 0 -or $Plaintext.Length -gt $maxKeyBytes) {
        Stop-Recovery 'KEY_SIZE_INVALID' 'Signing keystore is empty or unreasonably large.'
    }
    $hash = Get-Hash $Plaintext
    $nonce = New-Object byte[] 12
    $tag = New-Object byte[] 16
    $ciphertext = New-Object byte[] $Plaintext.Length
    [Security.Cryptography.RandomNumberGenerator]::Fill($nonce)
    $aad = [Text.Encoding]::UTF8.GetBytes("$schema|$hash|$($Plaintext.Length)")
    $aes = [Security.Cryptography.AesGcm]::new($Key, 16)
    try {
        $aes.Encrypt($nonce, $Plaintext, $ciphertext, $tag, $aad)
    }
    finally {
        $aes.Dispose()
    }
    return [ordered]@{
        schema = $schema
        algorithm = 'AES-256-GCM'
        contents = $keystoreName
        created_utc = [DateTimeOffset]::UtcNow.ToString('o')
        key_sha256 = $hash
        key_length = $Plaintext.Length
        nonce = [Convert]::ToBase64String($nonce)
        tag = [Convert]::ToBase64String($tag)
        ciphertext = [Convert]::ToBase64String($ciphertext)
    }
}

function Unprotect-Archive {
    param([string] $Path, [byte[]] $Key)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Recovery 'BACKUP_MISSING' 'Encrypted archive does not exist.'
    }
    if ((Get-Item -LiteralPath $Path).Length -gt (8 * 1024 * 1024)) {
        Stop-Recovery 'ARCHIVE_SIZE_INVALID' 'Unexpectedly large recovery archive.'
    }
    try {
        $archive = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -ErrorAction Stop
        if ($archive.schema -cne $schema -or $archive.algorithm -cne 'AES-256-GCM' -or
            $archive.contents -cne $keystoreName -or
            [string]$archive.key_sha256 -cnotmatch '^[a-f0-9]{64}$' -or
            [long]$archive.key_length -le 0 -or [long]$archive.key_length -gt $maxKeyBytes) {
            Stop-Recovery 'ARCHIVE_FORMAT_INVALID' 'Recovery archive identity or length is invalid.'
        }
        $nonce = [Convert]::FromBase64String([string]$archive.nonce)
        $tag = [Convert]::FromBase64String([string]$archive.tag)
        $ciphertext = [Convert]::FromBase64String([string]$archive.ciphertext)
        if ($nonce.Length -ne 12 -or $tag.Length -ne 16 -or $ciphertext.Length -ne [long]$archive.key_length) {
            Stop-Recovery 'ARCHIVE_FORMAT_INVALID' 'Invalid authenticated encryption payload lengths.'
        }
        $plaintext = New-Object byte[] $ciphertext.Length
        $aad = [Text.Encoding]::UTF8.GetBytes("$schema|$($archive.key_sha256)|$($archive.key_length)")
        $aes = [Security.Cryptography.AesGcm]::new($Key, 16)
        try {
            $aes.Decrypt($nonce, $ciphertext, $tag, $plaintext, $aad)
        }
        finally {
            $aes.Dispose()
        }
        if ((Get-Hash $plaintext) -cne [string]$archive.key_sha256) {
            Stop-Recovery 'ARCHIVE_DIGEST_MISMATCH' 'Decrypted identity digest mismatch.'
        }
        return ,$plaintext
    }
    catch {
        if ($_.Exception.Message -like 'MISH_PORTABLE_RECOVERY_FAILURE|*') { throw }
        Stop-Recovery 'ARCHIVE_AUTHENTICATION_FAILED' 'Archive corrupted or recovery code incorrect.'
    }
}

function Write-ProtectedArchive {
    param([byte[]] $Plaintext, [byte[]] $Key, [string] $Path)
    if (Test-Path -LiteralPath $Path) {
        Stop-Recovery 'BACKUP_ALREADY_EXISTS' 'Never overwrite an existing recovery artifact.'
    }
    $envelope = Protect-Bytes -Plaintext $Plaintext -Key $Key
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temp, ($envelope | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path)
        $check = Unprotect-Archive -Path $Path -Key $Key
        if ((Get-Hash $check) -cne (Get-Hash $Plaintext)) {
            Stop-Recovery 'BACKUP_READBACK_FAILED' 'Encrypted archive failed exact-byte readback.'
        }
        [Array]::Clear($check, 0, $check.Length)
        return $envelope.key_sha256
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -Force -LiteralPath $temp }
    }
}

function Write-NewSigningIdentity {
    param([byte[]] $Plaintext)
    if (Test-Path -LiteralPath $keystorePath) {
        $existing = [IO.File]::ReadAllBytes($keystorePath)
        try {
            if ((Get-Hash $existing) -cne (Get-Hash $Plaintext)) {
                Stop-Recovery 'SIGNING_IDENTITY_CONFLICT' 'Existing signing key differs; preserving it unchanged.'
            }
            Write-Output 'MISH_PORTABLE_RECOVERY=ALREADY_RESTORED'
            return
        }
        finally { [Array]::Clear($existing, 0, $existing.Length) }
    }
    [IO.Directory]::CreateDirectory($state) | Out-Null
    $temp = Join-Path $state ('.keystore-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, $Plaintext)
        if ($IsWindows) {
            & icacls.exe $temp /inheritance:r /grant:r '*S-1-5-18:(R)' '*S-1-5-32-544:(F)' '*S-1-5-20:(R)' | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Stop-Recovery 'SIGNING_ACL_FAILED' 'Could not protect restored LAB signing identity.'
            }
        }
        [IO.File]::Move($temp, $keystorePath)
        Write-Output 'MISH_PORTABLE_RECOVERY=RESTORED'
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -Force -LiteralPath $temp }
    }
}

if ($Action -ceq 'GenerateCode') {
    $random = New-Object byte[] 32
    try {
        [Security.Cryptography.RandomNumberGenerator]::Fill($random)
        Write-Warning 'Store this one-time 256-bit recovery code OUTSIDE Windows and separately from the encrypted vault. Do not copy it to GitHub, Actions logs or the vault directory.'
        Write-Output ('MISH_PORTABLE_RECOVERY_CODE=' + [Convert]::ToHexString($random).ToLowerInvariant())
    }
    finally { [Array]::Clear($random, 0, $random.Length) }
    exit 0
}

$backup = Resolve-BackupPath
$key = Get-RecoveryKey
try {
    switch ($Action) {
        'Protect' {
            if (-not (Test-Path -LiteralPath $keystorePath -PathType Leaf)) {
                Stop-Recovery 'SIGNING_IDENTITY_MISSING' 'No existing identity to escrow. Use Initialize only for a fresh device.'
            }
            $bytes = [IO.File]::ReadAllBytes($keystorePath)
            try {
                $digest = Write-ProtectedArchive -Plaintext $bytes -Key $key -Path $backup
                if ((Get-FileHash -LiteralPath $keystorePath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $digest) {
                    Stop-Recovery 'SIGNING_IDENTITY_CHANGED' 'Keystore changed during backup; stop and investigate.'
                }
                Write-Output "MISH_PORTABLE_RECOVERY=PROTECTED;KEY_SHA256=$digest"
            }
            finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
        'Verify' {
            $bytes = Unprotect-Archive -Path $backup -Key $key
            try {
                Write-Output ('MISH_PORTABLE_RECOVERY=VERIFIED;KEY_SHA256=' + (Get-Hash $bytes))
            }
            finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
        'Restore' {
            $bytes = Unprotect-Archive -Path $backup -Key $key
            try { Write-NewSigningIdentity -Plaintext $bytes }
            finally { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
        'Initialize' {
            if (-not $FreshAndroidInstallAcknowledged) {
                Stop-Recovery 'FRESH_DEVICE_REQUIRED' 'A new signing identity cannot update an already-installed app. Explicit fresh-device acknowledgement is required.'
            }
            if ((Test-Path -LiteralPath $keystorePath) -or
                (Test-Path -LiteralPath 'C:\mish-lab\runner\_work\.mish-device-candidate\device-candidate.p12')) {
                Stop-Recovery 'SIGNING_IDENTITY_PRESENT' 'Use Protect for an existing identity; never regenerate.'
            }
            if (Test-Path -LiteralPath $backup) {
                Stop-Recovery 'BACKUP_ALREADY_EXISTS' 'Refusing to initialize over a prior vault.'
            }
            $stage = Join-Path ([IO.Path]::GetTempPath()) ('mish-signing-enroll-' + [Guid]::NewGuid().ToString('N'))
            [IO.Directory]::CreateDirectory($stage) | Out-Null
            try {
                $stageKey = Join-Path $stage $keystoreName
                & $KeytoolPath -genkeypair -keystore $stageKey -storetype PKCS12 -storepass $signingPassword -keypass $signingPassword -alias $signingAlias -keyalg RSA -keysize 3072 -validity 36500 -dname 'CN=MISH LAB Device Candidate,O=MISH LAB,C=ZZ' -noprompt | Out-Null
                if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $stageKey -PathType Leaf)) {
                    Stop-Recovery 'KEY_GENERATION_FAILED' 'Official keytool failed.'
                }
                $bytes = [IO.File]::ReadAllBytes($stageKey)
                try {
                    $digest = Write-ProtectedArchive -Plaintext $bytes -Key $key -Path $backup
                    Write-NewSigningIdentity -Plaintext $bytes
                    Write-Output "MISH_PORTABLE_RECOVERY=ENROLLED;KEY_SHA256=$digest"
                }
                finally { [Array]::Clear($bytes, 0, $bytes.Length) }
            }
            finally { Remove-Item -Recurse -Force -LiteralPath $stage -ErrorAction SilentlyContinue }
        }
    }
}
finally { [Array]::Clear($key, 0, $key.Length) }
