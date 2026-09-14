# Managed physical lab plan

This document defines the stable physical-lab execution architecture. Live stage/checkpoint state belongs to Issue #135. PRODUCT/runtime ownership remains outside the lab.

## Purpose

The Windows LAB is one controlled execution environment for real-device/provider evidence. It is **not** an Android release-build authority, a second product owner, a mutable status database, or a remote-control service.

The lab has two intentionally different consumption modes:

```text
DEVELOPMENT DIAGNOSTIC
exact-head hosted debug candidate
 -> protected-main physical consumer
 -> DEVICE-1 bounded engineering evidence

FORMAL ACCEPTANCE
exact immutable RC/release bytes
 -> protected/manual acceptance workflow
 -> formal E3/E4/release evidence
```

The detailed development candidate contract is `docs/architecture/DEVELOPMENT_PIPELINE.md`. Formal release identity remains `docs/architecture/RELEASE.md`.

## Ownership

```text
Git/GitHub
  source, review, workflow definitions, immutable run/artifact/evidence records

GitHub-hosted CI
  development exact-head debug/test candidate production

GitHub-hosted restricted release workflow
  formal Android release build/sign/package authority

GitHub Release exact tag + digest
  formal binary distribution identity

Windows lab host
  physical execution environment and verified-byte consumer

GitHub self-hosted runner
  bounded job transport into that host

repository-owned PowerShell/labctl
  stateless verification/execution adapters

Android / MISH runtime owners
  live product facts
```

Root/network commands executed by LAB are test/evidence authority only. ADB/root success does not substitute for PRODUCT runtime ownership of root/network behavior.

## Development DEVICE-1 diagnostic

When Issue #135 states that the next engineering decision requires a real-device fact, use the hosted candidate path rather than rebuilding on Windows:

```text
ready PR targeting fix/root-policy-reconciliation
 -> Integration Android Preflight full gate PASS
 -> exact artifact device-candidate-pr-<PR>-<40-hex source SHA>
 -> protected-main Device Candidate Physical workflow
 -> verify PR/head/run/artifact/digest identity
 -> self-hosted Windows LAB
 -> built-in Windows PowerShell
 -> exactly one authorized DEVICE-1
 -> verify API 30 + armeabi-v7a
 -> verify candidate.json + APK SHA-256
 -> create/reuse persistent LAB-only debug signing identity
 -> adb install -r com.mobileproxymish.app.debug
 -> collect only the bounded physical fact requested by #135
```

Normal development consumption must not run Gradle, Cargo, cargo-ndk, UniFFI generation, NDK compilation or APK assembly locally. Portable PowerShell is not a prerequisite for this candidate path.

If the exact hosted candidate, digest, device identity, signing prerequisite or required tool is missing/wrong, fail closed. Do not automatically substitute another commit or start a local build.

A local build remains available only as an explicit engineering fallback after a separate decision. It does not inherit the identity/evidence of the hosted candidate.

Development debug candidates are not PRODUCT release identity and cannot authorize release promotion.

## Formal RC/release acceptance

Formal acceptance continues to use the stronger immutable-release ceremony:

```text
PIN
 -> BUILD ONCE
 -> HASH
 -> SIGN
 -> ATTEST
 -> TEST EXACT BYTES
 -> PROMOTE EXACT BYTES
```

A formal physical workflow resolves an exact RC/release tag and digest, downloads those exact bytes, verifies them, and tests them without rebuilding. Release-signing private material never belongs on the self-hosted LAB.

## LAB bootstrap/toolchain

`lab/windows/toolchain.json` is the pinned bootstrap manifest for the broader managed LAB. For the fixed appliance profile it mirrors:

```text
Android min SDK = 30
PRODUCT ABI = armeabi-v7a
Rust Android target = armv7-linux-androideabi
NDK = 29.0.14206865
```

The normal DEVICE-1 hosted-candidate consumer requires only the bounded runtime prerequisites it actually uses (including ADB/sign/install tooling); it must not require the full local Android build toolchain merely because legacy/bootstrap workflows can provide it.

## Fixed DEVICE-1 profile

Current supported physical appliance:

```text
Samsung SM-A022G
Android 11 / API 30
armeabi-v7a / 32-bit userspace
Magisk-rooted
```

DEVICE-1 observations are physical evidence, not a second configuration owner. Raw identifiers, credentials, public IPs and unrelated logs must not be persisted in durable evidence.

## Cellular/root physical boundary

Cellular Egress remains the sole semantic owner of cellular admission, generation/currentness and availability. Root routing is a narrow infrastructure adapter.

Physical work must preserve:

- no global replacement of Android default routing;
- no Wi-Fi/default/WARP public-egress fallback;
- no second Android VPN/TUN;
- stale or ambiguous authority remains fail closed;
- temporary LAB mutations are exactly scoped and removed/verified;
- ADB root cannot substitute for explicit PRODUCT runtime root authority.

## Provider/release trust boundaries

Provider credentials, release-signing secrets and protected mutations must never be exposed to an untrusted PR head or stored on the physical runner unless an explicitly accepted contract requires that exact secret there.

Terraform/provider state is deployment machinery, not runtime truth. The lab remains stateless across runs except for explicitly accepted host prerequisites and the persistent LAB-only debug signing identity needed for repeatable `adb install -r` of the isolated debug package.

## What the LAB must not become

The LAB must not become:

- an always-on daemon or HTTP/RPC command service;
- a scheduler or generic Issue-command router;
- a device registry;
- a mutable readiness/status database;
- a second PRODUCT lifecycle/cellular/readiness owner;
- a release-signing authority;
- a second artifact registry;
- a mechanism that selects `latest` instead of exact identities.

## Evidence law

```text
E1 < E2 < E3 < E4
```

Development physical diagnostics may inform engineering decisions, but weaker/debug evidence must never be promoted into stronger formal acceptance claims.
