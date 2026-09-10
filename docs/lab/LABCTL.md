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
```

`android install` requires a PASS `mish.lab.release-verification/v1` receipt, re-checks the exact authorized tuple, and re-hashes the APK immediately before invoking ADB. Changing the APK after verification therefore fails before installation.

`evidence collect` emits the existing `mish.lab.evidence/v1` schema through an explicit allowlist projection. Arbitrary receipt fields and local paths are not copied into durable evidence.

## LAB-2 boundary

Phone remains absent during LAB-2. `android install` is implemented as a fail-closed primitive for later PHONE-ON stages but is not executed against a real device in LAB-2.

The accepted REL-1 candidate used for initial consumer integration is:

```text
tag = v0.1.0-rc.1
source = 4542c1e2a16f3ac93f52ecb2464c2cfc0cafb3c0
APK SHA-256 = 26d7faa5e5f4f788c9c15fe53aaeac24ebd3a7241881e570887eec102304334e
signing certificate SHA-256 = 1958d474069ce0f8b8e5390c9c4ebecd6e306fb4e0f0f6e12d35c9b91cc67803
```

Hosted Windows CI resolves and verifies that exact published RC without installing Android build tooling. Physical-runner acceptance, when performed, must use protected `main`, the accepted LAB-owned PowerShell runtime and the phone-absent gate.
