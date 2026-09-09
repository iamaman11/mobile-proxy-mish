# LAB-1 Windows host bootstrap

Issue #25 owns this stage. This document is an operator procedure, not a second current-stage pointer.

## Scope

LAB-1 creates one Windows x64 physical execution fixture:

```text
accepted protected main
 -> manual LAB Host Preflight workflow
 -> repository-scoped self-hosted Windows runner
 -> versioned host-preflight script
 -> typed/redacted GitHub evidence
```

It does **not** enroll a phone, configure Cloudflare One Client, implement `labctl`, mutate Cloudflare/Terraform state, or execute E3.

## Ownership

```text
Git / repository files
  bootstrap procedure, desired host prerequisites, workflow definitions

GitHub repository runner
  runner registration and online/offline transport state

Windows
  installed host/toolchain reality

GitHub Actions run + artifact
  immutable LAB-1 evidence for one exact accepted-main execution
```

No mutable readiness database or local status registry is introduced.

## Host layout

The bootstrap owns only these machine-level locations:

```text
C:\mish-lab\runner\   # GitHub Actions runner + its _work checkout
C:\mish-lab\tools\    # pinned machine-level toolchains/caches
```

A human clone, if one exists, is not evidence identity and is not used by the physical workflow.

## Bootstrap entry prerequisites

Before the versioned bootstrap runs, the machine must provide only:

- 64-bit Windows;
- an elevated Windows PowerShell console;
- Microsoft App Installer / `winget`;
- outbound HTTPS needed to fetch the pinned GitHub runner and build-tool distributions.

The bootstrap then installs or materializes the LAB-1 Git, PowerShell, JDK, Gradle, Android SDK/NDK, Rust, cargo-ndk and ADB prerequisites declared by `toolchain.json`.

No browser/client package is added merely because a later stage may need one. The current LAB-1 host-only preflight has no concrete browser/client consumer; any such prerequisite remains with the first later stage that actually requires it.

## Security boundary

The runner is repository-scoped and carries the custom label:

```text
mobile-proxy-mish-lab
```

The accepted service identity is the Windows built-in `NT AUTHORITY\NETWORK SERVICE`. The GitHub runner installer grants that identity access to its runner/work directories. The bootstrap grants only the additional tool-directory permissions needed by the fixture.

The physical runner must not receive or store:

- Cloudflare Terraform API tokens;
- R2 Terraform-state credentials;
- provider apply credentials;
- broad GitHub PATs;
- production credentials.

The physical workflow has only `contents: read`, is `workflow_dispatch` only, and its job is gated before runner scheduling to `refs/heads/main` with `github.ref_protected == true`. Pull requests and normal push CI remain GitHub-hosted.

## Versioned bootstrap

`lab/windows/toolchain.json` is the LAB-1 host prerequisite manifest. `lab/windows/bootstrap-windows.ps1` installs/validates the host against it and registers the repository runner.

Bootstrap intentionally requires one short-lived GitHub runner registration token. It does not request a PAT and it never requests Cloudflare/R2/provider credentials.

For an accepted commit `<SHA>`, run the script itself and its manifest from that same immutable commit:

```powershell
$sha = '<SHA>'
$script = "$env:TEMP\mish-lab-bootstrap.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/iamaman11/mobile-proxy-mish/$sha/lab/windows/bootstrap-windows.ps1" -OutFile $script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -RepositoryCommit $sha
```

Run this once from an **elevated Windows PowerShell** console. The script installs the pinned host toolchain, asks for Android SDK license acceptance where required, then prompts for the short-lived repository runner registration token.

Do not paste a PAT, Cloudflare token, R2 key, or any other long-lived secret into that prompt.

## Host-only acceptance workflow

After the runner is registered and online, dispatch:

```text
LAB Host Preflight
```

from protected `main`.

The preflight checks:

- exact repository/ref/commit identity;
- Windows x64 and dedicated runner work-root identity;
- `NETWORK SERVICE` execution identity;
- Git/PowerShell/JDK/Gradle/Rust/cargo-ndk/ADB and Android SDK/NDK prerequisites;
- **no ADB device in any state** during LAB-1;
- Android arm64 Rust cross-build without a phone;
- Android debug APK assembly without a phone.

It writes `mish.lab.evidence/v1` JSON and uploads it as `lab-host-preflight-evidence`. The artifact contains no runner token, provider credential, device identifier, or public IP.

A green hosted static workflow proves only repository syntax/trust-boundary checks. LAB-1 is not accepted until a green physical `LAB Host Preflight` run exists on accepted `main`.
