Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Repository = 'iamaman11/mobile-proxy-mish'
$script:ReleaseSchema = 'mish.android-release/v1'
$script:ResolutionSchema = 'mish.lab.release-resolution/v1'
$script:VerificationSchema = 'mish.lab.release-verification/v1'
$script:EvidenceSchema = 'mish.lab.evidence/v1'
$script:RcTagPattern = '^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-rc\.([1-9]\d*)$'
$script:Hex40Pattern = '^[0-9a-f]{40}$'
$script:Hex64Pattern = '^[0-9a-f]{64}$'

function Stop-Labctl {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Message
    )
    throw "MISH_LABCTL_FAILURE|$Category|$Message"
}

function Assert-RcTag {
    param([Parameter(Mandatory)][string]$Tag)
    if ($Tag -notmatch $script:RcTagPattern) {
        Stop-Labctl 'IDENTITY_MISMATCH' 'RC tag must match vMAJOR.MINOR.PATCH-rc.N.'
    }
}

function Assert-Hex40 {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -notmatch $script:Hex40Pattern) {
        Stop-Labctl 'IDENTITY_MISMATCH' "$Name must be a lowercase 40-hex SHA."
    }
}

function Assert-Hex64 {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)
    if ($Value -notmatch $script:Hex64Pattern) {
        Stop-Labctl 'IDENTITY_MISMATCH' "$Name must be a lowercase 64-hex SHA-256."
    }
}

function Write-LabJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if ($parent) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($full, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    return $full
}

function Read-LabJson {
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Stop-Labctl 'ARTIFACT_MISSING' "Required JSON file is missing: $full"
    }
    try {
        return Get-Content -Raw -LiteralPath $full | ConvertFrom-Json
    }
    catch {
        Stop-Labctl 'ARTIFACT_INVALID' "Required JSON file is not valid JSON: $full"
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-Labctl 'ARTIFACT_MISSING' "Required artifact is missing: $Path"
    }
    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-ReleaseAsset {
    param(
        [Parameter(Mandatory)]$Release,
        [Parameter(Mandatory)][string]$Name
    )
    $matches = @($Release.assets | Where-Object { [string]$_.name -eq $Name })
    if ($matches.Count -ne 1) {
        Stop-Labctl 'RELEASE_INVALID' "Release must contain exactly one asset named $Name."
    }
    return $matches[0]
}

function Invoke-GitHubJson {
    param([Parameter(Mandatory)][string]$Uri)
    $headers = @{
        'Accept' = 'application/vnd.github+json'
        'User-Agent' = 'mobile-proxy-mish-labctl'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers -MaximumRedirection 5
    }
    catch {
        Stop-Labctl 'RELEASE_UNAVAILABLE' 'Exact GitHub Release metadata could not be read.'
    }
}

function Invoke-ArtifactDownload {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$Destination
    )
    $headers = @{ 'User-Agent' = 'mobile-proxy-mish-labctl' }
    try {
        Invoke-WebRequest -Method Get -Uri $Uri -Headers $headers -MaximumRedirection 10 -OutFile $Destination
    }
    catch {
        Stop-Labctl 'RELEASE_UNAVAILABLE' 'Exact GitHub Release asset download failed.'
    }
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        Stop-Labctl 'ARTIFACT_MISSING' 'Downloaded release asset is missing.'
    }
}

function Assert-ManifestTuple {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][string]$ExpectedApkSha256,
        [Parameter(Mandatory)][string]$ExpectedSigningCertificateSha256,
        [Parameter(Mandatory)][string]$ExpectedApkName
    )
    if ([string]$Manifest.schema -ne $script:ReleaseSchema -or [string]$Manifest.channel -ne 'rc') {
        Stop-Labctl 'RELEASE_INVALID' 'Release manifest schema/channel mismatch.'
    }
    if ([string]$Manifest.product.release_tag -ne $Tag) {
        Stop-Labctl 'IDENTITY_MISMATCH' 'Manifest release tag does not match the authorized tag.'
    }
    if ([string]$Manifest.product.source_commit -ne $ExpectedSourceCommit) {
        Stop-Labctl 'IDENTITY_MISMATCH' 'Manifest source commit does not match the authorized source commit.'
    }
    if ([string]$Manifest.product.abi -ne 'arm64-v8a' -or [string]$Manifest.product.build_mode -ne 'release') {
        Stop-Labctl 'IDENTITY_MISMATCH' 'Manifest Android ABI/build mode is not the releasable product contract.'
    }
    if ([string]$Manifest.artifact.name -ne $ExpectedApkName) {
        Stop-Labctl 'IDENTITY_MISMATCH' 'Manifest APK asset name mismatch.'
    }
    if ([string]$Manifest.artifact.sha256 -ne $ExpectedApkSha256) {
        Stop-Labctl 'DIGEST_MISMATCH' 'Manifest APK SHA-256 does not match the authorized digest.'
    }
    if ([string]$Manifest.artifact.signing_certificate_sha256 -ne $ExpectedSigningCertificateSha256) {
        Stop-Labctl 'SIGNING_IDENTITY_MISMATCH' 'Manifest signing certificate does not match the authorized signing identity.'
    }
}

