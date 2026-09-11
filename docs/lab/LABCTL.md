# LABCTL — stateless physical-lab execution adapter

`labctl` is the repository-owned stateless execution adapter for Windows physical workflows.

It is not a build system, daemon, scheduler, artifact registry, release selector, device registry, status database, or second control plane.

## Product artifact authority

For generic LAB release-consumer operations, `labctl` still consumes an exact verified tuple:

```text
tag
source commit
APK SHA-256
signing-certificate SHA-256
        ↓
labctl release resolve
        ↓
exact GitHub Release metadata + exact named assets
        ↓
labctl release verify
        ↓
PASS verification receipt
        ↓
android install may consume only those still-identical bytes
```

`latest` is never a machine input. Android product builds never run through `labctl`.

For E3, the operator no longer copies that tuple manually. The E3 workflow accepts only an exact immutable `rc_tag` plus the execution `mode`, resolves the remaining release/harness identity on a hosted runner, and passes the resulting machine-owned tuple to the existing fail-closed `labctl` verifiers.

The release signing-certificate fingerprint remains a reviewed stable trust anchor in the E3 consumer workflow. Per-RC source SHA, APK digest, ABI, harness run/artifact IDs, harness ZIP digest and test-APK digest are derived from the immutable tag/release/run rather than copied into the workflow for each candidate.

## Entry point

```powershell
C:\mish-lab\tools\powershell-7.6.6\pwsh.exe -NoLogo -NoProfile -NonInteractive -File .\lab\windows\labctl.ps1 <area> <action> ...
```

Current bounded surface:

```text
host inspect
release resolve
release verify
android inspect
android install
evidence collect
cloudflare prove
e3 verify
e3 ready
e3 execute
```

`android install` requires a PASS `mish.lab.release-verification/v1` receipt, re-checks the exact authorized tuple, and re-hashes the APK immediately before invoking ADB. Changing the APK after verification therefore fails before installation.

`evidence collect` is the single managed-LAB durable evidence projection. It emits `mish.lab.evidence/v1` through an explicit allowlist; arbitrary receipt fields, local paths, device identifiers, public-IP literals and secret-shaped data are not copied into durable evidence.

## E3 identity projection

The E3 workflow has one hosted resolver job before the self-hosted Windows job. Its human release input is exactly:

```text
rc_tag = vMAJOR.MINOR.PATCH-rc.N
```

The hosted resolver proves:

```text
exact tag syntax
 -> exact Git tag commit
 -> commit is in accepted main lineage
 -> published non-draft RC prerelease
 -> canonical release asset set
 -> GitHub APK SHA-256
 -> downloaded APK SHA-256
 -> mish.android-release/v1 manifest verification
 -> reviewed release-signing certificate trust anchor
 -> exactly one successful machine-owned Android Release Candidate run
 -> exactly one named E3 harness artifact for that run/tag/source
 -> non-expired artifact + canonical artifact digest
 -> harness manifest/product/test byte verification
 -> test APK SHA-256
```

Those facts become job outputs only for the current workflow run. They are not a new mutable release registry, status database, or second source of truth.

The Windows physical job then independently repeats the existing consumer checks using those machine-owned values:

```text
labctl release resolve
labctl release verify
e3 verify
```

So simplification removes manual identity transcription, not verification depth.

## E3 bounded commands

The E3 surface changes execution/supply mechanics only; #10 remains the semantic owner of the physical Cellular Egress positive/negative/recovery contract.

```text
e3 verify
  = verify exact harness run/artifact/ZIP/manifest/test-APK identity
    against an already verified exact product RC and machine-projected digests

e3 ready
  = create the pre-device domain readiness receipt after an explicit
    zero-ADB observation; this receipt is not durable evidence by itself

e3 execute
  = PHONE-ON adapter for the #10 continuous full-root-toggle lifecycle
    positive -> negative -> recovery using exact accepted bytes
```

These are bounded stateless commands. They do not create a daemon, scheduler, status database, second E3 workflow, second CURRENT pointer, release registry, or parallel semantic owner.

`NO_EVIDENCE_ESCALATION` is mandatory: hosted RC resolution, `e3 verify`, hosted contract CI, and `e3 ready` with `device_count=0` cannot claim E3 PASS.

## Physical execution gate

The E3 workflow may run hosted contract validation on pull requests and `push` to `main`, but its resolver and self-hosted physical job are admitted only by a manual `workflow_dispatch` on protected `main`:

```text
github.event_name == workflow_dispatch
AND github.ref == refs/heads/main
AND github.ref_protected == true
```

A PR or merge therefore validates the contract automatically but must never start the Windows physical LAB.

The accepted physical runner remains:

```text
[self-hosted, windows, x64, mobile-proxy-mish-lab]
```

PowerShell is invoked only through:

```text
C:\mish-lab\tools\powershell-7.6.6\pwsh.exe
```

from `shell: cmd` physical steps. Physical commands use repository-owned `labctl.ps1` through `pwsh -File`; inline arbitrary `pwsh -Command` is not part of the accepted boundary.

The physical runner receives no Android release signing secret and performs no Gradle/Cargo/Rust/NDK Android build.

## E3 operator protocol

From accepted protected `main`:

```text
Actions -> E3 Physical Cellular -> Run workflow
```

Inputs:

```text
rc_tag = exact immutable RC tag
mode   = pre-device-dry | full-root-toggle
```

The operator does **not** enter or copy:

```text
source commit
APK SHA-256
signing certificate per RC
harness run ID
harness artifact ID
harness ZIP SHA-256
test APK SHA-256
```

Those are resolved and verified from the exact immutable RC identity.

`mode=pre-device-dry` requires zero ADB devices, installs nothing, and may only produce:

```text
PHONE-ON READY
E3_PASS=NO
NO_EVIDENCE_ESCALATION=PASS
```

`mode=full-root-toggle` requires the physical phone and executes the one-process continuous B2 lifecycle accepted in #65:

```text
request direct CELLULAR + INTERNET + NOT_VPN
 -> positive admitted + exact-network DNS/socket proof
 -> svc data disable
 -> direct cellular lost / owner NOT_ADMITTED / old lease revoked
 -> svc data enable
 -> same request reacquires direct cellular
 -> fresh owner authority / fresh lease
 -> positive exact-network DNS/socket proof again
```

Wi-Fi is not a correctness prerequisite and cannot satisfy Cellular Egress. Cloudflare/VPN-derived networks cannot satisfy the `NOT_VPN` owner policy.

## Trust and privacy rules

The E3 simplification preserves all existing trust boundaries:

```text
NO untrusted PR execution on self-hosted runner
NO arbitrary-ref physical execution
NO release signing key on Windows LAB
NO Android rebuild on Windows LAB
NO latest/ambiguous RC selection
NO human-copied per-RC digest/artifact tuple
NO evidence escalation from hosted/pre-device proof
NO carrier public-IP persistence
NO device/SIM/network identifiers in durable public evidence
```

A missing, ambiguous, expired, mismatched, or non-canonical release/harness identity fails closed before physical execution.
