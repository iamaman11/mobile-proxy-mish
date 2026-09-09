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

Current commits are implementation-stage evidence only. They must not be interpreted as proof that Mesh, proxy serving, rotation, full runtime recovery, E3 physical cellular acceptance, E4 full-stack acceptance, or product readiness is complete.

## Architecture navigation

- [Decision index](docs/architecture/DECISION_INDEX.md)
- [System and process model](docs/architecture/SYSTEM.md)
- [Capability ownership](docs/architecture/OWNERSHIP.md)
- [Allowed dependency graph](docs/architecture/DEPENDENCIES.md)
- [Contract boundaries](docs/architecture/CONTRACTS.md)
- [Readiness and acceptance](docs/architecture/ACCEPTANCE.md)
- [Build, release, and GitHub delivery](docs/architecture/RELEASE.md)
- [E3 physical cellular protocol](docs/testing/E3_PHYSICAL_CELLULAR.md)
- [E4 future full-stack protocol](docs/testing/E4_FULL_STACK.md)

Durable architecture decision history is in GitHub Issue #2 and ADR #5. Physical-tree derivation is Issue #6. Current Cellular Egress implementation/acceptance is owned by Issue #10; read that issue for live stage status rather than relying on copied status text in documentation.

## Core law

```text
one fact -> one natural owner -> one write path -> one observation path
```

The repository is a modular monolith. Capability crates are compile-time ownership boundaries, not separate services or processes.
