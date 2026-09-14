# Build, release, and GitHub delivery

This document owns formal Android release identity and promotion. Development CI and DEVICE-1 diagnostic candidates are governed separately by `docs/architecture/DEVELOPMENT_PIPELINE.md`.

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
Git source + reviewed workflows
  = source, lockfiles, build/test/release definitions

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

The formal RC path is owned by `.github/workflows/android-release.yml` and its natural-owner issue:

```text
accepted source commit
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

Ordinary integration CI may produce an isolated debug/test candidate for a real-device engineering diagnostic:

```text
ready integration PR exact head
 -> hosted full gate PASS
 -> device-candidate-pr-<PR>-<source SHA>
 -> protected-main Device Candidate Physical consumer
 -> exact run/artifact/digest verification
 -> LAB-only debug signing
 -> com.mobileproxymish.app.debug
 -> bounded DEVICE-1 diagnostic
```

This path exists to shorten engineering feedback when Issue #135 requires a physical fact for the next decision. It is intentionally **not** release identity.

A development candidate:

- may originate from the current canonical integration PR exact head;
- must remain bound to exact source SHA, workflow run, artifact identity and SHA-256;
- must use the isolated debug package identity;
- must not expose release-signing material;
- must not be promoted or relabeled as RC/stable;
- must not satisfy a formal release-signing or promotion claim;
- must not silently fall back to a different commit or a local rebuild.

The Windows LAB is a consumer by default. Local builds remain an explicit diagnostic fallback only and never substitute for the selected hosted bytes without a separate engineering decision.

## Development and merge policy

Live execution state belongs to Issue #135; the master hardening/product plan belongs to Issue #134. Stable implementation policy is versioned in `AGENTS.md`, `docs/architecture/EXECUTION.md`, and `docs/architecture/DEVELOPMENT_PIPELINE.md`.

`main` is an accepted integration/evidence boundary, not a progress ledger. A development physical diagnostic does not by itself force the integration lineage to merge to `main`; exact-head hosted debug candidates exist specifically so physical attribution can happen without manufacturing a release or merging solely to obtain APK bytes.

## Provider and control-plane constraints

Do not create an Issue-command router, deployment controller, environment branches, mutable release-status database, custom artifact registry, or always-on remote-control daemon merely to bridge delivery steps.

Supported provider desired configuration should use one declarative Git-reviewed path where the provider exposes a stable resource/API. Terraform state is deployment machinery, not PRODUCT/runtime truth.
