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

Physical acceptance later uses a protected GitHub Environment plus one serialized bounded lab/device deployment adapter. Do not create an Issue-command router, deployment controller, environment branches, or mutable deployment-status database.

Rollback selects a previously accepted exact artifact digest after compatibility admission; it does not rebuild an old tag and assume equivalence.