function Resolve-Executable {
    param([Parameter(Mandatory)][string]$Command)
    if ([IO.Path]::IsPathFullyQualified($Command)) {
        if (-not (Test-Path -LiteralPath $Command -PathType Leaf)) {
            Stop-Labctl 'HOST_PREREQUISITE_MISSING' 'Required executable path does not exist.'
        }
        return [IO.Path]::GetFullPath($Command)
    }
    $resolved = Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue
    if (-not $resolved) {
        Stop-Labctl 'HOST_PREREQUISITE_MISSING' "Required executable is unavailable: $Command"
    }
    return $resolved.Source
}

function Invoke-LabProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60
    )
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $FilePath
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) {
        Stop-Labctl 'PROCESS_FAILED' 'Required subprocess could not be started.'
    }
    try {
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { $process.Kill($true) } catch { }
            Stop-Labctl 'PROCESS_TIMEOUT' 'Required subprocess exceeded its bounded timeout.'
        }
        $stdout = $process.StandardOutput.ReadToEnd()
        $stderr = $process.StandardError.ReadToEnd()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        StdOut = $stdout
        StdErr = $stderr
    }
}

function Invoke-ReleaseResolve {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][string]$ExpectedApkSha256,
        [Parameter(Mandatory)][string]$ExpectedSigningCertificateSha256,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ReceiptPath
    )
    Assert-RcTag $Tag
    Assert-Hex40 $ExpectedSourceCommit 'ExpectedSourceCommit'
    Assert-Hex64 $ExpectedApkSha256 'ExpectedApkSha256'
    Assert-Hex64 $ExpectedSigningCertificateSha256 'ExpectedSigningCertificateSha256'

    $outputDirectory = [IO.Path]::GetFullPath($Directory)
    [IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
    $escapedTag = [Uri]::EscapeDataString($Tag)
    $release = Invoke-GitHubJson "https://api.github.com/repos/$script:Repository/releases/tags/$escapedTag"
    if ([string]$release.tag_name -ne $Tag -or $release.draft -ne $false -or $release.prerelease -ne $true) {
        Stop-Labctl 'RELEASE_INVALID' 'Exact release is not the expected published RC prerelease.'
    }
    if (@($release.assets).Count -ne 2) {
        Stop-Labctl 'RELEASE_INVALID' 'RC release must contain exactly the product APK and release manifest.'
    }

    $apkName = "mobile-proxy-mish-$Tag.apk"
    $manifestName = "mobile-proxy-mish-$Tag.release.json"
    $apkAsset = Get-ReleaseAsset $release $apkName
    $manifestAsset = Get-ReleaseAsset $release $manifestName

    $apiDigest = [string]$apkAsset.digest
    if ($apiDigest -ne "sha256:$ExpectedApkSha256") {
        Stop-Labctl 'DIGEST_MISMATCH' 'GitHub Release APK digest does not match the authorized digest.'
    }

    $apkPath = Join-Path $outputDirectory $apkName
    $manifestPath = Join-Path $outputDirectory $manifestName
    Invoke-ArtifactDownload ([string]$manifestAsset.browser_download_url) $manifestPath
    $manifest = Read-LabJson $manifestPath
    Assert-ManifestTuple $manifest $Tag $ExpectedSourceCommit $ExpectedApkSha256 $ExpectedSigningCertificateSha256 $apkName

    Invoke-ArtifactDownload ([string]$apkAsset.browser_download_url) $apkPath
    $actualDigest = Get-FileSha256 $apkPath
    if ($actualDigest -ne $ExpectedApkSha256) {
        Stop-Labctl 'DIGEST_MISMATCH' 'Downloaded APK SHA-256 does not match the authorized digest.'
    }

    $receipt = [ordered]@{
        schema = $script:ResolutionSchema
        result = 'PASS'
        repository = $script:Repository
        release_id = [long]$release.id
        tag = $Tag
        source_commit = $ExpectedSourceCommit
        apk = [ordered]@{
            name = $apkName
            sha256 = $ExpectedApkSha256
            signing_certificate_sha256 = $ExpectedSigningCertificateSha256
            path = [IO.Path]::GetFullPath($apkPath)
        }
        manifest = [ordered]@{
            name = $manifestName
            path = [IO.Path]::GetFullPath($manifestPath)
        }
        resolved_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $written = Write-LabJson $receipt $ReceiptPath
    return [pscustomobject]@{ result = 'PASS'; tag = $Tag; apk_sha256 = $ExpectedApkSha256; receipt = $written }
}

function Invoke-ReleaseVerify {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][string]$ExpectedApkSha256,
        [Parameter(Mandatory)][string]$ExpectedSigningCertificateSha256,
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ReceiptPath
    )
    Assert-RcTag $Tag
    Assert-Hex40 $ExpectedSourceCommit 'ExpectedSourceCommit'
    Assert-Hex64 $ExpectedApkSha256 'ExpectedApkSha256'
    Assert-Hex64 $ExpectedSigningCertificateSha256 'ExpectedSigningCertificateSha256'

    $apkName = "mobile-proxy-mish-$Tag.apk"
    $manifestName = "mobile-proxy-mish-$Tag.release.json"
    $apkPath = Join-Path ([IO.Path]::GetFullPath($Directory)) $apkName
    $manifestPath = Join-Path ([IO.Path]::GetFullPath($Directory)) $manifestName
    $manifest = Read-LabJson $manifestPath
    Assert-ManifestTuple $manifest $Tag $ExpectedSourceCommit $ExpectedApkSha256 $ExpectedSigningCertificateSha256 $apkName
    $actualDigest = Get-FileSha256 $apkPath
    if ($actualDigest -ne $ExpectedApkSha256) {
        Stop-Labctl 'DIGEST_MISMATCH' 'Local APK SHA-256 does not match the authorized digest.'
    }

    $receipt = [ordered]@{
        schema = $script:VerificationSchema
        result = 'PASS'
        repository = $script:Repository
        tag = $Tag
        source_commit = $ExpectedSourceCommit
        apk = [ordered]@{
            name = $apkName
            sha256 = $ExpectedApkSha256
            signing_certificate_sha256 = $ExpectedSigningCertificateSha256
            path = [IO.Path]::GetFullPath($apkPath)
        }
        verified_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $written = Write-LabJson $receipt $ReceiptPath
    return [pscustomobject]@{ result = 'PASS'; tag = $Tag; apk_sha256 = $ExpectedApkSha256; receipt = $written }
}

