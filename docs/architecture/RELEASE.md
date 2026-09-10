# Build, release, and GitHub delivery

Canonical supply-chain path:

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
Git source + reviewed workflow
  = declarative source, contracts, lockfiles, build/test/release definition

GitHub-hosted restricted release workflow
  = Android release build/sign/package authority

GitHub Release exact version/tag + release manifest + APK digest
  = versioned binary distribution identity

Physical LAB
  = exact-release consumer and physical evidence executor only

Runtime
  = live Android/Cloudflare/network reality
```

Normal PR/main CI may compile debug/test APKs to prove source changes. Those artifacts are CI evidence only and are never promoted as the product release.

## Android release-candidate path

The concrete RC path is owned by issue #48 and `.github/workflows/android-release.yml`:

```text
accepted source commit
 -> immutable RC tag vMAJOR.MINOR.PATCH-rc.N
 -> restricted GitHub-hosted build/sign job
 -> final signed APK verification
 -> SHA-256 + signing certificate identity
 -> mish.android-release/v1 manifest
 -> exact versioned GitHub prerelease
 -> exact-tag download/readback
 -> byte-for-byte comparison + manifest verification
 -> physical acceptance consumer
```

The RC tag maps deterministically to Android `versionName` and monotonic `versionCode`. A stable tag is deliberately not a build input.

Release-signing private material belongs only to the restricted GitHub `android-release` environment. It must not exist in the repository, ordinary PR jobs, or the self-hosted physical runner.

`latest` may be a human convenience pointer but is never machine release identity. Physical acceptance must name the exact RC/release tag, exact source commit and exact APK SHA-256.

## Stable promotion

Stable means promotion of already accepted RC bytes, not another Android build:

```text
RC tag + signed APK digest X
 -> required physical acceptance PASS
 -> stable tag for the same base version
 -> publish/reference the same signed APK bytes
 -> stable digest remains X
```

Cross-version promotion is invalid. Gradle/Cargo must not run as part of stable promotion merely to recreate an artifact that has already passed physical acceptance.

The repository may implement the promotion ceremony only when the physical acceptance owner can provide the required exact RC identity/evidence. Do not create a separate release-status database or mutable approval service just to bridge that gate.

## Standard development path

```text
short-lived branch -> PR -> required CI -> squash merge -> main
```

Physical acceptance uses one serialized bounded lab/device execution path. The stable lab ownership, security and evidence contracts are versioned in:

- `docs/lab/PLAN.md`;
- `docs/lab/SECURITY.md`;
- `docs/lab/EVIDENCE.md`.

Do not create an Issue-command router, deployment controller, environment branches, mutable deployment-status database, custom artifact registry, or always-on custom remote-control daemon. The physical runner is execution transport only; repository-local `labctl` is a stateless exact-release verifier/execution adapter only.

Supported Cloudflare desired configuration should use one declarative Git-reviewed path where the provider exposes a stable resource/API. Terraform state is deployment machinery, not product/runtime truth. One-time provider bootstrap exceptions must be explicit rather than silently becoming a permanent second dashboard write path.

Rollback selects a previously accepted exact artifact digest after compatibility admission; it does not rebuild an old tag and assume equivalence.
