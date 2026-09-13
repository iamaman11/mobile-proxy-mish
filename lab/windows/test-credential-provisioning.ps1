Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'CredentialProvisioning.psm1'
Import-Module $modulePath -Force

$testRoot = Join-Path $env:TEMP ('mish-credential-provisioning-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$fakeAdbScript = Join-Path $testRoot 'fake-adb.ps1'
$fakeAdbCommand = Join-Path $testRoot 'fake-adb.cmd'
$storePath = Join-Path $testRoot 'client-store.dpapi'
$badStorePath = Join-Path $testRoot 'bad-client-store.dpapi'
$syntheticUser = 'mish-11111111111111111111111111111111'
$syntheticPassword = '2222222222222222222222222222222222222222222222222222222222222222'

try {
    @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptArguments = @($args)

function Get-ArgumentValue {
    param([Parameter(Mandatory)][string] $Name)
    for ($index = 0; $index -lt $scriptArguments.Count - 1; $index++) {
        if ([string]$scriptArguments[$index] -ceq $Name) {
            return [string]$scriptArguments[$index + 1]
        }
    }
    throw "Missing fake ADB argument: $Name"
}

function Add-ProtoVarint {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]] $Buffer,
        [Parameter(Mandatory)][uint64] $Value
    )
    $remaining = $Value
    while ($remaining -ge 128) {
        $Buffer.Add([byte](([int]($remaining -band 0x7f)) -bor 0x80))
        $remaining = $remaining -shr 7
    }
    $Buffer.Add([byte]$remaining)
}

function Add-ProtoVarintField {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]] $Buffer,
        [Parameter(Mandatory)][int] $FieldNumber,
        [Parameter(Mandatory)][uint64] $Value
    )
    Add-ProtoVarint -Buffer $Buffer -Value ([uint64](($FieldNumber -shl 3) -bor 0))
    Add-ProtoVarint -Buffer $Buffer -Value $Value
}

function Add-ProtoBytesField {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[byte]] $Buffer,
        [Parameter(Mandatory)][int] $FieldNumber,
        [Parameter(Mandatory)][byte[]] $Value
    )
    Add-ProtoVarint -Buffer $Buffer -Value ([uint64](($FieldNumber -shl 3) -bor 2))
    Add-ProtoVarint -Buffer $Buffer -Value ([uint64]$Value.Length)
    $Buffer.AddRange($Value)
}

$publicKeyBase64 = Get-ArgumentValue -Name 'client_public_key_spki_b64'
$challengeHex = Get-ArgumentValue -Name 'challenge_hex'
if ($env:MISH_FAKE_BAD_CHALLENGE -eq '1') {
    $challengeHex = ('00' * 32) -join ''
}

