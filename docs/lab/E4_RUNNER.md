# E4 stateless acceptance runner

> **Historical identity note (superseded):** Any RC tag/GitHub Release identity described below is not an active project pipeline. The Android RC workflows and release-lineage helpers were removed. Current Android build/physical acceptance uses the exact Integration Android Preflight device-candidate artifact and canonical Device Cycle. If this E3/E4 capability is reactivated, its identity boundary must be migrated to that exact candidate lineage; it must not recreate an RC/prerelease authority.


This document defines the repository-owned execution boundary for E4. It operationalizes the scenario contract in `docs/testing/E4_FULL_STACK.md` without turning LAB code into a second PRODUCT owner, release registry, provider control plane, or build system.

## Current scope

The repository provides bounded acceptance commands:

```text
labctl e3 accept
labctl e4 plan
labctl e4 finalize
```

They are acceptance coordination primitives. They do not build Android, mutate Cloudflare desired state, configure Magisk policy, own runtime readiness, or create a daemon/scheduler/status database.

No E3/E4 physical acceptance has been executed merely because these commands or their hosted contract tests exist.

## E3 acceptance handoff

Physical `e3 execute` remains the owner of the phone positive -> cellular loss -> fresh recovery ceremony. After that exact command returns `e3_pass=true`, the trusted Windows/protected-main workflow projects the result through:

```text
labctl e3 accept
```

The command revalidates the still-identical PRODUCT APK, the same-source/same-signing E3 harness and the exact physical execution result, then emits:

```text
mish.lab.e3-acceptance/v1
result = PASS
e3_pass = true
scenario = full-root-toggle
```

The receipt contains only bounded identity/evidence facts: execution-adapter Git SHA/run, exact RC tag/source/ABI/APK SHA-256/signing certificate, exact harness run/artifact/digests and instrumentation identity. It contains no device serial, SIM identity, public carrier IP, local path or raw device output.

A PHONE-ON readiness receipt is not E3 acceptance and cannot satisfy this handoff.

## Phase 1 — plan

`e4 plan` consumes:

```text
PASS mish.lab.release-verification/v1 receipt
PASS mish.lab.e3-acceptance/v1 receipt for the exact same RC bytes
exact still-identical PRODUCT APK bytes
pinned lab/windows/external-client-fixture.json
```

It re-hashes the PRODUCT APK, the E3 acceptance receipt and fixture, validates that E3 accepted the exact same tag/source/ABI/APK SHA-256/signing identity, validates the M1 TCP-only proxy surface, and emits:

```text
mish.lab.e4-session/v1
result = READY
e4_pass = false
no_evidence_escalation = true
```

The E4 session stores the SHA-256 of the exact E3 acceptance receipt. `e4 finalize` re-hashes that receipt again. Therefore a different RC, a readiness-only proof, a changed E3 receipt, or a changed PRODUCT APK fails closed before E4 acceptance.

The session contains the canonical mandatory E4 scenario matrix. `plan` cannot emit E4 PASS.

Example:

```powershell
.\lab\windows\labctl.ps1 e4 plan `
  -VerificationReceipt C:\bounded\release-verification.json `
  -E3AcceptancePath C:\bounded\e3-acceptance.json `
  -ReceiptPath C:\bounded\e4-session.json
```

`ExternalFixturePath` may be supplied explicitly, but the repository-pinned fixture is the default.

## Mandatory scenario matrix

Every final E4 ceremony contains exactly the following mandatory scenarios:

```text
windows_route_ownership
android_vpn_ownership
mesh_reachability
proxy_1080_mixed_auth
proxy_1081_socks5_auth
proxy_3128_http_connect_auth
proxy_wrong_missing_auth_rejected
cellular_positive
cellular_loss_fail_closed
cellular_recovery
ipv6_fail_closed
background_idle_5m
background_post_idle_10_session_load
background_foreground
normal_stop_cleanup
force_stop_explicit_relaunch
owned_child_recovery
root_authority_loss_recovery
one_agent_fresh_epoch_reconnect
one_client_recovery
selected_app_fail_closed
quic_webrtc_no_direct_udp
camoufox_real_client
kameleo_chroma_real_client
kameleo_junglefox_real_client
```

There are no optional scenarios in the M1 final matrix. If a required external executable/runtime is unavailable, that scenario is `BLOCKED`; the whole ceremony is `BLOCKED`, never PASS.

The known Camoufox/Playwright SOCKS5 fixture compatibility finding does not authorize weakening PRODUCT SOCKS5 authentication or protocol behavior. Product SOCKS5 correctness remains independently covered by the direct proxy scenarios.

## Phase 2 — physical observations

A bounded physical executor produces one `mish.lab.e4-observations/v1` document bound to the exact SHA-256 of the prepared E4 session. Because the session includes the exact E3 acceptance digest, the observation set is transitively tied to the same E3-accepted immutable RC. The observation document is ephemeral input, not durable public evidence.

Each canonical scenario appears exactly once with one status:

```text
PASS
FAIL
BLOCKED
```

`FAIL` and `BLOCKED` require a bounded uppercase `reason_code`. Free-form diagnostic text, credentials, addresses, public IPs, device identifiers, SIM identifiers, paths and vendor secret state are not part of the durable evidence contract.

Several scenarios have measurable facts that cannot be replaced by a PASS label:

```text
background_idle_5m
  observed_seconds >= 300

