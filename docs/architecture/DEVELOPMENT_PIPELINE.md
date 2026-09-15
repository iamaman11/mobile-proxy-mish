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

`workflow_dispatch` always performs the full Rust + Android gate. After an accepted merge, `push -> main` performs architecture/delivery smoke only; duplicate Rust/Android rebuilds are skipped.

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

The exact-head artifact is created only after the complete ready-PR gate succeeds. A `workflow_run: completed` event by itself is never install authority: `device-cycle.yml` additionally requires `conclusion == success`, and the successful run SHA must still equal the current PR head. A failed, cancelled, still-building, or superseded build therefore cannot start an install cycle.

The ready-PR artifact name is:

```text
device-candidate-pr-<PR>-<40-hex source SHA>
```

It contains the isolated debug APK, AndroidTest APK, and `candidate.json` with exact source/base identity, target ABI, application id and SHA-256 digests.

Artifacts are short-lived CI evidence. If an exact-head artifact expires, rerun the hosted gate for that same exact head or produce a new exact head; never silently substitute bytes from another commit.

## DEVICE-1 development candidate installer

`.github/workflows/device-candidate-physical.yml` is the single physical installer for exact hosted development candidates. It owns artifact verification, stable LAB signing, replacement installation, and verification of the bytes actually installed on DEVICE-1. It does not launch the app or diagnose PRODUCT behavior.

The caller supplies both identities:

```text
PRODUCT_SHA = exact integration PR head whose APK is installed
CONTROL_SHA = exact protected-main commit whose installer/verifier scripts execute
```

The physical workflow fails closed if its own run SHA differs from `CONTROL_SHA`; self-hosted checkout is pinned to that exact SHA.

The normal path is:

```text
successful exact-head hosted artifact
 -> verify candidate.json + hosted run identity + artifact digest
 -> create/reuse persistent LAB-only debug signing identity
 -> sign isolated debug APK
 -> adb install -r
 -> adb shell pm path <package>
 -> pull installed base.apk
 -> installed base.apk SHA-256 == signed candidate SHA-256
 -> installed signing certificate == expected LAB certificate
 -> INSTALL_VERIFY=PASS
```

`adb install -r = Success` is necessary but not sufficient. Launch/diagnostics are forbidden until installed exact-byte/signing verification passes.

The Windows LAB is a consumer, not a builder. The normal path must not invoke Gradle, Cargo, cargo-ndk, UniFFI generation, NDK compilation, local APK assembly, uninstall, credential rotation, or PRODUCT policy mutation.

If any artifact, digest, signing prerequisite, device identity, install result, installed byte digest, or installed certificate is wrong or missing, stop with a typed failure. Do not automatically fall back to a local build or another APK.

## Canonical DEVICE-1 engineering cycle

The control model is deliberately simple:

```text
diagnostic -> analysis -> decision -> code -> completed build -> install -> verify install -> launch -> diagnostic -> analysis
```

Diagnostics never chooses a repair. Diagnostics reports facts and classifications only. It never edits PRODUCT code/configuration, changes root policy, rotates credentials, reinstalls, selects a repair, or starts the next code cycle.

`.github/workflows/device-cycle.yml` automates only the mechanical segment after an already-made code decision:

```text
completed successful exact-head build
 -> exact artifact resolution
 -> canonical install
 -> exact installed-byte/signing verification
 -> explicit app launch
 -> one canonical diagnostic snapshot
 -> evidence publication
 -> STOP
```

There is **No automatic targeted probe** in `full` or `diagnose_only`. If the canonical snapshot is insufficient, analysis happens first; only then may an operator explicitly request `probe_only` with exactly one read-only probe such as `runtime_identity` or `loopback_connect`.

The supported manual modes are:

- `full` — completed successful exact build -> install -> verify install -> launch -> canonical diagnostic -> stop;
- `install_only` — completed successful exact build -> install -> verify install -> stop;
- `diagnose_only` — launch current installed debug package -> canonical diagnostic -> stop; no claim that PR bytes are installed;
- `probe_only` — no install and no restart; run exactly one explicitly named read-only probe after an analysis decision.

`full`, `install_only`, and `diagnose_only` require `probe=none`. `probe_only` rejects `none`. This keeps analysis outside the diagnostic workflow.

Every cycle carries separate provenance:

```text
PRODUCT_SHA
CONTROL_SHA
HOSTED_RUN_ID
INSTALL_RUN_ID
DEVICE_CYCLE_RUN_ID
```

If protected `main` moves after the Device Cycle run is created, the running cycle continues with its original exact `CONTROL_SHA`; if the separately dispatched physical workflow starts from another SHA, it fails closed before touching DEVICE-1.

Automatic mode is enabled per integration PR by the `device-cycle` label and starts only after the exact `Integration Android Preflight` has completed successfully. Automatic mode never runs airplane recovery. A baseline must first reach authenticated loopback PASS and Mesh PASS; recovery/airplane acceptance remains a separately requested later stage.

The visible control points are intentionally sequential and independently attributable:

```text
BUILD_PASS
ARTIFACT_RESOLVED
INSTALL_PASS
INSTALL_VERIFY_PASS
LAUNCH_PASS / PRODUCT_TERMINAL_FAILURE
DIAGNOSTIC_CAPTURED
REPORT_PUBLISHED
STOP_FOR_ANALYSIS
```

No workflow stage after `DIAGNOSTIC_CAPTURED` mutates PRODUCT state or decides what code should change next.

## Evidence boundary

An exact-head PR debug candidate may be used for development physical diagnostics when Issue #135 explicitly requires a physical fact for the next engineering decision.

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

physical install + installed-byte verification
  -> device-candidate-physical.yml
  -> install-device-candidate.ps1
  -> verify-installed-candidate.ps1

sequential launch/diagnostic orchestration
  -> device-cycle.yml

canonical read-only aggregate diagnostic
  -> collect-device-diagnostic.ps1

explicit post-analysis targeted probes
  -> collect-runtime-identity.ps1 / diagnose-loopback-connect.ps1

live execution pointer
  -> Issue #135

master hardening/product plan
  -> Issue #134
```

The repository guards must reject drift back to local rebuilding, uninstall/reinstall migration in the normal path, automatic repair/probe decisions, floating control checkout, ambiguous LAB/Product diagnostic attribution, or accepting `adb install` without verifying the installed exact bytes.
