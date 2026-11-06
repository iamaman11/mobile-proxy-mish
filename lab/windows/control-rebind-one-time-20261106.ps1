# One-time CONTROL recommissioning, only from owner-gated GitHub Actions.
# No Android install or restart, no new app/service/secret store.
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = 'C:\mish-lab\staging\pr-477-23bb9792-debug-noninstall-20261106'
$adb = 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe'
$signer = 'C:\mish-lab\tools\android-sdk\build-tools\36.0.0\apksigner.bat'
$expectedDigest = '9b198ae6a59d8a90357be58a338b52a285a85bb2240dda6523722abece0b32b5'
$expectedCert = '305f924fc7810d8bf6e566ae244e0f6e850533c458efb8c01c67ce4ecc16a595'
$oldPath = Join-Path $root 'old-control-public-identity-rebind-private.json'
$newPath = Join-Path $root 'new-control-public-identity-rebind-private.json'
foreach ($file in @($adb, $signer, $oldPath, $newPath)) {
    if (-not [IO.File]::Exists($file)) { throw 'CONTROL_REBIND_PREREQUISITE_MISSING' }
}
$devices = @(& $adb devices | Where-Object { $_ -match '^\S+\s+device\s*$' })
if ($LASTEXITCODE -ne 0 -or $devices.Count -ne 1) {
    throw 'CONTROL_REBIND_DEVICE_COUNT_NOT_ONE'
}
$paths = @(& $adb shell pm path com.mobileproxymish.app.debug)
if ($LASTEXITCODE -ne 0) { throw 'CONTROL_REBIND_PACKAGE_UNAVAILABLE' }
$base = @($paths | Where-Object { $_ -match '^package:.+/base\.apk$' })
if ($base.Count -ne 1) { throw 'CONTROL_REBIND_BASE_APK_NOT_UNIQUE' }
$apk = Join-Path $env:RUNNER_TEMP 'mish-control-rebind-readonly-base.apk'
if ([IO.File]::Exists($apk)) { throw 'CONTROL_REBIND_TEMP_APK_ALREADY_EXISTS' }
try {
    & $adb pull ($base[0].Substring(8)) $apk 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'CONTROL_REBIND_PULL_FAILED' }
    $digest = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($digest -cne $expectedDigest) { throw 'CONTROL_REBIND_APK_BYTES_MISMATCH' }
    $proof = @(& $signer verify --print-certs $apk 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'CONTROL_REBIND_APK_SIGNING_INVALID' }
    $match = [regex]::Match(($proof -join [Environment]::NewLine),
        '(?im)^Signer #1 certificate SHA-256 digest:\s*([0-9a-f:]{64,95})\s*$')
    if (-not $match.Success -or
        $match.Groups[1].Value.Replace(':', '').ToLowerInvariant() -cne $expectedCert) {
        throw 'CONTROL_REBIND_APK_CERT_MISMATCH'
    }
} finally {
    Remove-Item -LiteralPath $apk -Force -ErrorAction SilentlyContinue
}
$old = Get-Content -Raw -LiteralPath $oldPath | ConvertFrom-Json
$new = Get-Content -Raw -LiteralPath $newPath | ConvertFrom-Json
foreach ($identity in @($old, $new)) {
    $deviceId = [string]$identity.device_id
    if ($deviceId -cnotmatch '^[0-9a-f]{64}$') { throw 'CONTROL_REBIND_BAD_DEVICE_ID' }
    $spkiBytes = [Convert]::FromBase64String([string]$identity.public_key_spki_b64)
    $computed = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($spkiBytes)).ToLowerInvariant()
    if ($computed -cne $deviceId) { throw 'CONTROL_REBIND_SPKI_ID_MISMATCH' }
}
if ($old.device_id -ceq $new.device_id) { throw 'CONTROL_REBIND_IDENTITIES_NOT_DISTINCT' }
$component = 'com.mobileproxymish.app.debug/com.mobileproxymish.app.ControlIdentityProvisioningReceiver'
$action = 'com.mobileproxymish.app.action.READ_CONTROL_IDENTITY_V1'
$observed = @(& $adb shell am broadcast -n $component -a $action)
if ($LASTEXITCODE -ne 0) { throw 'CONTROL_REBIND_BROADCAST_FAILED' }
$match = [regex]::Match(($observed -join [Environment]::NewLine),
    'mish-control-identity-v1:([0-9a-f]{64}):([A-Za-z0-9+/=]+)')
if (-not $match.Success -or
    $match.Groups[1].Value -cne [string]$new.device_id -or
    $match.Groups[2].Value -cne [string]$new.public_key_spki_b64) {
    throw 'CONTROL_REBIND_DEVICE_PUBLIC_IDENTITY_MISMATCH'
}
Write-Output 'CONTROL_REBIND_PHYSICAL_PREFLIGHT=PASS'

# Single authorized CAS: never redirect, log secret, or automatically retry.
$token = [string]$env:MISH_MANAGER_TOKEN
if ($token.Length -lt 32) { throw 'CONTROL_REBIND_MANAGER_TOKEN_UNAVAILABLE' }
Remove-Item Env:\MISH_MANAGER_TOKEN -ErrorAction SilentlyContinue
$handler = [Net.Http.HttpClientHandler]::new()
$handler.UseProxy = $false
$handler.AllowAutoRedirect = $false
$client = [Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(25)
$response = $null
$request = $null
try {
    $url = "https://mish.alegria.by/v1/devices/$($new.device_id)"
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Put, [Uri]$url)
    $request.Headers.Authorization =
        [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
    $body = @{
        public_key_spki_b64 = [string]$new.public_key_spki_b64
        expected_device_id = [string]$old.device_id
    } | ConvertTo-Json -Compress
    $request.Content = [Net.Http.StringContent]::new(
        $body, [Text.Encoding]::UTF8, 'application/json')
    $response = $client.Send($request)
    $status = [int]$response.StatusCode
    $json = $null
    try {
        $json = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() |
            ConvertFrom-Json -ErrorAction Stop
    } catch {}
    if ($status -ne 200 -or $null -eq $json -or
        $json.enrolled -ne $true -or $json.replaced -ne $true) {
        Write-Output "CONTROL_REBIND_HTTP_STATUS=$status"
        throw 'CONTROL_REBIND_UNCONFIRMED_NO_AUTOMATIC_RETRY'
    }
    Write-Output 'CONTROL_REBIND_RESULT=PASS'
    Write-Output 'CONTROL_REBIND_SECRET_DISCLOSED=NO'
} finally {
    if ($null -ne $response) { $response.Dispose() }
    if ($null -ne $request) { $request.Dispose() }
    $client.Dispose()
    $handler.Dispose()
}
