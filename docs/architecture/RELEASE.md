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
Git     = declarative source, contracts, lockfiles, build/test/workflow definitions
GitHub  = review, CI, immutable artifact/release/deployment evidence
Runtime = live Android/Cloudflare/network reality
```

Standard development path:

```text
short-lived branch -> PR -> required CI -> squash merge -> main
```

Physical acceptance uses one serialized bounded lab/device execution path. The stable lab ownership, security and evidence contracts are versioned in:

- `docs/lab/PLAN.md`;
- `docs/lab/SECURITY.md`;
- `docs/lab/EVIDENCE.md`.

Do not create an Issue-command router, deployment controller, environment branches, mutable deployment-status database, or always-on custom remote-control daemon. The physical runner is execution transport only; repository-local `labctl` is a stateless execution adapter only.

Supported Cloudflare desired configuration should use one declarative Git-reviewed path where the provider exposes a stable resource/API. Terraform state is deployment machinery, not product/runtime truth. One-time provider bootstrap exceptions must be explicit rather than silently becoming a permanent second dashboard write path.

Rollback selects a previously accepted exact artifact digest after compatibility admission; it does not rebuild an old tag and assume equivalence.
