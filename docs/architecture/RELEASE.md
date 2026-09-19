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

## Distribution

Stable external distribution, store publication, or production signing may be defined later when the
roadmap reaches deployment closure. That future distribution task must not introduce a second
development/physical-acceptance authority and must not require an RC lineage.

Until then, exact hosted device-candidate artifacts plus canonical Device Cycle evidence are the only
Android build/physical-acceptance identity used by the project.
