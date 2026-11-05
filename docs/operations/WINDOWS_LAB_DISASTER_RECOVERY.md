# Windows LAB: recovery after reinstall or total disk loss

Tracking: [issue #467](https://github.com/iamaman11/mobile-proxy-mish/issues/467). Scope: Windows LAB and Android candidate signing identity, not Android PRODUCT runtime.

**The Windows computer is replaceable; the Android APK signing identity is not.** Windows tools and GitHub runner registration may be rebuilt from protected GitHub main and the pinned LAB manifest. In-place upgrades of an already installed Android APK need the *same* original signing private key. After an unexpected total disk loss, only an independently retained, authenticated encrypted vault created **before** the loss can recover that private key.

## Recovery inventory

| Item | Recovery rule |
|---|---|
| Rust/Kotlin/Android source and Windows LAB scripts | GitHub protected main exact SHA |
| Tools (Git, PowerShell, Java, SDK/NDK, Rust), runner binaries | lab/windows/bootstrap-windows.ps1 and lab/windows/toolchain.json |
| GitHub Actions runner credentials, .runner/.service, tokens | Disposable; re-register with new short-lived GitHub token. Never back up token/credential files |
| Windows Cloudflare One Client and WARP session | Disposable; install and re-enroll normally, never copy authentication tokens |
| C:\mish-lab\runner\.state\device-candidate\device-candidate.p12 | Unique Android LAB signing identity; **must have off-host encrypted recovery vault** |
| Candidate versions, receipts and signed APKs | Useful exact provenance/cache; retain independently if needed, verify exact identity. They do not replace lost private signing key |
| Android application private data, primary/temporary proxy credentials | Remain on the phone, not in Windows LAB. This workflow does not delete or migrate them |

## Rebuild diagnostic capabilities without the signing key

**Do this first when Windows LAB files vanished but DEVICE-1 still runs.** A missing PKCS#12
file must not prevent read-only Android and network diagnosis; it blocks only signing
and installing compatible new APKs. No key search, shadow-copy recovery, Android
uninstall or new key initialization is a prerequisite for this step.

On a new Windows installation, open elevated PowerShell. Get the **exact 40-hex
commit of protected main** from the repository in an authenticated browser session.
Do not use a floating branch or an unverified copied script as an administrative
installer. With that SHA in hand, obtain the bootstrap directly from that commit:

~~~powershell
$sha = Read-Host 'Exact protected main commit SHA (40 lowercase hex)'
if ($sha -cnotmatch '^[0-9a-f]{40}

Perform locally; never send your recovery code or private key into public GitHub comments, Actions logs or source.

1. Choose an external backup folder that synchronizes off this computer (external independent disk or encrypted cloud storage). A folder or partition on the **same physical disk** is not sufficient. Separately store the recovery code in a password manager available without this Windows computer.
2. From an interactive local PowerShell console on checked-out trusted source, generate a cryptographically random 256-bit code:

~~~powershell
& .\lab\windows\portable-signing-recovery.ps1 -Action GenerateCode
~~~

3. Save the displayed 64-character hexadecimal code **outside this computer and separate from the vault file**. Do not store it in PowerShell history, GitHub, a cloud-sync directory beside the vault, or an Actions secret that is not retrievable.
4. For the **first install on a genuinely fresh Android device**, initialize the signing key with *simultaneous* encrypted backup enrollment. The script asks for the recovery code with hidden input and independently reads back/decrypts the encrypted vault before admitting the local key.

~~~powershell
& .\lab\windows\portable-signing-recovery.ps1 -Action Initialize -FreshAndroidInstallAcknowledged -BackupPath 'X:\IndependentBackup\mish-signing.mishvault'
~~~

5. For a **pre-existing** original LAB signing key, do NOT initialize or replace it. Encrypt that existing key to a new external, non-overwriting recovery file instead:

~~~powershell
& .\lab\windows\portable-signing-recovery.ps1 -Action Protect -BackupPath 'X:\IndependentBackup\mish-signing.mishvault'
~~~

6. Verify that the encrypted file **actually exists on independent storage**. From a clean machine, copy it down and perform a successful Verify, followed by Restore into a disposable test state root, and compare SHA-256 against the original signing key. Keep an additional independent encrypted copy. Do not claim DISASTER_RECOVERABLE from merely creating a local file.

The vault uses AES-256-GCM with a random 256-bit key (the recovery code), fresh random nonce, authenticated identity digest, and exact-byte check. Windows DPAPI, BitLocker recovery state, runner service identity and the original disk are **not** required for decryption.

## Recovery on brand-new Windows or replacement disk

1. **Leave the Android app and its private storage untouched.** Do not uninstall, clear data, regenerate the identity, rotate credentials or change cellular routing.
2. Obtain exact accepted source from GitHub protected main. Run the normal trusted bootstrap from elevated PowerShell (lab/windows/bootstrap-windows.ps1 with -RepositoryCommit set to the exact main SHA), which materializes pinned toolchain and registers a new Windows LAB runner using a fresh short-lived GitHub registration token. When diagnosing without any signing backup, use the separate `-ToolsOnly` path above first. This does not require copying the old .runner, .service or runner OAuth credentials.
3. Fetch the encrypted vault **from independent storage** and its recovery code from the password manager, separately. On the checked-out trusted source run:

~~~powershell
& .\lab\windows\portable-signing-recovery.ps1 -Action Verify -BackupPath 'X:\IndependentBackup\mish-signing.mishvault'
& .\lab\windows\portable-signing-recovery.ps1 -Action Restore -BackupPath 'X:\IndependentBackup\mish-signing.mishvault'
~~~

Restore decrypts and authenticates before creating any local state. It atomically writes the exact original PKCS#12 bytes with restricted Windows ACLs, refuses a conflicting existing key and accepts only an identical already-restored key.

4. Reinstall and enroll the Windows Cloudflare One Client normally with authorized identity. Do not move old WARP tokens or any Windows VPN configuration whose ownership is separate.
5. **Before installing a future APK**, verify recovered signing certificate against the actual installed Android application (installed APK readback/apksigner or canonical exact signed receipt). Mismatch or missing evidence is a STOP, not permission to uninstall Android or invent a new identity.
6. Run the authorized read-only diagnostics on the physical Windows LAB. Require Android runtime RUNNING/READY, Cellular ADMITTED, root policy authorized, proxy healthy, active primary credentials, authenticated ADB loopback PASS and authenticated Windows Mesh E2E PASS. WARP Connected or green evidence collection alone is insufficient.

### When Windows has a stale Runner service but no files

A partial deletion of C:\mish-lab on an existing Windows installation may leave a stopped orphaned service still registered. Confirm the **exact** stopped actions.runner.iamaman11-mobile-proxy-mish.* service, its binary path under C:\mish-lab\runner, the absence of the runner executable and the absence of running runner processes. Only then may a separately approved Windows operator unregister that specific orphan service before clean bootstrap. Never touch a different service such as iamaman11-sing-box, and do not blindly delete Windows services. A truly fresh Windows installation has no orphaned registration.

## Important limits and acceptance

- A signing key already lost **before encrypted off-host escrow was created** is not derivable from source code, signed APK, Cloudflare, GitHub or a new keytool. Do not assert that the current loss can be magically repaired.
- The portable vault restores Windows LAB *signing identity*, **not** Android private data, Cloudflare/device tokens or an entire Windows user profile. Phone loss is a different product requirement.
- The vault must actually exist **off host**, and its code must be retrievable **independently**. Otherwise total disk recovery is not guaranteed.
- The existing install script is deliberately fail-closed: it refuses to create an unescrowed new signing key. First enrollment must create and verify the encrypted vault before installing Android.

Acceptance: hosted Windows test of byte-perfect protect/verify/restore, invalid code, tampering, conflicting destination, missing vault, duplicate use, unsafe path, and fresh initialization; **then** independently stored vault + recovery code restored on a fresh Windows host and identical signing certificate check + authenticated Windows Mesh E2E PASS. Never merge or claim complete end-to-end physical recovery from hosted tests alone.
) { throw 'Invalid protected-main SHA' }
$script = Join-Path $env:TEMP 'mish-bootstrap-windows.ps1'
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/iamaman11/mobile-proxy-mish/$sha/lab/windows/bootstrap-windows.ps1" -OutFile $script
& $script -RepositoryCommit $sha -ToolsOnly
~~~

This provisions the manifest-pinned Git/Java/PowerShell/Gradle/Android
SDK/ADB/NDK/Rust tools, but **does not register, delete or start a runner**, touch
the APK, or access the signing key. Network availability and Android SDK license
acceptance are required. The pinned LAB PowerShell may differ from the interactive
system PowerShell: use the manifest-pinned binary in Actions.

Confirm canonical ADB and the authorized phone from the administrator console:

~~~powershell
& 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe' version
& 'C:\mish-lab\tools\android-sdk\platform-tools\adb.exe' devices -l
~~~

The second command may start the local ADB server; it does not install or change
the Android app. Authorization and USB connection must be established on the
phone before treating device-specific results as valid.

To restore the **GitHub-operated** diagnostics, invoke the same exact trusted
bootstrap without `-ToolsOnly`; it will request a **new short-lived GitHub
self-hosted runner registration token** if the registration files are absent.
Neither the key nor pre-existing Android app data is required for runner
registration. After the runner reports Online, run one explicitly authorized
read-only `/mish-diag snapshot` through the canonical issue #163 workflow,
followed by relevant `control-snapshot`, `mesh-route`, `warp-state`, or
`installed-identity` checks when their prerequisites exist. An Online runner
alone is not Android/Mesh E2E PASS.

### Re-register after partial folder deletion

If and **only if** the old runner service is stopped, both registration markers
`C:\mish-lab\runner\.runner` and `.service` are missing, and the
service matches the exact MISH repository/name, NetworkService identity and
canonical binary path, the operator may explicitly request bounded removal of
that *one* orphaned service and re-registration:

~~~powershell
& $script -RepositoryCommit $sha -RepairOrphanedRunnerService
~~~

This is a **mutating administrator operation** requiring deliberate authorization;
do not use it as part of read-only diagnostics. It refuses ambiguous, active,
non-MISH or mismatching services, and never deletes `iamaman11-sing-box` or
another project's runner. A service still pending Windows deletion must be
resolved before a subsequent new registration. The old GitHub-side offline
runner record may need separate removal/replacement through GitHub's runner
administration; never export/copy old runner OAuth material.

After re-registration, run the existing Device Cycle diagnostics exactly as
defined in protected-main workflows. A successful **host recovery** does not
authorize an APK install. A later in-place update requires either the validated
original signing identity from independent escrow, or a separately approved
migration strategy if that identity is irretrievably lost.

## Initial setup on a truly fresh Android device

Perform locally; never send your recovery code or private key into public GitHub comments, Actions logs or source.

1. Choose an external backup folder that synchronizes off this computer (external independent disk or encrypted cloud storage). A folder or partition on the **same physical disk** is not sufficient. Separately store the recovery code in a password manager available without this Windows computer.
2. From an interactive local PowerShell console on checked-out trusted source, generate a cryptographically random 256-bit code:

~~~powershell
& .\lab\windows\portable-signing-recovery.ps1 -Action GenerateCode
~~~

3. Save the displayed 64-character hexadecimal code **outside this computer and separate from the vault file**. Do not store it in PowerShell history, GitHub, a cloud-sync directory beside the vault, or an Actions secret that is not retrievable.
4. For the **first install on a genuinely fresh Android device**, initialize the signing key with *simultaneous* encrypted backup enrollment. The script asks for the recovery code with hidden input and independently reads back/decrypts the encrypted vault before admitting the local key.

~~~powershell
& .\lab\windows\portable-signing-recovery.ps1 -Action Initialize -FreshAndroidInstallAcknowledged -BackupPath 'X:\IndependentBackup\mish-signing.mishvault'
~~~

5. For a **pre-existing** original LAB signing key, do NOT initialize or replace it. Encrypt that existing key to a new external, non-overwriting recovery file instead:

~~~powershell
& .\lab\windows\portable-signing-recovery.ps1 -Action Protect -BackupPath 'X:\IndependentBackup\mish-signing.mishvault'
~~~

6. Verify that the encrypted file **actually exists on independent storage**. From a clean machine, copy it down and perform a successful Verify, followed by Restore into a disposable test state root, and compare SHA-256 against the original signing key. Keep an additional independent encrypted copy. Do not claim DISASTER_RECOVERABLE from merely creating a local file.

The vault uses AES-256-GCM with a random 256-bit key (the recovery code), fresh random nonce, authenticated identity digest, and exact-byte check. Windows DPAPI, BitLocker recovery state, runner service identity and the original disk are **not** required for decryption.

## Recovery on brand-new Windows or replacement disk

1. **Leave the Android app and its private storage untouched.** Do not uninstall, clear data, regenerate the identity, rotate credentials or change cellular routing.
2. Obtain exact accepted source from GitHub protected main. Run the normal trusted bootstrap from elevated PowerShell (lab/windows/bootstrap-windows.ps1 with -RepositoryCommit set to the exact main SHA), which materializes pinned toolchain and registers a new Windows LAB runner using a fresh short-lived GitHub registration token. This does not require copying the old .runner, .service or runner OAuth credentials.
3. Fetch the encrypted vault **from independent storage** and its recovery code from the password manager, separately. On the checked-out trusted source run:

~~~powershell
& .\lab\windows\portable-signing-recovery.ps1 -Action Verify -BackupPath 'X:\IndependentBackup\mish-signing.mishvault'
& .\lab\windows\portable-signing-recovery.ps1 -Action Restore -BackupPath 'X:\IndependentBackup\mish-signing.mishvault'
~~~

Restore decrypts and authenticates before creating any local state. It atomically writes the exact original PKCS#12 bytes with restricted Windows ACLs, refuses a conflicting existing key and accepts only an identical already-restored key.

4. Reinstall and enroll the Windows Cloudflare One Client normally with authorized identity. Do not move old WARP tokens or any Windows VPN configuration whose ownership is separate.
5. **Before installing a future APK**, verify recovered signing certificate against the actual installed Android application (installed APK readback/apksigner or canonical exact signed receipt). Mismatch or missing evidence is a STOP, not permission to uninstall Android or invent a new identity.
6. Run the authorized read-only diagnostics on the physical Windows LAB. Require Android runtime RUNNING/READY, Cellular ADMITTED, root policy authorized, proxy healthy, active primary credentials, authenticated ADB loopback PASS and authenticated Windows Mesh E2E PASS. WARP Connected or green evidence collection alone is insufficient.

### When Windows has a stale Runner service but no files

A partial deletion of C:\mish-lab on an existing Windows installation may leave a stopped orphaned service still registered. Confirm the **exact** stopped actions.runner.iamaman11-mobile-proxy-mish.* service, its binary path under C:\mish-lab\runner, the absence of the runner executable and the absence of running runner processes. Only then may a separately approved Windows operator unregister that specific orphan service before clean bootstrap. Never touch a different service such as iamaman11-sing-box, and do not blindly delete Windows services. A truly fresh Windows installation has no orphaned registration.

## Important limits and acceptance

- A signing key already lost **before encrypted off-host escrow was created** is not derivable from source code, signed APK, Cloudflare, GitHub or a new keytool. Do not assert that the current loss can be magically repaired.
- The portable vault restores Windows LAB *signing identity*, **not** Android private data, Cloudflare/device tokens or an entire Windows user profile. Phone loss is a different product requirement.
- The vault must actually exist **off host**, and its code must be retrievable **independently**. Otherwise total disk recovery is not guaranteed.
- The existing install script is deliberately fail-closed: it refuses to create an unescrowed new signing key. First enrollment must create and verify the encrypted vault before installing Android.

Acceptance: hosted Windows test of byte-perfect protect/verify/restore, invalid code, tampering, conflicting destination, missing vault, duplicate use, unsafe path, and fresh initialization; **then** independently stored vault + recovery code restored on a fresh Windows host and identical signing certificate check + authenticated Windows Mesh E2E PASS. Never merge or claim complete end-to-end physical recovery from hosted tests alone.
