using namespace System.IO

Set-StrictMode -Version Latest

$script:ProvisioningAction = 'com.mobileproxymish.app.action.PROVISION_EXTERNAL_PROXY_V1'
$script:ProvisioningComponent = 'com.mobileproxymish.app/.CredentialProvisioningReceiver'
$script:PublicKeyExtra = 'client_public_key_spki_b64'
$script:ChallengeExtra = 'challenge_hex'
$script:StoreEntropy = [System.Text.Encoding]::UTF8.GetBytes(
    'mobile-proxy-mish/windows/external-proxy-dpapi/v1'
)
$script:StrictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
$script:ProvisioningSchemaVersion = [uint64]1

class MishExternalProxyCredentialLease {
    [string] $CredentialVersion
    [string] $CredentialId
    hidden [string] $ProxyUserName
    hidden [System.Security.SecureString] $ProxyPassword

    MishExternalProxyCredentialLease(
        [string] $credentialVersion,
        [string] $credentialId,
        [string] $proxyUserName,
        [System.Security.SecureString] $proxyPassword
    ) {
        $this.CredentialVersion = $credentialVersion
        $this.CredentialId = $credentialId
        $this.ProxyUserName = $proxyUserName
        $this.ProxyPassword = $proxyPassword
    }

    [string] ToString() {
        return 'MishExternalProxyCredentialLease(<redacted>)'
    }
}

function Get-MishDefaultCredentialStorePath {
    $localAppData = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::LocalApplicationData
    )
    if ([string]::IsNullOrWhiteSpace($localAppData)) {
        throw [InvalidOperationException]::new(
            'Windows LocalApplicationData is unavailable for credential storage.'
        )
    }
    return Join-Path $localAppData 'MobileProxyMish\ClientCredentials\external-proxy.v1.dpapi'
}

function Assert-MishCredentialStorePath {
    param([Parameter(Mandatory)][string] $StorePath)

    if (-not [IO.Path]::IsPathRooted($StorePath)) {
        throw [ArgumentException]::new('Credential store path must be absolute.')
    }
    $fullPath = [IO.Path]::GetFullPath($StorePath)
    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) {
        $workspace = [IO.Path]::GetFullPath($env:GITHUB_WORKSPACE)
        $separator = [IO.Path]::DirectorySeparatorChar
        if (-not $workspace.EndsWith([string]$separator)) {
            $workspace += $separator
        }
        if ($fullPath.StartsWith($workspace, [StringComparison]::OrdinalIgnoreCase)) {
            throw [ArgumentException]::new(
                'Credential store must never be inside the GitHub workspace.'
            )
        }
    }
    return $fullPath
}

function ConvertTo-MishLowerHex {
    param([Parameter(Mandatory)][byte[]] $Bytes)

    return [Convert]::ToHexString($Bytes).ToLowerInvariant()
}

function Read-MishProtoVarint {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][ref] $Offset
    )

    [uint64]$result = 0
    for ($index = 0; $index -lt 10; $index++) {
        if ($Offset.Value -ge $Bytes.Length) {
            throw [InvalidDataException]::new('Provisioned credential protobuf varint is truncated.')
        }
        $current = [int]$Bytes[$Offset.Value]
        $Offset.Value++
        if ($index -eq 9 -and (($current -band 0xfe) -ne 0)) {
            throw [InvalidDataException]::new('Provisioned credential protobuf varint overflows uint64.')
        }
        $piece = ([uint64]($current -band 0x7f)) -shl (7 * $index)
        $result = $result -bor $piece
        if (($current -band 0x80) -eq 0) {
            return $result
        }
    }
    throw [InvalidDataException]::new('Provisioned credential protobuf varint is too long.')
}

function Read-MishProtoBytes {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][ref] $Offset
    )

    $length = Read-MishProtoVarint -Bytes $Bytes -Offset $Offset
    if ($length -gt [int]::MaxValue) {
        throw [InvalidDataException]::new('Provisioned credential protobuf field is too large.')
    }
    $count = [int]$length
    if ($count -gt ($Bytes.Length - $Offset.Value)) {
        throw [InvalidDataException]::new('Provisioned credential protobuf field is truncated.')
    }
    $result = New-Object byte[] $count
    if ($count -gt 0) {
        [Array]::Copy($Bytes, $Offset.Value, $result, 0, $count)
    }
    $Offset.Value += $count
    return ,$result
}