background_post_idle_10_session_load
  attempted_sessions >= 10
  successful_sessions >= 10

cellular_loss_fail_closed
  fallback_observed = false

ipv6_fail_closed
  fallback_observed = false

selected_app_fail_closed
  direct_fallback_observed = false

quic_webrtc_no_direct_udp
  direct_udp_observed = false

normal_stop_cleanup
  generation_artifacts_removed = true

force_stop_explicit_relaunch
  automatic_relaunch_observed = false
  explicit_relaunch_recovered = true

owned_child_recovery
  fresh_generation = true

root_authority_loss_recovery
  gate_closed_during_loss = true
  fresh_reauthorization = true

one_agent_fresh_epoch_reconnect
  fresh_epoch = true

one_client_recovery
  recovered = true

proxy_wrong_missing_auth_rejected
  wrong_credentials_rejected = true
  missing_credentials_rejected = true
```

Force Stop is deliberately preserved as the Android platform/user override. E4 therefore rejects any claim that PRODUCT automatically bypassed Force Stop; it requires recovery only after an explicit relaunch.

## Phase 3 — finalize

`e4 finalize` is the only command that can produce E4 acceptance evidence. It requires the accepted Windows x64 boundary on protected `main`, re-hashes the session-bound PRODUCT APK, E3 acceptance receipt and fixture again, verifies the exact observation/session/release identity, rejects missing/duplicate/unknown scenarios, and enforces the measurable facts above.

Example:

```powershell
.\lab\windows\labctl.ps1 e4 finalize `
  -SessionReceipt C:\bounded\e4-session.json `
  -ObservationPath C:\bounded\e4-observations.json `
  -EvidencePath C:\bounded\e4-evidence.json
```

Outcomes are machine-distinct:

```text
PASS    -> exit 0, e4_pass=true
FAIL    -> exit 2, sanitized FAIL evidence, e4_pass=false
BLOCKED -> exit 3, sanitized BLOCKED evidence, e4_pass=false
```

This prevents an unavailable Kameleo/Junglefox/Camoufox runtime or another external prerequisite from being silently converted into CI success/acceptance.

## Durable evidence allowlist

`mish.lab.e4-evidence/v1` copies only bounded facts:

```text
execution-adapter Git ref/SHA/run ID
exact RC tag/source/ABI/APK SHA-256/signing-certificate SHA-256
pinned external-fixture SHA-256 + reviewed version labels
canonical scenario ID
PASS/FAIL/BLOCKED
bounded reason_code for non-PASS scenarios
selected non-sensitive acceptance measurements/booleans
completion timestamp
```

The exact E3 acceptance receipt remains session authority and is revalidated before finalization; the E4 observation/session digest chain prevents substituting another E3 result underneath an already prepared ceremony.

E4 durable evidence intentionally does not copy arbitrary observation fields. Password/token-shaped data, public carrier IPs, DNS addresses, device/SIM identifiers, local filesystem paths and raw vendor diagnostics must remain absent from durable public evidence.

## Hosted contract boundary

`.github/workflows/e4-contract.yml` runs only deterministic hosted Windows contract tests on pull requests and pushes to `main`. It has no self-hosted runner, no manual physical trigger, and no path that can claim physical E3 or E4 acceptance.

The hosted contract proves fail-closed behavior including:

```text
E3 acceptance projection rejects wrong execution identity and changed APK bytes
E4 plan rejects an E3 receipt for different PRODUCT bytes
E4 plan cannot claim PASS
all 25 scenarios are mandatory
299 seconds cannot satisfy the 5-minute gate
9/10 post-idle sessions cannot satisfy load acceptance
wrong session identity fails
changed APK bytes fail
changed E3 acceptance receipt fails
untrusted refs fail finalization
required external client absence becomes BLOCKED/exit 3
mandatory scenario failure becomes FAIL/exit 2
durable evidence does not copy secret/privacy-shaped arbitrary input
```

## Physical execution remains later

The physical ceremony is intentionally not run as part of introducing this coordinator. After a fresh immutable PRODUCT RC exists, formal E3 must pass and emit `mish.lab.e3-acceptance/v1`; only then may `e4 plan` prepare the Windows/full-stack ceremony for those same bytes.

Until that later physical ceremony completes with PASS:

```text
PROXY_ON_PHONE_WORKING=NO
E4_PASS=NO
```

Cloudflare live preflight, RC creation, E3 execution and E4 physical execution are separate later gates and are not implied by merging this runner.
