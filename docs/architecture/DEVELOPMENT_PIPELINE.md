# Development CI and DEVICE-1 candidate contract

This document is the stable development-delivery contract. Protected `main` is the latest accepted PRODUCT + CONTROL source. Live stage/checkpoint state belongs to Issue #135. Ordered PRODUCT direction belongs to `PRODUCT_ROADMAP.md`. Executable workflows are the mechanical authority if prose and YAML disagree.

It does not replace `RELEASE.md` for formal RC/release promotion.

## Supported PRODUCT floor

```text
Android 11 / API 30
armeabi-v7a
```

Canonical build authority remains the Android/Rust build graph. Android 23 and Android 26 are not supported PRODUCT compatibility floors. Do not add lower-API compatibility shims unless a new accepted PRODUCT requirement explicitly reopens support below API 30.

## Integration Android Preflight

`.github/workflows/integration-android-preflight.yml` is the exact-head hosted candidate producer for PRODUCT-changing PRs targeting protected `main`.

Current contract:

```text
PR to main opened / synchronized / reopened / ready-for-review
 -> checkout exact PR head
 -> Kotlin compile + lint
 -> when PR is ready/non-draft:
      Rust fmt
      Rust clippy -D warnings
      Rust workspace tests --locked
      Android Rust/NDK setup
      Android/Kotlin unit tests
      assembleDebug
      assembleDebugAndroidTest
      exact PRODUCT candidate verification
      publish exact-head device candidate artifact
```

The candidate artifact is produced only after the complete configured gate succeeds.

A successful hosted build is a prerequisite only. No successful build, merge to main, label, or completed workflow starts DEVICE-1.

## Exact candidate identity

Ready candidate artifact naming:

```text
device-candidate-pr-<PR>-<40-hex PRODUCT_SHA>
```

The artifact contains the debug PRODUCT APK, AndroidTest APK and `candidate.json` with exact source/base identity, application id, target ABI and APK digests.

Expired, superseded or mismatched artifacts fail closed; never silently substitute bytes from another commit.

## Protected-main Device Cycle

`.github/workflows/device-cycle.yml` owns development physical execution.

The canonical engineering loop is intentionally explicit:

```text
diagnostic -> analysis -> decision -> code -> completed build -> explicit cycle request -> install -> verify install -> launch -> diagnostic -> analysis
```

Diagnostics never chooses a repair. No automatic targeted probe is allowed. Analysis chooses any follow-up action after the previous run has stopped.

One explicit request produces one GitHub Actions Device Cycle run. There is no automatic start from build completion, PR merge, main merge, label or artifact publication.

Current accepted command forms are defined by the workflow. At this policy revision they are:

```text
/mish-cycle full <PRODUCT_SHA>
/mish-cycle install_only <PRODUCT_SHA>
/mish-cycle diagnose_only <PRODUCT_SHA>
/mish-cycle probe_only <PRODUCT_SHA> loopback_connect
```

`probe_only` supports only the current-function `loopback_connect` probe unless the executable workflow is deliberately changed and this document is updated with it.

`full`, `install_only` and `diagnose_only` accept no probe argument.

## PRODUCT_SHA and CONTROL_SHA

Protected `main` is the accepted source for both PRODUCT and CONTROL. The two-SHA form exists only as pre-merge physical evidence provenance:

```text
PRODUCT_SHA = exact open ready PR head being physically exercised
CONTROL_SHA = exact protected-main workflow/scripts executing that physical cycle
```

That split does not create two accepted sources. When a candidate is accepted and merged, protected `main` again contains the accepted PRODUCT and CONTROL together.

For `full` / `install_only`:

- the candidate must be an **open, ready PR to `main`**;
- the exact hosted candidate producer must already have completed successfully;
- the producer workflow blob at PRODUCT_SHA must match the protected-main producer workflow blob required by the Device Cycle resolver;
- any mismatch fails closed before installation.

Do not perform a second `full`/`install_only` acceptance of a merged PR merely to reconstruct accepted state. Accepted state comes from `main`; later physical work starts from a new explicit need/candidate.

## Physical runner contract

The Windows LAB is a consumer, not a builder.

Normal path:

