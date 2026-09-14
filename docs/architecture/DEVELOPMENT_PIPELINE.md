# Development CI and DEVICE-1 candidate contract

This document is the stable versioned authority for development CI, hosted Android candidate production, and DEVICE-1 development diagnostics. Live stage/checkpoint state belongs to Issue #135. The PRODUCT/architecture hardening plan belongs to Issue #134.

It does not replace the immutable RC/release contract in `docs/architecture/RELEASE.md` for formal release promotion.

## Supported Android product floor

The supported appliance target is Android 11 / API 30.

Canonical build authority:

```text
android/app/build.gradle.kts
  androidMinSdk = 30
  -> Android defaultConfig.minSdk
  -> cargo-ndk -P
```

The Windows LAB manifest mirrors that product fact:

```text
lab/windows/toolchain.json
  android.min_sdk = 30
  rust.target = armv7-linux-androideabi
```

`android/gradle.properties` owns the PRODUCT ABI selection and currently fixes `mishTargetAbi=armeabi-v7a`.

Android 23 and Android 26 are not supported PRODUCT compatibility floors. Do not add API-23/API-26 compatibility shims unless a new accepted product requirement explicitly reopens support below API 30.

## CI contract

### Pull requests to protected `main`

`Rust Workspace` and `Android Compose Shell` remain required status contexts for branch protection.

The CI classifier is deliberately fail-safe:

```text
all changed files belong to the explicit no-product-build allowlist
  -> required contexts run as fast PASS jobs
  -> PRODUCT Rust/Android build steps are skipped

any PRODUCT/build input, CI policy file, unknown path, or classifier uncertainty
  -> full Rust + Android gate
```

The no-product-build allowlist is intentionally narrow: LAB-only files, docs/README, and the bounded LAB/device-candidate workflows. The classifier defaults to the full gate rather than guessing that an unfamiliar change is harmless.

`workflow_dispatch` always performs the full Rust + Android gate.

After an accepted merge, `push -> main` performs `Architecture Guards` only; duplicate Rust/Android rebuilds are skipped. The expensive acceptance work belongs to the exact PR head that entered `main`.

### Integration PRs to `fix/root-policy-reconciliation`

`.github/workflows/integration-android-preflight.yml` owns the hosted Android development gate.

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
 -> exact-head device candidate artifact
```

Rust, Gradle, cargo-ndk, NDK and build caches are keyed from pinned toolchain versions and relevant exact inputs. Superseded PR runs are cancelled by concurrency.

The ready-PR artifact name is:

```text
device-candidate-pr-<PR>-<40-hex source SHA>
```

It contains the isolated debug APK, AndroidTest APK, and `candidate.json` with exact source/base identity, target ABI, application id and SHA-256 digests.

Artifacts are short-lived CI evidence. If an exact-head artifact expires, rerun the hosted gate for that same exact head or produce a new exact head; never silently substitute bytes from another commit.

## DEVICE-1 development diagnostic consumer

`.github/workflows/device-candidate-physical.yml` is the protected-main consumer for development diagnostics.

Inputs identify the integration PR and optionally pin its expected current head SHA. The workflow must fail closed unless all of these are true:

- the PR is open and ready;
- the PR targets `fix/root-policy-reconciliation`;
- the PR originates from the canonical repository;
- the current head matches `expected_head_sha` when supplied;
- a non-expired artifact exists for that exact PR/head;
- the artifact came from a successful completed `Integration Android Preflight` PR run for that same head/branch;
- artifact metadata includes a valid SHA-256 digest.

The self-hosted Windows job is a consumer, not a builder. Its normal path is:

```text
protected main workflow
 -> built-in Windows PowerShell
 -> exactly one authorized DEVICE-1
 -> API 30 + armeabi-v7a check
 -> download exact hosted artifact
 -> verify candidate.json
 -> verify APK SHA-256 values
 -> create/reuse persistent LAB-only debug signing identity
 -> sign isolated debug APKs
 -> adb install -r com.mobileproxymish.app.debug
 -> physical diagnostic/evidence collection
```

The normal DEVICE-1 candidate path must not invoke Gradle, Cargo, cargo-ndk, UniFFI generation, NDK compilation or local APK assembly. Portable PowerShell is not a prerequisite for this path.

If a required hosted artifact, digest, tool, signing prerequisite or device identity is wrong or missing, stop with a typed failure. Do not automatically fall back to a local build.

A local build remains an explicit engineering fallback for a separate diagnostic decision; it is never implicit evidence substitution.

## Evidence boundary

An exact-head PR debug candidate may be used for development physical diagnostics when Issue #135 explicitly requires a physical fact for the next engineering decision, for example P0 recovery attribution.

It is not PRODUCT release identity and cannot be promoted to a stable release.

Formal E3/release acceptance that authorizes promotion continues to use the immutable RC/release path:

```text
PIN -> BUILD ONCE -> HASH -> SIGN -> ATTEST -> TEST EXACT BYTES -> PROMOTE EXACT BYTES
```

No debug candidate may be relabeled as an RC/release or satisfy a release-signing claim.

## Reproducibility and ownership

The intended authorities are:

```text
PRODUCT Android floor / package-native build graph
  -> android/app/build.gradle.kts

PRODUCT ABI
  -> android/gradle.properties

hosted integration candidate production
  -> integration-android-preflight.yml

protected physical candidate consumption
  -> device-candidate-physical.yml

candidate byte verification / LAB debug signing / install
  -> lab/windows/install-device-candidate.ps1

LAB bootstrap toolchain mirror
  -> lab/windows/toolchain.json

live execution pointer
  -> Issue #135

master hardening/product plan
  -> Issue #134
```

The repository architecture guard must reject drift in the API floor, ABI/Rust-target mirror, required path-aware CI contract, and no-local-build DEVICE-1 consumer invariants.