function Skip-MishProtoField {
    param(
        [Parameter(Mandatory)][byte[]] $Bytes,
        [Parameter(Mandatory)][ref] $Offset,
        [Parameter(Mandatory)][int] $WireType
    )

    switch ($WireType) {
        0 { [void](Read-MishProtoVarint -Bytes $Bytes -Offset $Offset); return }
        1 { $count = 8 }
        2 {
            $length = Read-MishProtoVarint -Bytes $Bytes -Offset $Offset
            if ($length -gt [int]::MaxValue) {
                throw [InvalidDataException]::new('Provisioned credential protobuf field is too large.')
            }
            $count = [int]$length
        }
        5 { $count = 4 }
        default {
            throw [InvalidDataException]::new('Provisioned credential protobuf wire type is unsupported.')
        }
    }
    if ($count -gt ($Bytes.Length - $Offset.Value)) {
        throw [InvalidDataException]::new('Provisioned credential protobuf field is truncated.')
    }
    $Offset.Value += $count
}

function ConvertFrom-MishProvisioningEnvelope {
    param(
        [Parameter(Mandatory)][byte[]] $Plaintext,
        [string] $ExpectedChallengeHex
    )

    $offset = 0
    $schemaSeen = $false
    $versionSeen = $false
    $idSeen = $false
    $challengeSeen = $false
    $usernameSeen = $false
    $passwordSeen = $false
    [uint64]$schemaVersion = 0
    [uint64]$credentialVersionValue = 0
    $credentialId = $null
    $challengeBytes = $null
    $userName = $null
    $password = $null

    try {
        while ($offset -lt $Plaintext.Length) {
            $key = Read-MishProtoVarint -Bytes $Plaintext -Offset ([ref]$offset)
            if ($key -eq 0) {
                throw [InvalidDataException]::new('Provisioned credential protobuf tag is invalid.')
            }
            $fieldNumber = [int]($key -shr 3)
            $wireType = [int]($key -band 7)
            if ($fieldNumber -le 0) {
                throw [InvalidDataException]::new('Provisioned credential protobuf field number is invalid.')
            }

            switch ($fieldNumber) {
                1 {
                    if ($wireType -ne 0 -or $schemaSeen) { throw 'malformed schema_version' }
                    $schemaSeen = $true
                    $schemaVersion = Read-MishProtoVarint -Bytes $Plaintext -Offset ([ref]$offset)
                }
                2 {
                    if ($wireType -ne 0 -or $versionSeen) { throw 'malformed credential_version' }
                    $versionSeen = $true
                    $credentialVersionValue = Read-MishProtoVarint -Bytes $Plaintext -Offset ([ref]$offset)
                }
                3 {
                    if ($wireType -ne 2 -or $idSeen) { throw 'malformed credential_id' }
                    $idSeen = $true
                    $credentialId = $script:StrictUtf8.GetString(
                        (Read-MishProtoBytes -Bytes $Plaintext -Offset ([ref]$offset))
                    )
                }
                4 {
                    if ($wireType -ne 2 -or $challengeSeen) { throw 'malformed challenge' }
                    $challengeSeen = $true
                    $challengeBytes = Read-MishProtoBytes -Bytes $Plaintext -Offset ([ref]$offset)
                }
                5 {
                    if ($wireType -ne 2 -or $usernameSeen) { throw 'malformed username' }
                    $usernameSeen = $true
                    $userName = $script:StrictUtf8.GetString(
                        (Read-MishProtoBytes -Bytes $Plaintext -Offset ([ref]$offset))
                    )
                }
                6 {
                    if ($wireType -ne 2 -or $passwordSeen) { throw 'malformed password' }
                    $passwordSeen = $true
                    $password = $script:StrictUtf8.GetString(
                        (Read-MishProtoBytes -Bytes $Plaintext -Offset ([ref]$offset))
                    )
                }
                default {
                    Skip-MishProtoField -Bytes $Plaintext -Offset ([ref]$offset) -WireType $wireType
                }
            }
        }
    }
    catch {
        throw [InvalidDataException]::new('Provisioned credential protobuf envelope is malformed.')
    }

    if (-not ($schemaSeen -and $versionSeen -and $idSeen -and $challengeSeen -and $usernameSeen -and $passwordSeen)) {
        throw [InvalidDataException]::new('Provisioned credential protobuf envelope is incomplete.')
    }
    if ($schemaVersion -ne $script:ProvisioningSchemaVersion) {
        throw [InvalidDataException]::new('Provisioned credential protocol version is unsupported.')
    }
    if ($credentialVersionValue -eq 0) {
        throw [InvalidDataException]::new('Provisioned credential owner version is invalid.')
    }
    $credentialVersion = $credentialVersionValue.ToString([Globalization.CultureInfo]::InvariantCulture)
    if ($credentialId -cne "external-proxy-v$credentialVersion") {
        throw [InvalidDataException]::new('Provisioned credential identity/version mismatch.')
    }
    if ($null -eq $challengeBytes -or $challengeBytes.Length -ne 32) {
        throw [InvalidDataException]::new('Provisioned credential challenge is invalid.')
    }
    $challengeHex = ConvertTo-MishLowerHex -Bytes $challengeBytes
    if (
        -not [string]::IsNullOrEmpty($ExpectedChallengeHex) -and
        $challengeHex -cne $ExpectedChallengeHex
    ) {
        throw [InvalidDataException]::new('Provisioned credential challenge does not match this session.')
    }
    if ($userName -notmatch '^mish-[0-9a-f]{32}$') {
        throw [InvalidDataException]::new('Provisioned credential username shape is invalid.')
    }
    if ($password -notmatch '^[0-9a-f]{64}$') {
        throw [InvalidDataException]::new('Provisioned credential password shape is invalid.')
    }

    return [pscustomobject]@{
        CredentialVersion = $credentialVersion
        CredentialId = $credentialId
        ChallengeHex = $challengeHex
        UserName = $userName
        Password = $password
    }
}