function Assert-VerificationReceipt {
    param(
        [Parameter(Mandatory)]$Receipt,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][string]$ExpectedApkSha256,
        [Parameter(Mandatory)][string]$ExpectedSigningCertificateSha256
    )
    if ([string]$Receipt.schema -ne $script:VerificationSchema -or [string]$Receipt.result -ne 'PASS') {
        Stop-Labctl 'VERIFICATION_REQUIRED' 'A PASS release-verification receipt is required.'
    }
    if ([string]$Receipt.repository -ne $script:Repository -or [string]$Receipt.tag -ne $Tag -or [string]$Receipt.source_commit -ne $ExpectedSourceCommit) {
        Stop-Labctl 'IDENTITY_MISMATCH' 'Verification receipt identity does not match the authorized release.'
    }
    if ([string]$Receipt.apk.sha256 -ne $ExpectedApkSha256 -or [string]$Receipt.apk.signing_certificate_sha256 -ne $ExpectedSigningCertificateSha256) {
        Stop-Labctl 'DIGEST_MISMATCH' 'Verification receipt artifact identity does not match the authorized release.'
    }
    $apkPath = [string]$Receipt.apk.path
    if ((Get-FileSha256 $apkPath) -ne $ExpectedApkSha256) {
        Stop-Labctl 'DIGEST_MISMATCH' 'Verified APK bytes changed after verification.'
    }
    return [IO.Path]::GetFullPath($apkPath)
}

