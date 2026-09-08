# mobile-proxy-mish

Clean VM-free Android mobile-proxy successor built around Cloudflare Mesh and phone-owned cellular egress.

## Product path

```text
Kameleo / Camoufox
        ↓
Cloudflare One Client
        ↓
Cloudflare Mesh
        ↓
Cloudflare One Agent on Android
        ↓
product-admitted Mesh listener
        ↓
sing-box (:1080 / :1081 / :3128)
        ↓
validated Android cellular Network
        ↓
LTE/5G Internet
```

This repository is now in bootstrap implementation. No current commit should be interpreted as proof that Mesh, cellular egress, proxy serving, rotation, or physical-device acceptance is complete.

## Architecture navigation

- [System and process model](docs/architecture/SYSTEM.md)
- [Capability ownership](docs/architecture/OWNERSHIP.md)
- [Allowed dependency graph](docs/architecture/DEPENDENCIES.md)
- [Contract boundaries](docs/architecture/CONTRACTS.md)
- [Readiness and acceptance](docs/architecture/ACCEPTANCE.md)
- [Build, release, and GitHub delivery](docs/architecture/RELEASE.md)

Durable architecture decision history is in GitHub Issue #2 and ADR #5. Physical-tree derivation is Issue #6. Active bootstrap stage is Issue #7.

## Core law

```text
one fact -> one natural owner -> one write path -> one observation path
```

The repository is a modular monolith. Capability crates are compile-time ownership boundaries, not separate services or processes.