function Get-MishAdbProvisioningCiphertext {
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [Parameter(Mandatory)][string] $PublicKeyBase64,
        [Parameter(Mandatory)][string] $ChallengeHex
    )

    $arguments = @(
        'shell', 'am', 'broadcast', '--user', '0',
        '-n', $script:ProvisioningComponent,
        '-a', $script:ProvisioningAction,
        '--es', $script:PublicKeyExtra, $PublicKeyBase64,
        '--es', $script:ChallengeExtra, $ChallengeHex
    )
    $output = @(& $AdbPath @arguments 2>$null)
    $exitCode = $LASTEXITCODE
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        throw [InvalidOperationException]::new(
            "ADB credential provisioning transport failed with exit code $exitCode."
        )
    }

    $match = [regex]::Match(
        ($output -join "`n"),
        'Broadcast completed:\s*result=(?<code>-?\d+)(?:,\s*data="(?<data>[^"]*)")?'
    )
    if (-not $match.Success) {
        throw [InvalidOperationException]::new(
            'ADB credential provisioning returned no bounded broadcast result.'
        )
    }
    $resultCode = [int]$match.Groups['code'].Value
    if ($resultCode -ne 1) {
        throw [InvalidOperationException]::new(
            "Android credential provisioning failed with typed result code $resultCode."
        )
    }
    $ciphertextBase64 = $match.Groups['data'].Value
    if ([string]::IsNullOrWhiteSpace($ciphertextBase64)) {
        throw [InvalidOperationException]::new(
            'Android credential provisioning returned an empty ciphertext.'
        )
    }
    try {
        return [Convert]::FromBase64String($ciphertextBase64)
    }
    catch {
        throw [InvalidDataException]::new(
            'Android credential provisioning returned malformed ciphertext.'
        )
    }
}