function Invoke-AndroidInspect {
    param([Parameter(Mandatory)][string]$AdbPath, [ValidateRange(1, 3600)][int]$TimeoutSeconds, [switch]$RequireNoDevice)
    $adb = Resolve-Executable $AdbPath
    $result = Invoke-LabProcess $adb @('devices') $TimeoutSeconds
    if ($result.ExitCode -ne 0) {
        Stop-Labctl 'PROCESS_FAILED' 'adb devices failed.'
    }
    $rows = @($result.StdOut -split "`r?`n" | Where-Object { $_ -match '^\S+\s+\S+\s*$' })
    if ($RequireNoDevice -and $rows.Count -ne 0) {
        Stop-Labctl 'DEVICE_PRESENT' 'Android device is present before PHONE-ON.'
    }
    $states = @($rows | ForEach-Object { ($_ -split '\s+')[1] } | Sort-Object -Unique)
    return [pscustomobject]@{ result = 'PASS'; device_count = $rows.Count; states = $states }
}

function Invoke-AndroidInstall {
    param(
        [Parameter(Mandatory)][string]$VerificationReceipt,
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$ExpectedSourceCommit,
        [Parameter(Mandatory)][string]$ExpectedApkSha256,
        [Parameter(Mandatory)][string]$ExpectedSigningCertificateSha256,
        [Parameter(Mandatory)][string]$AdbPath,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds
    )
    Assert-RcTag $Tag
    Assert-Hex40 $ExpectedSourceCommit 'ExpectedSourceCommit'
    Assert-Hex64 $ExpectedApkSha256 'ExpectedApkSha256'
    Assert-Hex64 $ExpectedSigningCertificateSha256 'ExpectedSigningCertificateSha256'
    $receipt = Read-LabJson $VerificationReceipt
    $apkPath = Assert-VerificationReceipt $receipt $Tag $ExpectedSourceCommit $ExpectedApkSha256 $ExpectedSigningCertificateSha256
    $adb = Resolve-Executable $AdbPath
    $result = Invoke-LabProcess $adb @('install', '-r', $apkPath) $TimeoutSeconds
    if ($result.ExitCode -ne 0 -or $result.StdOut -notmatch '(?m)^Success\s*$') {
        Stop-Labctl 'INSTALL_FAILED' 'adb install did not report Success.'
    }
    return [pscustomobject]@{ result = 'PASS'; tag = $Tag; apk_sha256 = $ExpectedApkSha256; installed = $true }
}

function Invoke-EvidenceCollect {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$EvidencePath)
    $receipt = Read-LabJson $InputPath
    if ([string]$receipt.schema -ne $script:VerificationSchema -or [string]$receipt.result -ne 'PASS') {
        Stop-Labctl 'VERIFICATION_REQUIRED' 'Evidence collection accepts only a PASS release-verification receipt.'
    }
    # Deliberate allowlist projection: paths, arbitrary extra fields and secret-shaped data are never copied.
    $evidence = [ordered]@{
        schema = $script:EvidenceSchema
        run_kind = 'release-consumer'
        repository = $script:Repository
        git_ref = [string]$env:GITHUB_REF
        git_commit = [string]$env:GITHUB_SHA
        run_id = [string]$env:GITHUB_RUN_ID
        result = 'PASS'
        failure = $null
        observations = [ordered]@{
            release = [ordered]@{
                tag = [string]$receipt.tag
                source_commit = [string]$receipt.source_commit
                apk_name = [string]$receipt.apk.name
                apk_sha256 = [string]$receipt.apk.sha256
                signing_certificate_sha256 = [string]$receipt.apk.signing_certificate_sha256
            }
        }
        completed_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $written = Write-LabJson $evidence $EvidencePath
    return [pscustomobject]@{ result = 'PASS'; evidence = $written; schema = $script:EvidenceSchema }
}

