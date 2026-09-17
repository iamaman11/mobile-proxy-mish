$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$probePath = Join-Path $PSScriptRoot 'diagnose-cloudflare-registration-recovery.ps1'

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'Cloudflare registration recovery probe must parse under PowerShell.'
}
if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
    throw 'Cloudflare registration recovery probe must not shadow the PowerShell automatic PID variable.'
}

$source = Get-Content -Raw -LiteralPath $probePath

foreach ($required in @(
    "`$script:Schema = 'mish.lab.cloudflare-registration-recovery/v1'",
    "`$ApiTokenEnvironmentVariable = 'CLOUDFLARE_API_TOKEN'",
    '/devices/registrations',
    "ValidateSet('revoke','unrevoke')",
    "-Action revoke",
    "-Action unrevoke",
    "`$registrationMayBeRevoked = `$true",
    "finally {",
    "Invoke-MishGuaranteedUnrevoke",
    "LAB_TARGET_UNREVOKE_CLEANUP_FAILED",
    "LAB_REGISTRATION_REVOKE_NO_OWNER_LOSS_WITHIN_WINDOW",
    "LAB_REGISTRATION_UNREVOKE_AUTORECOVERY_NOT_OBSERVED",
    "-TimeoutSeconds `$SnapshotTimeoutSeconds",
    "`$script:SnapshotPollMs = 2000",
    "`$script:PollMs = 250",
    "`$process.Kill(`$true)",
    "status=all&per_page=100&include=policy",
    "registration_type') -cne 'warp'",
    "tunnel_type') -cne 'masque'",
    "Compare-MishNonTargetRegistrations",
    "collect-device-diagnostic.ps1",
    "post_recovery_mesh_e2e",
    "physical_device_revoke = `$false",
    "global_warp_disconnect = `$false",
    "cloudflare_app_force_stop = `$false",
    "cloudflare_ui_used = `$false",
    "airplane_mode_mutated = `$false",
    "product_routes_or_iptables_mutated_by_lab = `$false"
)) {
    if (-not $source.Contains($required)) {
        throw "Cloudflare registration recovery probe lost required bounded/scope/cleanup evidence: $required"
    }
}

$armIndex = $source.IndexOf('$registrationMayBeRevoked = $true', [StringComparison]::Ordinal)
$revokeIndex = $source.IndexOf('Invoke-MishRegistrationMutation -Client $client -Action revoke', [StringComparison]::Ordinal)
if ($armIndex -lt 0 -or $revokeIndex -lt 0 -or $armIndex -ge $revokeIndex) {
    throw 'Cleanup must be armed before issuing targeted revoke because an HTTP timeout may occur after server-side mutation.'
}

$finallyIndex = $source.LastIndexOf('finally {', [StringComparison]::Ordinal)
$cleanupIndex = $source.LastIndexOf('Invoke-MishGuaranteedUnrevoke -Client $client', [StringComparison]::Ordinal)
if ($finallyIndex -lt 0 -or $cleanupIndex -lt $finallyIndex) {
    throw 'Exact-registration unrevoke must be guaranteed from the outer finally block.'
}

foreach ($forbidden in @(
    '/physical-devices/',
    '/devices/resilience/disconnect',
    "-Method 'DELETE'",
    'Invoke-RestMethod',
    "'shell','am','force-stop'",
    "'shell', 'am', 'force-stop'",
    "'airplane-mode','enable'",
    "'airplane-mode', 'enable'",
    "'airplane-mode','disable'",
    "'airplane-mode', 'disable'",
    "'shell','input'",
    "'shell', 'input'",
    "'shell','iptables'",
    "'shell', 'iptables'",
    "'shell','ip6tables'",
    "'shell', 'ip6tables'",
    'settings put',
    'svc data',
    'cmd phone data',
    'gradle ',
    'cargo build',
    'assembleDebug'
)) {
    if ($source.Contains($forbidden)) {
        throw "Cloudflare registration recovery probe must stay exact-registration CONTROL-only: $forbidden"
    }
}

if ($source -match '(?i)Bearer\s+[A-Za-z0-9._~-]{20,}') {
    throw 'Cloudflare registration recovery probe must never contain a literal bearer token.'
}

Write-Host 'CLOUDFLARE_REGISTRATION_RECOVERY_CONTRACT=PASS'
exit 0
