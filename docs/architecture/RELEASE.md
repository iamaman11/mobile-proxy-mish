# Build, release, and GitHub delivery

This document owns **formal Android release identity and promotion**. Development exact-head CI / DEVICE-1 candidates are governed by `DEVELOPMENT_PIPELINE.md` and Issue #135.

Protected `main` is the latest accepted PRODUCT + CONTROL source. A PR head is only a development candidate until accepted and merged.

## Supply-chain law

Formal release acceptance preserves:

```text
PIN
 -> BUILD ONCE
 -> HASH
 -> SIGN
 -> ATTEST
 -> TEST EXACT BYTES
 -> PROMOTE EXACT BYTES
 -> INSTALL WITH EXPLICIT COMPATIBILITY
 -> OBSERVE FRESH REALITY
```

Authority split:

```text
protected main + reviewed workflows
  = accepted source, lockfiles, build/test/release definitions

GitHub-hosted restricted release workflow
  = Android release build/sign/package authority

GitHub Release exact tag + manifest + digest
  = versioned binary distribution identity

Physical LAB
  = exact-byte consumer and physical evidence executor

Runtime
  = live Android/Cloudflare/network reality
```

Release-signing private material belongs only to the restricted GitHub release environment. It must not exist in ordinary PR jobs, the repository, or the self-hosted physical runner.

## Android release-candidate path

The formal RC path is owned by `.github/workflows/android-release.yml` and the current release contract:

```text
accepted release source commit on main
 -> immutable RC tag vMAJOR.MINOR.PATCH-rc.N
 -> restricted hosted build/sign
 -> final signed APK verification
 -> SHA-256 + signing certificate identity
 -> versioned release manifest
 -> exact GitHub prerelease
 -> exact-tag download/readback
 -> byte-for-byte + manifest verification
 -> formal physical acceptance
```

`latest` is never machine identity. Formal acceptance names the exact tag, source commit, signing identity and APK digest.

## Stable promotion

Stable promotion reuses accepted RC bytes; it does not rebuild them:

```text
RC tag + signed APK digest X
 -> required formal physical acceptance PASS
 -> stable tag for the same base version
 -> publish/reference the same APK bytes
 -> stable digest remains X
```

Cross-version promotion is invalid. Gradle/Cargo must not run merely to recreate an artifact that has already passed formal physical acceptance.

Rollback selects a previously accepted exact artifact digest after compatibility admission; it does not rebuild an old tag and assume equivalence.

## Development candidate boundary

Development physical evidence is separate from release identity:

```text
open ready PR to main, exact PRODUCT head
 -> Integration Android Preflight PASS
 -> device-candidate-pr-<PR>-<PRODUCT_SHA>
 -> explicit protected-main Device Cycle request
 -> CONTROL_SHA resolves/verifies exact producer/artifact provenance
 -> Windows LAB consumes exact artifact; no local Android rebuild
 -> adb install -r when requested
 -> installed-byte/signature verification
 -> bounded current-PRODUCT diagnostics / requested current-function probe
 -> immutable evidence
 -> STOP_FOR_ANALYSIS
 -> merge accepted change to main
```

This path lets the active roadmap stage obtain a real physical fact **before merge** without pretending a development build is release identity.

A development candidate:

- originates from the exact open ready PR to `main` being evaluated;
- remains bound to `PRODUCT_SHA`, hosted run/artifact identity and digest;
- is executed by an explicit `CONTROL_SHA` from protected main;
- uses the isolated debug package identity;
- never receives release-signing material;
- cannot be promoted or relabeled as RC/stable;
- cannot satisfy a formal release-signing or promotion claim;
- cannot silently fall back to another commit or local rebuild.

The Windows LAB is a consumer by default.

## Development and merge policy

Live execution state belongs only to Issue #135. Ordered stage/product direction belongs to `PRODUCT_ROADMAP.md`. Issue #134 is historical research/rationale.

`main` is the accepted PRODUCT + CONTROL integration boundary. Accepted development slices should merge to `main` promptly after their required evidence passes. Do not keep accepted PRODUCT state on a long-lived parallel integration branch.

A development physical fact does not itself authorize formal release promotion. It may, however, be the required evidence for accepting the candidate PR into `main`.

## Provider and control-plane constraints

Do not create an Issue-command deployment controller, environment-branch control plane, mutable release-status database, custom artifact registry, or always-on remote-control daemon merely to bridge delivery steps.

Supported provider desired configuration should use one declarative Git-reviewed path where the provider exposes a stable resource/API. Terraform state is deployment machinery, not PRODUCT/runtime truth.

## Conflict rule

- `DEVELOPMENT_PIPELINE.md` + executable workflows own development candidate/Device Cycle mechanics.
- This file owns only formal RC/release identity/promotion.
- `ACCEPTANCE.md` owns evidence-strength boundaries.
- Issue #135 owns current stage/open PR/evidence ids, never release semantics themselves.
