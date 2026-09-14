# Architecture decision index

This file is a navigation index, not a second source of truth. Live execution state belongs to GitHub Issues; stable contracts live in versioned repository files.

## Current authorities

- Issue #135 — current execution/checkpoint pointer: stage, active slice, integration head, current blocker and required physical fact.
- Issue #134 — master PRODUCT/architecture hardening plan and research findings. It does not become a second current-stage pointer.
- `AGENTS.md` — executor startup, bounded-slice, CI and physical-uncertainty policy.
- `docs/architecture/EXECUTION.md` — stable implementation/integration execution policy.
- `docs/architecture/DEVELOPMENT_PIPELINE.md` — canonical development CI, Android product-floor, hosted exact-head candidate and DEVICE-1 diagnostic contract.
- `docs/architecture/RELEASE.md` — formal immutable RC/release identity and promotion contract.
- `docs/architecture/ACCEPTANCE.md` — evidence-level and development-vs-formal acceptance boundaries.
- `docs/lab/PLAN.md` — physical LAB ownership/trust/execution architecture.

## PRODUCT ownership contracts

- `docs/architecture/SYSTEM.md` — canonical product path and system topology.
- `docs/architecture/OWNERSHIP.md` — natural-owner map.
- `docs/architecture/DEPENDENCIES.md` — dependency direction and minimal-layer invariant.
- `docs/architecture/CONTRACTS.md` — durable interface/contract navigation.
- `docs/architecture/CELLULAR_ROOT_POLICY.md` — root-policy mechanism and fail-closed constraints.

The project law remains:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Prefer the existing natural owner plus one narrow adapter. Do not add a second VPN/TUN, second Cellular Egress/Runtime Lifecycle/Readiness owner, generic root shell/control API, mutable status database, or Wi-Fi/default/WARP public-egress fallback.

## Android development delivery decision

The supported appliance target is Android 11 / API 30 with `armeabi-v7a` PRODUCT ABI.

Stable authority split:

```text
android/app/build.gradle.kts
  -> one androidMinSdk=30 authority for Android minSdk + cargo-ndk -P

android/gradle.properties
  -> mishTargetAbi=armeabi-v7a

lab/windows/toolchain.json
  -> mirror min_sdk=30 and rust.target=armv7-linux-androideabi

Integration Android Preflight
  -> hosted exact-head debug/test build and verification

Device Candidate Physical
  -> protected-main exact-artifact consumer on DEVICE-1
```

Android 23/26 compatibility is not a supported PRODUCT requirement unless a future explicit product decision reopens it.

## Development physical diagnostics vs formal release acceptance

A successful ready integration PR may produce a short-lived exact-head debug candidate. When Issue #135 requires a physical fact for the next engineering decision, the protected-main consumer may install those exact verified bytes on DEVICE-1 without a local rebuild.

That diagnostic path is not release identity and cannot be promoted.

Formal release acceptance remains the stronger immutable RC/release path:

```text
PIN -> BUILD ONCE -> HASH -> SIGN -> ATTEST -> TEST EXACT BYTES -> PROMOTE EXACT BYTES
```

No development artifact or weaker evidence may be relabeled as formal E3/release acceptance.

## Test/evidence navigation

- `docs/testing/E3_PHYSICAL_CELLULAR.md` — formal physical Cellular Egress acceptance protocol.
- `docs/testing/E4_FULL_STACK.md` — later Windows/Cloudflare/Mesh/Android/external-client full-stack contract.
- `.github/workflows/integration-android-preflight.yml` — hosted development Android fast-to-full gate and device-candidate producer.
- `.github/workflows/device-candidate-physical.yml` — protected-main development DEVICE-1 candidate consumer.
- `.github/workflows/e3-physical-cellular.yml` — formal self-hosted E3 workflow; it must match the currently accepted PRODUCT mechanism before it can claim E3 PASS.

## Non-authority rule

README text, chat handoffs, generated artifacts, CI summaries and this index are not mutable product-state authorities. Always begin from fresh GitHub facts and the current authority named above.
