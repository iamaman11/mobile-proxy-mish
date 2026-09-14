# Executor policy

GitHub is the durable source of truth. Chat handoffs, copied status text, CI summaries and generated artifacts are not substitutes for a fresh GitHub baseline.

## Required startup baseline

Before planning or mutating:

1. read fresh protected `main`;
2. read Issue #135 as the current execution/checkpoint pointer;
3. read Issue #134 only for the master PRODUCT/architecture plan and findings relevant to the active slice;
4. inspect `fix/root-policy-reconciliation` and the current slice PR/head named by #135;
5. read only the natural-owner contracts and implementation files required by that slice;
6. distinguish current facts from historical evidence.

One fresh baseline opens one bounded mutation window. Do not re-baseline after every write inside that same bounded window.

## Engineering rule

```text
concrete product/operator problem
 -> smallest safe change or smallest missing measurement
 -> measurable result
 -> preserved invariants
 -> stop condition
```

Prefer NO CHANGE when the accepted requirement is already met. Do not introduce a framework, daemon, generic shell API, second owner, or refactor merely because it is possible.

## Working lineage and slice rule

`main` is an accepted integration/evidence boundary, not a scratch branch. Current bounded implementation work continues from the integration lineage recorded by #135.

A normal implementation slice contains:

- one natural owner;
- at most one required platform/vendor/composition adapter;
- direct tests for that owner/adapter boundary.

A slice PR targets the current integration lineage unless #135 explicitly records another base. After acceptance, update the integration pointer in #135. Do not merge the integration lineage to `main` merely to record progress.

## CI and Android build rule

The stable development delivery contract is `docs/architecture/DEVELOPMENT_PIPELINE.md`.

Supported PRODUCT floor:

```text
Android 11 / API 30
armeabi-v7a
```

`android/app/build.gradle.kts` is the package/native floor authority. One `androidMinSdk=30` value must drive both Android `minSdk` and cargo-ndk `-P`. Android 23/26 compatibility is not a supported PRODUCT requirement.

### Integration PRs

For Android/Rust/build changes targeting `fix/root-policy-reconciliation`, `Integration Android Preflight` is the canonical hosted gate:

```text
draft -> compileDebugKotlin + lintDebug
ready -> fast gate + unit + assemble + native/package verification
      -> exact-head device-candidate artifact
```

Do not replace hosted exact-head evidence with an untracked local build.

### PRs to protected main

`Rust Workspace` and `Android Compose Shell` remain required contexts.

The main CI classifier is fail-safe:

- explicit LAB/docs/device-consumer-only paths may satisfy those contexts with fast no-build PASS jobs;
- PRODUCT/build inputs, CI policy, unknown paths, or ambiguity run the full Rust + Android gate;
- `workflow_dispatch` always runs the full gate.

After merge, `push -> main` is smoke-only: `Architecture Guards` run and duplicate Rust/Android rebuilds are skipped.

## DEVICE-1 development diagnostic rule

When #135 requires an irreducible physical fact for the next engineering decision, the normal path is:

```text
successful ready integration PR exact head
 -> hosted device-candidate artifact
 -> protected-main Device Candidate Physical workflow
 -> self-hosted Windows LAB consumes exact artifact
 -> candidate.json + SHA-256 verification
 -> persistent LAB-only debug signing
 -> adb install -r com.mobileproxymish.app.debug
 -> bounded physical evidence
```

The Windows LAB is a consumer by default, not a builder. The normal candidate path must not run Gradle, Cargo, cargo-ndk, UniFFI generation, NDK compilation or APK assembly locally. Portable PowerShell is not a prerequisite for this path.

If hosted artifact identity, digest, device identity or a required tool is wrong/missing, fail closed. Do not silently fall back to local build. A local build is an explicit engineering fallback only after a separate decision.

Exact-head PR debug candidates are development diagnostic evidence, not PRODUCT release identity. Formal release/promotion continues to use the immutable RC/release contract in `docs/architecture/RELEASE.md`.

## Evidence law

```text
E1 < E2 < E3 < E4
```

Weaker evidence must never close a stronger claim. A development DEVICE-1 diagnostic may inform the next implementation decision without becoming release acceptance.

Do not persist secrets, raw public IPs, unrelated logcat, device identifiers or credential material in durable evidence.

## Architecture law

Preserve:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Prefer an existing natural owner plus one narrow adapter.

Do not introduce:

- a second Android VPN/TUN;
- a second Cellular Egress, Runtime Lifecycle or Readiness owner;
- a generic root shell/control API;
- whole-UID/default-route public egress policy;
- Wi-Fi/default/WARP public-egress fallback;
- a mutable LAB/runtime status database or second control plane;
- false PASS from weaker or stale evidence.

## Physical uncertainty

Do not guess DEVICE-1, Magisk/root, RPDB, Cloudflare/provider or carrier facts from source code. When the next decision depends on real physical state, request or run the smallest bounded physical diagnostic and return sanitized typed evidence.