function Invoke-HostInspect {
    param([switch]$PhysicalLab)
    if (-not $IsWindows) {
        Stop-Labctl 'IDENTITY_MISMATCH' 'labctl host inspect requires Windows.'
    }
    $processPath = (Get-Process -Id $PID).Path
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    if ($PhysicalLab) {
        if ($env:GITHUB_REPOSITORY -ne $script:Repository -or $env:GITHUB_REF -ne 'refs/heads/main' -or $env:GITHUB_REF_PROTECTED -ne 'true') {
            Stop-Labctl 'UNTRUSTED_REF' 'Physical LAB inspection requires protected main.'
        }
        if ($env:RUNNER_OS -ne 'Windows' -or $env:RUNNER_ARCH -ne 'X64') {
            Stop-Labctl 'IDENTITY_MISMATCH' 'Physical LAB runner identity mismatch.'
        }
        if ($identity -ine 'NT AUTHORITY\NETWORK SERVICE') {
            Stop-Labctl 'IDENTITY_MISMATCH' 'Physical LAB service identity must be NetworkService.'
        }
        $expectedPwsh = 'C:\mish-lab\tools\powershell-7.6.6\pwsh.exe'
        if ([IO.Path]::GetFullPath($processPath) -ine [IO.Path]::GetFullPath($expectedPwsh)) {
            Stop-Labctl 'IDENTITY_MISMATCH' 'Physical LAB must use the accepted LAB-owned PowerShell runtime.'
        }
    }
    return [pscustomobject]@{
        result = 'PASS'
        os = 'Windows'
        architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        powershell = $PSVersionTable.PSVersion.ToString()
        service_identity = $identity
        physical_contract_enforced = [bool]$PhysicalLab
    }
}

function Invoke-Labctl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('host', 'release', 'android', 'evidence')][string]$Area,
        [Parameter(Mandatory)][string]$Action,
        [string]$Tag,
        [string]$ExpectedSourceCommit,
        [string]$ExpectedApkSha256,
        [string]$ExpectedSigningCertificateSha256,
        [string]$Directory,
        [string]$ReceiptPath,
        [string]$VerificationReceipt,
        [string]$InputPath,
        [string]$EvidencePath,
        [string]$AdbPath = 'adb',
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [switch]$PhysicalLab,
        [switch]$RequireNoDevice
    )

    switch ("$Area/$Action") {
        'host/inspect' { return Invoke-HostInspect -PhysicalLab:$PhysicalLab }
        'release/resolve' {
            foreach ($name in @('Tag','ExpectedSourceCommit','ExpectedApkSha256','ExpectedSigningCertificateSha256','Directory','ReceiptPath')) {
                if (-not (Get-Variable -Name $name -ValueOnly)) { Stop-Labctl 'INPUT_INVALID' "$name is required." }
            }
            return Invoke-ReleaseResolve $Tag $ExpectedSourceCommit $ExpectedApkSha256 $ExpectedSigningCertificateSha256 $Directory $ReceiptPath
        }
        'release/verify' {
            foreach ($name in @('Tag','ExpectedSourceCommit','ExpectedApkSha256','ExpectedSigningCertificateSha256','Directory','ReceiptPath')) {
                if (-not (Get-Variable -Name $name -ValueOnly)) { Stop-Labctl 'INPUT_INVALID' "$name is required." }
            }
            return Invoke-ReleaseVerify $Tag $ExpectedSourceCommit $ExpectedApkSha256 $ExpectedSigningCertificateSha256 $Directory $ReceiptPath
        }
        'android/inspect' { return Invoke-AndroidInspect $AdbPath $TimeoutSeconds -RequireNoDevice:$RequireNoDevice }
        'android/install' {
            foreach ($name in @('VerificationReceipt','Tag','ExpectedSourceCommit','ExpectedApkSha256','ExpectedSigningCertificateSha256')) {
                if (-not (Get-Variable -Name $name -ValueOnly)) { Stop-Labctl 'INPUT_INVALID' "$name is required." }
            }
            return Invoke-AndroidInstall $VerificationReceipt $Tag $ExpectedSourceCommit $ExpectedApkSha256 $ExpectedSigningCertificateSha256 $AdbPath $TimeoutSeconds
        }
        'evidence/collect' {
            if (-not $InputPath -or -not $EvidencePath) { Stop-Labctl 'INPUT_INVALID' 'InputPath and EvidencePath are required.' }
            return Invoke-EvidenceCollect $InputPath $EvidencePath
        }
        default { Stop-Labctl 'INPUT_INVALID' "Unsupported command: $Area $Action" }
    }
}

Export-ModuleMember -Function Invoke-Labctl
