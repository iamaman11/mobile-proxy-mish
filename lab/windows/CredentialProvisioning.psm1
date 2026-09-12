Set-StrictMode -Version Latest

$script:ProvisioningAction = 'com.mobileproxymish.app.action.PROVISION_EXTERNAL_PROXY_V1'
$script:ProvisioningComponent = 'com.mobileproxymish.app/.CredentialProvisioningReceiver'
$script:PublicKeyExtra = 'client_public_key_spki_b64'
$script:ChallengeExtra = 'challenge_hex'
$script:StoreEntropy = [System.Text.Encoding]::UTF8.GetBytes(
    'mobile-proxy-mish/windows/external-proxy-dpapi/v1'
)

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

function ConvertFrom-MishProvisioningEnvelope {
    param(
        [Parameter(Mandatory)][byte[]] $Plaintext,
        [string] $ExpectedChallengeHex
    )

    try {
        $json = [Text.Encoding]::UTF8.GetString($Plaintext)
        $payload = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw [InvalidDataException]::new('Provisioned credential envelope is malformed.')
    }

    if ([int]$payload.v -ne 1) {
        throw [InvalidDataException]::new('Provisioned credential protocol version is unsupported.')
    }
    $credentialVersion = [string]$payload.cv
    if ($credentialVersion -notmatch '^[1-9][0-9]{0,19}$') {
        throw [InvalidDataException]::new('Provisioned credential owner version is invalid.')
    }
    $credentialId = [string]$payload.id
    if ($credentialId -ne "external-proxy-v$credentialVersion") {
        throw [InvalidDataException]::new('Provisioned credential identity/version mismatch.')
    }
    $challengeHex = [string]$payload.c
    if ($challengeHex -notmatch '^[0-9a-f]{64}$') {
        throw [InvalidDataException]::new('Provisioned credential challenge is invalid.')
    }
    if (
        -not [string]::IsNullOrEmpty($ExpectedChallengeHex) -and
        $challengeHex -cne $ExpectedChallengeHex
    ) {
        throw [InvalidDataException]::new('Provisioned credential challenge does not match this session.')
    }
    $userName = [string]$payload.u
    $password = [string]$payload.p
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
            Schema = 'mish.external-proxy.windows-store/v1'
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
