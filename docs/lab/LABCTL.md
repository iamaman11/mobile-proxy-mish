# LABCTL — stateless physical-lab execution adapter

`labctl` is the repository-owned stateless execution adapter for Windows physical workflows.

It is not a build system, daemon, scheduler, artifact registry, release selector, device registry, status database, or second control plane.

## Product artifact authority

```text
exact authorized tuple
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

The signing certificate fingerprint in the authorized tuple is an identity fact already proven against the exact APK bytes by the restricted REL-1 release workflow. On the physical consumer, the exact APK SHA-256 binds the downloaded bytes to that accepted release proof; LAB-2 does not duplicate the Android signing implementation or require JDK/Android Build Tools merely to re-derive the same fact.

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

`evidence collect` is the single managed-LAB durable evidence projection. It emits `mish.lab.evidence/v1` through an explicit allowlist; arbitrary receipt fields, local paths, device identifiers, public-IP literals and secret-shaped data are not copied into durable evidence. For LAB-3B, the domain-specific E3 readiness receipt is an internal typed input only and is projected by this existing command into the accepted evidence envelope.

## E3 bounded commands

The E3 surface changes execution/supply mechanics only; #10 remains the semantic owner of the physical Cellular Egress positive/negative/recovery contract.

```text
e3 verify
  = verify the exact harness run/artifact/ZIP/manifest/test-APK identity
    against an already verified exact product RC

e3 ready
  = create the pre-device domain readiness receipt after an explicit
    zero-ADB observation; this receipt is not durable evidence by itself

e3 execute
  = later PHONE-ON adapter for the original #10 full-root-toggle
    positive -> negative -> recovery ceremony using exact accepted bytes
```

These are bounded stateless commands. They do not create a daemon, scheduler, status database, second E3 workflow, second CURRENT pointer, release selector, or parallel semantic owner.

`NO_EVIDENCE_ESCALATION` is mandatory: `e3 verify`, hosted contract CI, and `e3 ready` with `device_count=0` cannot claim E3 PASS. The LAB-3B durable evidence remains `mish.lab.evidence/v1` and records `PHONE-ON READY`, `E3_PASS=NO`, and `NO_EVIDENCE_ESCALATION=PASS`.

## Physical execution gate

The E3 workflow may run hosted validation on pull requests and on `push` to `main`, but its self-hosted physical job is authorized only by a separate manual `workflow_dispatch` on protected `main`:

```text
github.event_name == workflow_dispatch
AND github.ref == refs/heads/main
AND github.ref_protected == true
```

Therefore a merge/push may validate the contract automatically but must never start the Windows physical LAB. The accepted physical runner remains `[self-hosted, windows, x64, mobile-proxy-mish-lab]`, and PowerShell is invoked only through `C:\mish-lab\tools\powershell-7.6.6\pwsh.exe` from `shell: cmd` steps.

## LAB lifecycle boundary

Phone remains absent through LAB-3 pre-device acceptance. `android install` and `e3 execute` are fail-closed primitives for PHONE-ON stages but are not executed during the pre-device dry proof.

The LAB-3B accepted immutable candidate is:

```text
tag = v0.1.0-rc.3
source = d057f267ffac5cbeca40839778783d462a51b7a0
APK SHA-256 = 84d8a53857a20a5d55093604324770d00fdbd8a187a69c524e88920d00b323f0
signing certificate SHA-256 = 1958d474069ce0f8b8e5390c9c4ebecd6e306fb4e0f0f6e12d35c9b91cc67803
harness run = 34498778808
harness artifact = 10161372180
harness ZIP SHA-256 = 1c1758a5ce3672db76952627e4b1a61ac4e2e73744957f8c8b1f80b5efc01d36
test APK SHA-256 = 2d377cfce3f0827d6bc4efda313d6ebaeb6dac148303bb1eaff9a0b60c860c9c
```

Hosted Windows CI verifies the contract without executing self-hosted PR code. After merge and hosted post-merge acceptance, an operator may authorize exactly one protected-main `pre-device-dry` dispatch while ADB device count is zero. Only its resulting durable evidence may advance #28 to `PHONE-ON READY`.
