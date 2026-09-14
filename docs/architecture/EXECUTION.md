# Development execution and integration policy

This document defines stable execution policy. Live stage/checkpoint state belongs to Issue #135. The master PRODUCT/architecture plan belongs to Issue #134. The concrete CI/device-candidate contract is `docs/architecture/DEVELOPMENT_PIPELINE.md`.

## Core model

```text
accepted main
 -> current integration lineage from #135
 -> one bounded slice
 -> hosted evidence at the cheapest valid level
 -> integration update
 -> physical diagnostic only when the next fact genuinely requires it
 -> milestone merge to main only at an accepted boundary
```

A commit batch, a review slice, a physical diagnostic and a main merge are different units. Do not turn `main` into a progress ledger.

## Bounded slice

Default slice budget:

- one natural owner;
- at most one necessary platform/vendor/composition adapter;
- direct tests for those semantics.

A slice that crosses more than two semantic owners should be split unless the coupling is technically inseparable and documented.

The active working set is intentionally small:

```text
#135 current checkpoint
+ current slice PR/head
+ relevant #134 finding when needed
+ one natural-owner contract
+ one adapter boundary when required
+ direct tests/evidence
```

## Hosted CI

### Integration Android gate

For Android/Rust/build work targeting `fix/root-policy-reconciliation`:

```text
draft PR
 -> compileDebugKotlin
 -> lintDebug

ready PR
 -> fast gate
 -> unit tests
 -> assembleDebug
 -> assembleDebugAndroidTest
 -> native/package verification
 -> exact-head device-candidate artifact
```

The gate uses pinned toolchains and deterministic input-aware caches. Superseded runs are cancelled.

### Protected main gate

PRs to `main` must satisfy the branch-protection contexts `Rust Workspace` and `Android Compose Shell`.

The path classifier is fail-safe:

```text
explicit non-product allowlist only
 -> fast required-context PASS
 -> no PRODUCT rebuild

anything else / unknown / CI policy / PRODUCT input
 -> full Rust + Android validation
```

`workflow_dispatch` always performs the full gate.

After merge, `push -> main` performs the architecture smoke/invariants only; it does not repeat the expensive Rust/Android acceptance already established on the accepted PR head.

## Android product floor

The PRODUCT appliance target is Android 11 / API 30. `android/app/build.gradle.kts` owns one `androidMinSdk=30` value used by both Android `minSdk` and cargo-ndk `-P`.

The PRODUCT ABI is selected by `android/gradle.properties` and is currently `armeabi-v7a`. The LAB bootstrap mirror must use Rust target `armv7-linux-androideabi`.

Android 23/26 compatibility is not an accepted PRODUCT requirement. Do not add compatibility shims below API 30 without a new explicit product decision.

## Development physical diagnostic

Development physical work no longer requires a local Android rebuild or a merge to `main` solely to obtain test bytes.

When #135 states that the next engineering decision requires DEVICE-1 evidence:

```text
successful ready integration PR exact head
 -> exact-head hosted device candidate
 -> protected-main Device Candidate Physical consumer
 -> exact artifact/run/digest verification
 -> self-hosted Windows LAB
 -> built-in Windows PowerShell
 -> API 30 / armeabi-v7a DEVICE-1 check
 -> LAB-only stable debug signing
 -> adb install -r com.mobileproxymish.app.debug
 -> bounded sanitized physical evidence
```

The physical consumer is fail-closed and does not automatically build locally when the hosted candidate is unavailable or invalid.

A local build remains a separate explicit diagnostic fallback, not the normal path and not evidence substitution.

## Release/acceptance distinction

An exact-head PR debug candidate is allowed for development diagnostics and evidence needed to choose the next implementation step. It is not release identity and cannot be promoted.

Formal release acceptance continues to use exact immutable RC/release bytes under `docs/architecture/RELEASE.md` and the supply-chain law:

```text
PIN -> BUILD ONCE -> HASH -> SIGN -> ATTEST -> TEST EXACT BYTES -> PROMOTE EXACT BYTES
```

## Physical correction loop

```text
typed physical finding
 -> smallest bounded correction slice
 -> exact hosted validation
 -> new exact-head candidate when physical re-proof is required
 -> DEVICE-1 re-proof
```

Do not merge each attempted correction to `main` simply to get an APK. Do not guess a physical fact to avoid DEVICE-1 evidence.

## Stop conditions

Stop a slice when its required deterministic evidence passes and the next missing fact belongs to another owner or requires physical reality. Prefer NO CHANGE when measurement shows the suspected subsystem is not materially responsible.
