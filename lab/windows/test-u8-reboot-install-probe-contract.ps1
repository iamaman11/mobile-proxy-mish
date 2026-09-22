Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$probePath = Join-Path $PSScriptRoot 'diagnose-u8-reboot-install-durability.ps1'
$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($probePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -ne 0) {
    $errors | ForEach-Object { Write-Error $_.Message }
    throw 'U8 reboot/install durability probe must parse under PowerShell.'
}
if (@($tokens | Where-Object { $_.Text -ieq '$PID' }).Count -ne 0) {
    throw 'U8 reboot/install durability probe must not shadow the PowerShell automatic PID variable.'
}

$source = Get-Content -Raw -LiteralPath $probePath
$required = @(
    'mish.lab.u8-reboot-install-durability/v1',
    'snapshot_v2',
    "'shell', 'pidof'",
    'Do not touch the diagnostics provider until PRODUCT is independently observable',
    "'shell', 'content', 'call'",
    "'shell', 'dumpsys', 'package'",
    'userId=(?<uid>',
    'verify-installed-candidate.ps1',
    "@('install', '-r'",
    'adb_install_r_attempts = 1',
    "Invoke-MishAdbCapture -Arguments @('reboot')",
    'adb_reboot_attempts = 1',
    '/proc/sys/kernel/random/boot_id',
    'sys.boot_completed',
    'boot_id_changed = $false',
    'passive_process_start_observed = $false',
    'uid_stable = $false',
    'signing_certificate_stable = $false',
    'root_authorized_after = $false',
    'ready_after = $false',
    '[bool]$Snapshot.runtime.running',
    '[bool]$Snapshot.cellular.admitted',
    '[bool]$Snapshot.root.policy_authorized',
    "[string]$Snapshot.proxy.state -ceq 'RUNNING'",
    '[bool]$Snapshot.mesh.admitted',
    '[bool]$Snapshot.mesh.ingress_running',
    "[string]$Snapshot.readiness.state -ceq 'READY'",
    "[string]$Snapshot.readiness.probe_state -ceq 'SUCCEEDED'",
    'PRODUCT_REPLACEMENT_AUTOSTART_NOT_OBSERVED',
    'PRODUCT_REPLACEMENT_NOT_READY',
    'PRODUCT_REPLACEMENT_UID_CHANGED',
    'PRODUCT_REPLACEMENT_SIGNER_CHANGED',
    'PRODUCT_REPLACEMENT_ROOT_AUTHORITY_NOT_RESTORED',
    'PRODUCT_REBOOT_AUTOSTART_NOT_OBSERVED',
    'PRODUCT_REBOOT_NOT_READY',
    'PRODUCT_REBOOT_UID_CHANGED',
    'PRODUCT_REBOOT_SIGNER_CHANGED',
    'PRODUCT_REBOOT_ROOT_AUTHORITY_NOT_RESTORED',
    'U8_REBOOT_INSTALL_DURABILITY_PASS',
    'secrets_persisted_in_evidence = $false',
    'raw_public_ip_persisted = $false',
    'Invoke-MishRecoveryAfterFailure',
    'recovery_only',
    'start-device-app.ps1'
)
foreach ($needle in $required) {
    if (-not $source.Contains($needle)) {
        throw "U8 reboot/install durability probe lost required contract: $needle"
    }
}

$forbidden = @(
    "'shell', 'su'",
    "'shell', 'iptables'",
    "'shell', 'ip6tables'",
    'pm uninstall',
    'adb uninstall',
    "'uninstall'",
    'airplane-mode',
    "'cmd', 'phone', 'data'",
    'settings put',
    'svc data',
    'warp-cli',
    'sing-box',
    'gradle ',
    'cargo build',
    'assembleDebug',
    'ProxyUserName',
    'ProxyPassword',
    'before_ip',
    'after_ip',
    'retry-until',
    'retry_until',
    'generic updater'
)
foreach ($needle in $forbidden) {
    if ($source.Contains($needle)) {
        throw "U8 reboot/install durability probe contains forbidden duplicate PRODUCT/control path: $needle"
    }
}

if ([regex]::Matches($source, [regex]::Escape("@('install', '-r'" )).Count -ne 1) {
    throw 'U8 durability probe must contain exactly one deliberate replacement-install command.'
}
if ([regex]::Matches($source, [regex]::Escape("Invoke-MishAdbCapture -Arguments @('reboot')")).Count -ne 1) {
    throw 'U8 durability probe must contain exactly one physical reboot request.'
}

Write-Host 'U8_REBOOT_INSTALL_PROBE_CONTRACT=PASS'
exit 0