function Write-MishAtomicCredentialBlob {
    param(
        [Parameter(Mandatory)][string] $StorePath,
        [Parameter(Mandatory)][byte[]] $ProtectedBytes
    )

    $directory = Split-Path -Parent $StorePath
    [void][IO.Directory]::CreateDirectory($directory)
    $temporaryPath = "$StorePath.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllBytes($temporaryPath, $ProtectedBytes)
        Move-Item -LiteralPath $temporaryPath -Destination $StorePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-MishExternalProxyCredentialProvisioning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AdbPath,
        [string] $StorePath = (Get-MishDefaultCredentialStorePath)
    )

    $resolvedStorePath = Assert-MishCredentialStorePath -StorePath $StorePath
    $rsa = [Security.Cryptography.RSA]::Create()
    $rsa.KeySize = 3072
    $challenge = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Fill($challenge)
    $challengeHex = ConvertTo-MishLowerHex -Bytes $challenge
    $publicKeyDer = $rsa.ExportSubjectPublicKeyInfo()
    $publicKeyBase64 = [Convert]::ToBase64String($publicKeyDer)
    $ciphertext = $null
    $plaintext = $null
    $protected = $null

    try {
        $ciphertext = Get-MishAdbProvisioningCiphertext `
            -AdbPath $AdbPath `
            -PublicKeyBase64 $publicKeyBase64 `
            -ChallengeHex $challengeHex
        try {
            $plaintext = $rsa.Decrypt(
                $ciphertext,
                [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256
            )
        }
        catch {
            throw [InvalidDataException]::new(
                'Provisioned credential envelope failed RSA-OAEP authentication/decryption.'
            )
        }

        $envelope = ConvertFrom-MishProvisioningEnvelope `
            -Plaintext $plaintext `
            -ExpectedChallengeHex $challengeHex
        $protected = [Security.Cryptography.ProtectedData]::Protect(
            $plaintext,
            $script:StoreEntropy,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        Write-MishAtomicCredentialBlob `
            -StorePath $resolvedStorePath `
            -ProtectedBytes $protected

        return [pscustomobject]@{
            Schema = 'mish.credentials.v1.ExternalProxyProvisioningEnvelope'
            CredentialVersion = $envelope.CredentialVersion
            CredentialId = $envelope.CredentialId
            StorePath = $resolvedStorePath
            Protection = 'DPAPI-CurrentUser'
        }
    }
    finally {
        if ($null -ne $plaintext) {
            [Array]::Clear($plaintext, 0, $plaintext.Length)
        }
        if ($null -ne $protected) {
            [Array]::Clear($protected, 0, $protected.Length)
        }
        if ($null -ne $ciphertext) {
            [Array]::Clear($ciphertext, 0, $ciphertext.Length)
        }
        [Array]::Clear($challenge, 0, $challenge.Length)
        [Array]::Clear($publicKeyDer, 0, $publicKeyDer.Length)
        $rsa.Dispose()
    }
}

function Open-MishExternalProxyCredentialLease {
    [CmdletBinding()]
    param(
        [string] $StorePath = (Get-MishDefaultCredentialStorePath)
    )

    $resolvedStorePath = Assert-MishCredentialStorePath -StorePath $StorePath
    if (-not (Test-Path -LiteralPath $resolvedStorePath -PathType Leaf)) {
        throw [IO.FileNotFoundException]::new('Provisioned credential store is absent.')
    }

    $protected = [IO.File]::ReadAllBytes($resolvedStorePath)
    $plaintext = $null
    try {
        try {
            $plaintext = [Security.Cryptography.ProtectedData]::Unprotect(
                $protected,
                $script:StoreEntropy,
                [Security.Cryptography.DataProtectionScope]::CurrentUser
            )
        }
        catch {
            throw [InvalidDataException]::new(
                'Provisioned credential store cannot be opened by this Windows identity.'
            )
        }
        $envelope = ConvertFrom-MishProvisioningEnvelope -Plaintext $plaintext
        $securePassword = [Security.SecureString]::new()
        $passwordCharacters = $envelope.Password.ToCharArray()
        try {
            foreach ($character in $passwordCharacters) {
                $securePassword.AppendChar($character)
            }
            $securePassword.MakeReadOnly()
        }
        finally {
            [Array]::Clear($passwordCharacters, 0, $passwordCharacters.Length)
        }

        return [MishExternalProxyCredentialLease]::new(
            $envelope.CredentialVersion,
            $envelope.CredentialId,
            $envelope.UserName,
            $securePassword
        )
    }
    finally {
        [Array]::Clear($protected, 0, $protected.Length)
        if ($null -ne $plaintext) {
            [Array]::Clear($plaintext, 0, $plaintext.Length)
        }
    }
}

Export-ModuleMember -Function @(
    'Invoke-MishExternalProxyCredentialProvisioning',
    'Open-MishExternalProxyCredentialLease'
)
