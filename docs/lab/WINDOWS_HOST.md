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
- an elevated native Windows PowerShell process;
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

`lab/windows/toolchain.json` is the LAB-1 host prerequisite manifest. `lab/windows/bootstrap-windows.ps1` installs/validates the host against it and registers the repository runner.

Bootstrap requires one short-lived GitHub runner registration token. It does not request a PAT and it never requests Cloudflare/R2/provider credentials.

For an accepted commit `<SHA>`, run the script itself and its manifest from that same immutable commit:

```powershell
$sha = '<SHA>'
$script = "$env:TEMP\mish-lab-bootstrap.ps1"
Invoke-WebRequest "https://raw.githubusercontent.com/iamaman11/mobile-proxy-mish/$sha/lab/windows/bootstrap-windows.ps1" -OutFile $script
```

### Bootstrap rerun and package postconditions

LAB-1 bootstrap is expected to survive a bounded retry after a partial host-toolchain installation. For the WinGet-owned Git, PowerShell and Temurin JDK prerequisites, installed Windows capability is the authoritative postcondition; a raw WinGet process exit code is not sufficient by itself to decide installed state.

The bootstrap therefore follows this rule for each of those prerequisites:

```text
capability already satisfies toolchain.json
 -> skip winget entirely

capability missing
 -> invoke pinned package id through winget
 -> refresh native Windows PATH/state
 -> verify the real capability again
    -> satisfied: continue, even if installer transport returned nonzero
    -> not satisfied: fail closed and report decimal + hexadecimal exit code
```

A broken WinGet source configuration is **not** treated as success. It is tolerated only when no WinGet call is needed because the required capability already exists, or when the requested installation actually materialized the required capability despite the transport exit status. Otherwise bootstrap fails with the exact exit code and unsatisfied postcondition.

`LAB Host Static` executes the bootstrap's deterministic package-idempotency self-test on GitHub-hosted Windows. The self-test proves that an already-ready dependency does not invoke WinGet, a nonzero installer status is accepted only when its postcondition became true, and a nonzero status with a missing postcondition remains fail-closed.

### Autonomous token provider

Automation is the preferred path when an approved vault is already available. The bootstrap accepts:

```text
-RunnerTokenProviderExecutable
-RunnerTokenProviderArgumentsJson
```

`RunnerTokenProviderExecutable` must be an absolute native Windows executable path. `RunnerTokenProviderArgumentsJson` is a JSON array of non-secret arguments. The executable is invoked directly, without a shell, only when runner registration is about to occur.

The provider contract is strict:

- stdout must contain exactly one registration token and nothing else;
- the token must contain no whitespace;
- provider stderr is suppressed by bootstrap and is never included in an error message;
- provider nonzero exit fails closed;
- the captured token is converted to `SecureString` immediately and is not written to disk;
- provider arguments must contain only vault location/reference information, never the secret value itself.

A WSL-only vault is supported by using the native Windows `wsl.exe` binary as `RunnerTokenProviderExecutable` and passing only the vault lookup command/reference in the JSON argument array. The agent must use the vault's raw/quiet secret-read mode so stdout contains only the token.

Example shape; the vault command itself is environment-specific and must be resolved by the local agent from the approved vault tooling:

```powershell
$providerArgs = @(
  '--distribution', '<vault-wsl-distro>',
  '--exec', '<vault-cli>',
  '<raw-secret-read-argument>',
  '<vault-secret-reference>'
) | ConvertTo-Json -Compress

& $script `
  -RepositoryCommit $sha `
  -RunnerTokenProviderExecutable "$env:SystemRoot\System32\wsl.exe" `
  -RunnerTokenProviderArgumentsJson $providerArgs
```

The local agent must not stop merely because it lacks an interactive TTY. If the token already exists in the approved vault, it must use this provider contract and complete bootstrap autonomously.

Do not put the registration token in:

- CLI arguments;
- provider JSON;
- environment variables;
- repository files;
- temporary files;
- Windows/WSL shell history;
- logs or reports.

### Interactive fallback

If no autonomous provider is supplied, bootstrap retains `Read-Host -AsSecureString` as a human fallback. This fallback is not the expected path for an autonomous lab agent with approved vault access.

Run bootstrap from an **elevated native Windows PowerShell** process. WSL may participate only in the bounded vault-provider lookup described above.

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