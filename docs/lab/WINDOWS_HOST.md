# LAB-1 Windows host bootstrap

Issue #25 owns this stage. This document is an operator procedure, not a second current-stage pointer.

## Scope

LAB-1 creates one Windows x64 physical execution fixture:

```text
accepted protected main
 -> versioned Windows bootstrap
 -> repository-scoped self-hosted Windows runner
 -> manual LAB Host Preflight workflow
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
- an elevated native Windows PowerShell process;
- Microsoft App Installer / `winget` for the remaining WinGet-owned host prerequisites;
- outbound HTTPS needed to fetch pinned distributions.

The bootstrap materializes the LAB-1 Git, JDK, PowerShell, Gradle, Android SDK/NDK, Rust, cargo-ndk and ADB prerequisites declared by `toolchain.json`.

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

## WSL boundary

WSL may be used only as an **out-of-band secrets-vault client**. It is not a LAB-1 execution environment.

Allowed WSL responsibility:

```text
vault lookup -> emit one short-lived runner registration token to the native Windows bootstrap token-provider call
```

WSL must not run or own:

- the LAB-1 bootstrap itself;
- GitHub Actions runner execution or service state;
- Android/Rust build steps;
- ADB checks;
- host-preflight;
- LAB-1 evidence generation.

The native Windows bootstrap may invoke `wsl.exe` as a token-provider executable solely to retrieve the short-lived registration token. That does not make WSL part of the LAB-1 execution/evidence path.

## Versioned bootstrap

`lab/windows/toolchain.json` is the LAB-1 host prerequisite manifest. `lab/windows/bootstrap-windows.ps1` installs/validates the host against it and registers or validates the repository runner.

For an accepted commit `<SHA>`, run the script and manifest from the same immutable commit:

```powershell
$sha = '<SHA>'
$script = "$env:TEMP\mish-lab-bootstrap.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/iamaman11/mobile-proxy-mish/$sha/lab/windows/bootstrap-windows.ps1" -OutFile $script
```

### WinGet-owned prerequisites

Git and Temurin JDK use capability-based WinGet materialization. Installed capability is the authoritative postcondition; a raw WinGet process exit code alone does not define success.

```text
capability already satisfies toolchain.json
 -> skip winget

capability missing
 -> invoke pinned package id through winget
 -> refresh Windows PATH/state
 -> verify the real capability
    -> satisfied: continue
    -> not satisfied: fail closed with decimal + hexadecimal exit code
```

A broken WinGet source configuration is not treated as success when the required postcondition remains absent.

### LAB-owned portable PowerShell

PowerShell is deliberately **not** owned by WinGet/MSIX for LAB-1. A per-user MSIX can be visible to the interactive bootstrap user but invisible to the `NETWORK SERVICE` runner, so it is not a valid LAB service capability.

`toolchain.json` therefore pins an official x64 portable PowerShell ZIP with exact version, release URL and SHA-256. Bootstrap expands it under:

```text
C:\mish-lab\tools\powershell-<version>\pwsh.exe
```

and:

- validates the exact executable version;
- adds that directory to machine PATH;
- grants the existing LAB tools ACL to `NETWORK SERVICE`;
- leaves unrelated user-scoped PowerShell/MSIX installations untouched;
- restarts the configured runner service so future runner processes inherit current machine state.

The physical workflow does not depend on ambient service PATH to start acceptance. It begins with built-in Windows PowerShell, reads `toolchain.json`, and launches the exact LAB-owned `pwsh.exe` by absolute path. The host-preflight then requires that `pwsh` resolves back to the same LAB-owned executable and that its version equals the exact manifest pin.

This gives one clear service capability owner:

```text
lab/windows/toolchain.json
 -> pinned portable PowerShell artifact
 -> C:\mish-lab\tools\powershell-<version>\pwsh.exe
 -> NETWORK SERVICE physical execution
```

### Bounded bootstrap retry and existing runner reuse

Bootstrap is expected to survive bounded retries after partial host materialization.

If `.runner` and `.service` are both absent, bootstrap performs normal repository runner registration and retrieves one short-lived registration token.

If `.runner` and `.service` are both present, bootstrap:

1. reads the existing service marker;
2. verifies the Windows service exists;
3. verifies service identity is `NT AUTHORITY\NETWORK SERVICE`;
4. preserves the existing repository runner registration;
5. skips token retrieval and registration;
6. refreshes the host/toolchain as needed;
7. restarts the service so it inherits the accepted machine environment.

If exactly one of `.runner` / `.service` exists, or the referenced service/identity disagrees, bootstrap fails closed. It does not silently repair, replace, or register a second runner.

This means a host-toolchain repair after successful registration does not require another registration token and does not create a second runner.

### Hosted static proofs

`LAB Host Static` validates the bootstrap and physical-workflow contracts on GitHub-hosted Windows. Among other checks it verifies:

- PowerShell manifest version/asset/URL/SHA shape;
- the exact pinned PowerShell asset and digest against upstream GitHub release metadata;
- Android platform coordinate against live Google repository metadata;
- PowerShell syntax;
- WinGet postcondition/idempotency self-test;
- portable PowerShell exact-version self-test;
- existing-runner reuse/token-skip contract;
- physical workflow independence from `shell: pwsh` / service PATH;
- physical trust boundary and provider-secret exclusions.

Hosted static success proves repository-side contract only. Physical LAB-1 remains incomplete until the accepted-main physical preflight passes.

### Autonomous token provider

Automation is the preferred registration path when an approved vault is available. Bootstrap accepts:

```text
-RunnerTokenProviderExecutable
-RunnerTokenProviderArgumentsJson
```

`RunnerTokenProviderExecutable` must be an absolute native Windows executable path. `RunnerTokenProviderArgumentsJson` is a JSON array of non-secret arguments. The provider is invoked only when a new runner registration is actually required.

The provider contract is strict:

- stdout contains exactly one registration token and nothing else;
- the token contains no whitespace;
- provider stderr is suppressed and is never included in an error message;
- provider nonzero exit fails closed;
- the captured token is converted to `SecureString` immediately and is not written to disk;
- provider arguments contain only vault location/reference information, never the secret value.

A WSL-only vault is supported by using native Windows `wsl.exe` as `RunnerTokenProviderExecutable` and passing only the vault lookup command/reference in the JSON argument array.

If an accepted runner is already configured, the provider is not invoked at all.

### Interactive fallback

If a new runner registration is required and no autonomous provider is supplied, bootstrap retains `Read-Host -AsSecureString` as a human fallback. This fallback is not the expected path for an autonomous lab agent with approved vault access.

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
- exact LAB-owned portable PowerShell identity/version;
- Git/JDK/Gradle/Rust/cargo-ndk/ADB and Android SDK/NDK prerequisites;
- no ADB device in any state during LAB-1;
- Android arm64 Rust cross-build without a phone;
- Android debug APK assembly without a phone.

It writes `mish.lab.evidence/v1` JSON and uploads it as `lab-host-preflight-evidence`. The artifact contains no runner token, provider credential, device identifier, or public IP.

LAB-1 is accepted only after a green physical `LAB Host Preflight` run exists on the current accepted protected `main`.