$rsa = [Security.Cryptography.RSA]::Create()
try {
    $publicKeyBytes = [Convert]::FromBase64String($publicKeyBase64)
    $bytesRead = 0
    $rsa.ImportSubjectPublicKeyInfo($publicKeyBytes, [ref]$bytesRead)
    if ($bytesRead -ne $publicKeyBytes.Length) {
        throw 'Fake ADB public key import was incomplete.'
    }

    $payload = [System.Collections.Generic.List[byte]]::new()
    Add-ProtoVarintField -Buffer $payload -FieldNumber 1 -Value 1
    Add-ProtoVarintField -Buffer $payload -FieldNumber 2 -Value 7
    Add-ProtoBytesField -Buffer $payload -FieldNumber 3 -Value ([Text.Encoding]::UTF8.GetBytes('external-proxy-v7'))
    Add-ProtoBytesField -Buffer $payload -FieldNumber 4 -Value ([Convert]::FromHexString($challengeHex))
    Add-ProtoBytesField -Buffer $payload -FieldNumber 5 -Value ([Text.Encoding]::UTF8.GetBytes('mish-11111111111111111111111111111111'))
    Add-ProtoBytesField -Buffer $payload -FieldNumber 6 -Value ([Text.Encoding]::UTF8.GetBytes('2222222222222222222222222222222222222222222222222222222222222222'))
    $plaintext = $payload.ToArray()

    $ciphertext = $rsa.Encrypt(
        $plaintext,
        [Security.Cryptography.RSAEncryptionPadding]::OaepSHA256
    )
    $encoded = [Convert]::ToBase64String($ciphertext)
    Write-Output "Broadcast completed: result=1, data=`"$encoded`""
}
finally {
    $rsa.Dispose()
}
'@ | Set-Content -LiteralPath $fakeAdbScript -Encoding UTF8

    $pwshExe = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $pwshExe -PathType Leaf)) {
        throw 'Hosted credential provisioning self-test requires native pwsh.exe.'
    }
    @"
@echo off
"$pwshExe" -NoLogo -NoProfile -NonInteractive -File "$fakeAdbScript" %*
"@ | Set-Content -LiteralPath $fakeAdbCommand -Encoding ASCII

    $result = Invoke-MishExternalProxyCredentialProvisioning `
        -AdbPath $fakeAdbCommand `
        -StorePath $storePath
    if ($result.Schema -ne 'mish.credentials.v1.ExternalProxyProvisioningEnvelope') {
        throw 'Provisioning result schema drifted.'
    }
    if ($result.CredentialVersion -ne '7' -or $result.CredentialId -ne 'external-proxy-v7') {
        throw 'Provisioning result owner identity drifted.'
    }
    if ($result.Protection -ne 'DPAPI-CurrentUser') {
        throw 'Provisioning result storage protection drifted.'
    }
    if (-not (Test-Path -LiteralPath $storePath -PathType Leaf)) {
        throw 'Provisioning did not persist the DPAPI blob.'
    }

    $resultDisplay = $result | Out-String
    if ($resultDisplay.Contains($syntheticUser) -or $resultDisplay.Contains($syntheticPassword)) {
        throw 'Provisioning metadata output leaked synthetic credential material.'
    }
    $storedBytes = [IO.File]::ReadAllBytes($storePath)
    try {
        $storedText = [Text.Encoding]::UTF8.GetString($storedBytes)
        if ($storedText.Contains($syntheticUser) -or $storedText.Contains($syntheticPassword)) {
            throw 'DPAPI store contains plaintext synthetic credential material.'
        }
    }
    finally {
        [Array]::Clear($storedBytes, 0, $storedBytes.Length)
    }

    $lease = Open-MishExternalProxyCredentialLease -StorePath $storePath
    if ($lease.CredentialVersion -ne '7' -or $lease.CredentialId -ne 'external-proxy-v7') {
        throw 'Opened credential lease owner identity drifted.'
    }
    $leaseDisplay = $lease | Out-String
    if ($leaseDisplay.Contains($syntheticUser) -or $leaseDisplay.Contains($syntheticPassword)) {
        throw 'Credential lease ordinary rendering leaked synthetic credential material.'
    }
    if ($lease.ProxyUserName -cne $syntheticUser) {
        throw 'Credential lease username did not round-trip.'
    }
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($lease.ProxyPassword)
    try {
        $roundTripPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        if ($roundTripPassword -cne $syntheticPassword) {
            throw 'Credential lease password did not round-trip.'
        }
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }

    $env:MISH_FAKE_BAD_CHALLENGE = '1'
    $failedClosed = $false
    try {
        [void](Invoke-MishExternalProxyCredentialProvisioning `
            -AdbPath $fakeAdbCommand `
            -StorePath $badStorePath)
    }
    catch {
        if ($_.Exception.Message -cne 'Provisioned credential challenge does not match this session.') {
            throw
        }
        $failedClosed = $true
    }
    finally {
        Remove-Item Env:MISH_FAKE_BAD_CHALLENGE -ErrorAction SilentlyContinue
    }
    if (-not $failedClosed) {
        throw 'Provisioning accepted a replay/challenge mismatch.'
    }
    if (Test-Path -LiteralPath $badStorePath) {
        throw 'Failed provisioning transaction wrote a credential store.'
    }

    Write-Output 'Credential provisioning protobuf hosted self-test passed.'
}
finally {
    Remove-Module CredentialProvisioning -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
