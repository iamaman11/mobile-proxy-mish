# Android artifact identity and physical acceptance

This file defines the Android artifact identity rule for Mobile Proxy MISH.

There is **no RC/prerelease lineage** in the development or physical-acceptance pipeline. No Android
Release Candidate workflow, RC tag reservation, GitHub prerelease, promotion ceremony or
release-specific physical resolver is required.

The canonical path is:

```text
exact PR head
  -> Integration Android Preflight
  -> hosted debug PRODUCT APK + AndroidTest APK
  -> candidate.json with exact source/base/ABI/digests
  -> GitHub Actions artifact
  -> explicit Device Cycle request
  -> verify artifact/run/source identity
  -> persistent LAB signing of the exact hosted payload
  -> install on DEVICE-1
  -> pull back installed base.apk
  -> verify installed digest + LAB signing identity
  -> launch + diagnostics + explicitly selected physical probe
  -> typed evidence
```

## Artifact authority

`.github/workflows/integration-android-preflight.yml` is the only hosted Android candidate producer.

The device candidate coordinate is:

```text
PR number + exact PRODUCT source SHA + exact GitHub artifact id/digest
```

The artifact contains:

- `mobile-proxy-mish-debug.apk`;
- `mobile-proxy-mish-debug-androidTest.apk`;
- `candidate.json`.

There is no mutable `latest` pointer and no tag-based candidate lookup.

## Physical authority

`.github/workflows/device-cycle.yml` is the only canonical Android DEVICE-1 installation and
physical-acceptance workflow.

The Windows LAB is a consumer, not a builder. It must never run Gradle, Cargo, cargo-ndk, NDK
compilation or UniFFI generation to rescue a missing/failed hosted candidate.

A normal physical cycle always resolves and downloads an already successful exact hosted artifact,
then verifies the complete lineage before installation.

## Signing

Hosted debug APK bytes are development candidate bytes. Before installation the LAB applies its
persistent debug/LAB signing identity and records the resulting digest and certificate.

Therefore physical identity is proven by lineage, not by assuming hosted APK SHA equals installed
base.apk SHA:

```text
hosted artifact digest
  -> hosted APK digest
  -> LAB-signed APK digest + signing certificate
  -> installed base.apk digest + installed certificate
```

## Accepted U8 development provenance closure

The final current-roadmap U8 acceptance is bound to one exact development lineage:

```text
PRODUCT source       94a9f4993b524b0388f0e2216e9e78183c8a3a4f
PRODUCT tree         d4f467c8a5c7d793835448eddd7cb0d6753b877e
hosted producer run  35803074208
candidate artifact   10726024554
candidate digest     sha256:a60bf25bc02413e4f93aad8bf62abedbf8db0e7a097806e261df3dd2428b336b
physical CONTROL     16a843cca4890b5d777b11cccb0ebeb9cb26924a
Device Cycle         35936074767 / #728 / PASS
install evidence     10782918236
install digest       sha256:ca6e37ac6be74ab8cec438038b92c2c36f9e098a0c1b3736aec11c94d93be4a3
cycle evidence       10783028195
cycle digest         sha256:b1a3bedd309748cf337e591c1eb9de922cef2e973ec856dcc72edc900662d544
```

The install evidence proves exact installed bytes and LAB signing identity. The physical evidence bundle
contains the bounded typed device diagnostic, targeted U8-G evidence, launch receipt and cycle report.
Those records are support/acceptance evidence only; they do not form a mutable status database.

Later CONTROL/docs-only commits do not create a new PRODUCT identity when the canonical PRODUCT paths
remain byte/tree-identical to the accepted source. A future externally distributed build may use a
different production signing/distribution mechanism, but its lineage must start from an explicitly
selected exact source/artifact and must not retroactively redefine this development acceptance.

## Distribution

Stable external distribution, store publication, or production signing may be defined later when the
roadmap reaches deployment closure. That future distribution task must not introduce a second
development/physical-acceptance authority and must not require an RC lineage.

Until then, exact hosted device-candidate artifacts plus canonical Device Cycle evidence are the only
Android build/physical-acceptance identity used by the project.