```text
successful exact hosted artifact already exists for an open ready PR to main
 -> explicit /mish-cycle request after analysis
 -> verify PR/base/source identity
 -> verify accepted producer policy
 -> verify hosted run/artifact/digest provenance
 -> checkout exact CONTROL_SHA
 -> verify pinned PowerShell/runtime + DEVICE-1 prerequisites
 -> consume exact candidate
 -> stable LAB-only debug signing where configured
 -> adb install -r when mode requests installation
 -> read back installed base.apk
 -> installed base.apk SHA-256 == exact signed candidate SHA-256
 -> verify installed signing identity
 -> launch when mode requests it
 -> collect generation-consistent current-L8 diagnostics
 -> optional explicitly requested current-function probe
 -> produce typed evidence/report
 -> STOP_FOR_ANALYSIS
```

`adb install -r = Success` is necessary but not sufficient. When installation is part of the cycle, launch/acceptance is blocked until the installed APK bytes and signing identity are verified against the exact candidate.

The runner must not silently run Gradle, Cargo, cargo-ndk, NDK compilation, UniFFI generation, local APK assembly or clean uninstall to rescue a failed candidate path.

Pinned PowerShell/tool requirements are real physical-run prerequisites and are enforced by the executable workflow/scripts.

## Modes

### `full`

Requires an already successful exact-head hosted candidate from an open ready PR to `main`.

```text
resolve provenance
 -> install exact candidate
 -> verify installed bytes/signing identity
 -> launch/restart app as defined by workflow
 -> canonical diagnostics
 -> exact-candidate acceptance classification
 -> STOP
```

### `install_only`

Requires an already successful exact-head hosted candidate from an open ready PR to `main`.

```text
resolve provenance
 -> install
 -> verify installed bytes/signing identity
 -> STOP
```

### `diagnose_only`

No candidate installation claim.

```text
use currently installed debug package
 -> explicit app launch/restart as defined by workflow
 -> canonical diagnostics
 -> STOP
```

The result cannot be promoted into exact candidate acceptance because installation identity was not established in that cycle.

### `probe_only`

No install and no app restart.

```text
run exactly one explicitly named read-only current-function probe
 -> evidence
 -> STOP
```

A successful probe means the probe executed/collected evidence; it is not exact PRODUCT acceptance.

## Canonical diagnostics

Current APK diagnostics use `mish.diagnostics/v2` / `snapshot_v2` and observe current native facts only:

- runtime running/generation consistency;
- Cellular admission/boundary state;
- root authority/root-policy authorization;
- native Proxy Serving state/health/typed failure;
- credential state;
- Mesh admission/ingress;
- Readiness.

Diagnostics do not own or execute repairs, root mutations, network toggles, credential rotation, install, runtime lifecycle decisions or legacy process management.

Historical Android sing-box/runtime identity is not a current PRODUCT diagnostic fact.

## Recovery sequencing

Automatic airplane recovery is not part of the baseline cycle. Baseline functionality is established first. Cellular-loss/airplane/recovery acceptance is run only as a separately authorized stage when the roadmap requires that physical fact.

## Acceptance fields

Physical reporting separates mechanical execution from PRODUCT acceptance.

```text
cycle_result
  did the requested cycle/probe execute and collect its required evidence?

exact_candidate_acceptance
  evaluated only when the exact installed candidate and required baseline were exercised
```

A green `probe_only` or `diagnose_only` must never be interpreted as exact candidate acceptance.

## Formal release boundary

Development debug candidates are stage/development evidence only. It is not PRODUCT release identity and cannot be promoted.

Formal promotion remains:

```text
PIN -> BUILD ONCE -> HASH -> SIGN -> ATTEST -> TEST EXACT BYTES -> PROMOTE EXACT BYTES
```

under `RELEASE.md`.

## Stable authorities

```text
accepted PRODUCT + CONTROL source       -> protected main
live execution pointer                  -> Issue #135
ordered PRODUCT plan                    -> PRODUCT_ROADMAP.md
reconstruction/authority map            -> SOURCE_OF_TRUTH.md
hosted candidate producer               -> integration-android-preflight.yml
physical development executor           -> device-cycle.yml + lab/windows scripts
architecture                            -> SYSTEM.md / DEPENDENCIES.md / OWNERSHIP.md
formal release                          -> RELEASE.md
```

Repository guards should reject drift back to automatic phone starts, local rebuilding in the normal physical path, long-lived accepted PRODUCT outside main, stale/floating control identity, automatic repair/probe decisions, legacy Android proxy assumptions, accepting `adb install` without installed-byte/signature verification, or treating a read-only probe as exact PRODUCT acceptance.
