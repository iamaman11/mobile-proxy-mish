# Managed physical lab plan

This document defines the stable physical-execution boundary. Protected `main` is the latest accepted PRODUCT + CONTROL source. Live stage status belongs to Issue #135.

## Purpose

The Windows/DEVICE-1 lab is a controlled evidence executor, not a second PRODUCT control plane or build authority.

There are two distinct physical paths:

```text
1. development exact-head Device Cycle
2. formal immutable RC/release acceptance
```

They share trust/evidence discipline but not artifact identity or promotion authority.

## Development Device Cycle

Use this path when the active roadmap stage needs a physical fact before merging a candidate to `main`.

Canonical shape:

```text
open ready PR to main, exact PRODUCT head
 -> successful Integration Android Preflight
 -> immutable debug candidate artifact + digest
 -> explicit owner /mish-cycle command after analysis
 -> protected-main CONTROL_SHA resolves/verifies provenance
 -> isolated Windows self-hosted runner
 -> pinned lab tools / PowerShell runtime
 -> consume exact artifact; NO local Android build
 -> adb install -r when requested
 -> pull/read back installed base.apk
 -> verify installed digest + signing identity
 -> launch/read-only diagnostics/current-function probe as explicitly requested
 -> bounded sanitized evidence
 -> STOP_FOR_ANALYSIS
 -> merge accepted change to main
```

A successful hosted build, merge, artifact publication or workflow completion never starts DEVICE-1 automatically.

`Device Cycle` is the executable authority for currently supported modes and probes.

## Development artifact rules

The physical runner is a consumer by default.

Normal development physical work must not:

- run Gradle/Cargo/cargo-ndk/NDK compilation to manufacture a substitute APK;
- silently fall back to another candidate;
- clean-uninstall as the normal upgrade mechanism;
- rotate credentials merely to make a test pass;
- automatically repair PRODUCT/root/network state;
- start another cycle after a result.

When installing a candidate, exact installed bytes and signing identity are verified before launch/acceptance claims.

Development debug candidate evidence may close the exact stage-specific physical fact recorded by #135. It is not release identity.

## Formal RC/release physical acceptance

Formal release uses the immutable release path in `RELEASE.md`:

```text
accepted release source/version from main
 -> restricted hosted build/sign authority
 -> immutable manifest + digest
 -> exact RC/release asset
 -> protected/manual physical consumer
 -> test exact bytes
 -> promote exact already-tested bytes
```

No debug candidate is relabeled as RC/release. No release-signing secret belongs on the physical runner.

## Physical ownership

```text
GitHub protected main
  accepted PRODUCT + CONTROL source, review, workflow definitions

hosted candidate/release producers
  Android build/package authority for their respective artifact class

Windows lab host / self-hosted runner
  bounded physical execution environment and artifact consumer

ADB / supported Android interfaces
  device mechanism only

Cloudflare / carrier / Android OS / Magisk
  external live reality

MISH runtime owners
  live PRODUCT facts
```

Root commands executed by LAB are diagnostic/evidence authority only. ADB/root success never proves that PRODUCT runtime itself has the required root capability.

## Supported current PRODUCT topology

Android PRODUCT is one in-process native Rust proxy runtime.

```text
Cloudflare One Agent
  = only Android VPN/VpnService owner

MISH Android app
  = thin Kotlin platform/effect boundary
  = in-process Rust/UniFFI runtime
  = NO Android external proxy child
  = NO Android sing-box PRODUCT runtime

MISH public target egress
  = exact Cellular Egress owner
  = exact-network target DNS
  = root-policy-gated public sockets
  = NO Wi-Fi/default/WARP fallback
```

Historical `/data/adb/mobile-proxy-node`, Android sing-box binaries, watchdog/supervisor trees or similar residue are LAB hygiene only. They are not current PRODUCT state, startup prerequisites or migration inputs. If found and proven to conflict with current PRODUCT, cleanup is a separate bounded LAB-maintenance action with current package/data/UID explicitly protected.

## PRODUCT / CONTROL provenance

Accepted repository state is protected `main`. A development physical run may temporarily separate:

```text
PRODUCT_SHA = exact open PR head under test
CONTROL_SHA = exact protected-main Device Cycle/control implementation
HOSTED_RUN_ID when consuming a hosted artifact
DEVICE_CYCLE_RUN_ID
```

That split is provenance only, not a second accepted source. After acceptance/merge, PRODUCT and CONTROL are together on `main` again.

Do not infer architecture from stale device processes. Do not infer physical state from source.

## Local-agent diagnostics

A local agent may be used for a bounded missing physical fact that the current repository workflow does not expose, for example:

- process/socket ownership;
- `su` process/session count;
- `/proc` FD/thread/resource measurements;
- Magisk prompt observation;
- OS-level mechanism facts.

Default scope is read-only. Give one exact question, explicit allowed mutations if any, exact expected output, and stop after the evidence is returned. Relevant sanitized conclusions are written back to #135 or the natural-owner/evidence surface.

The local agent is not a second architecture planner or mutable product-state database.

## Device identity / prerequisites

The canonical DEVICE-1 profile and exact tool requirements are enforced by executable workflow/scripts. Do not copy mutable serials or secrets into documentation.

If required device/tool/artifact identity is missing or ambiguous, fail closed rather than substitute another device, build or mechanism.

## Security and evidence

The repository is public. Provider credentials, release-signing material, device secrets and private identifiers are never exposed to untrusted PR code or durable logs.

Evidence must be typed, bounded and redacted. Do not persist raw carrier/public IPs, credential material, unrelated logcat or unbounded process/environment data.

## Non-negotiable constraints

```text
ONE_FACT_ONE_OWNER
NO_SECOND_CONTROL_PLANE
NO_MUTABLE_LAB_STATUS_DB
NO_AUTOMATIC_DEVICE_MUTATION_FROM_BUILD_OR_MERGE
NO_LOCAL_ANDROID_REBUILD_IN_NORMAL_PHYSICAL_PATH
NO_SECOND_ANDROID_VPN
NO_ANDROID_SING_BOX_PRODUCT_COMPATIBILITY
NO_DEFAULT_WIFI_WARP_PUBLIC_EGRESS_FALLBACK
NO_EVIDENCE_ESCALATION
NO_SECRET_OR_DEVICE_IDENTIFIER_PERSISTENCE
```
