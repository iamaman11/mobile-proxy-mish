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
product Cellular Egress owner
        ↓
validated direct-cellular authority
        ↓
fail-closed product-owned cellular routing
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
- [Managed physical lab plan](docs/lab/PLAN.md)
- [Physical lab security boundary](docs/lab/SECURITY.md)
- [Managed lab evidence contract](docs/lab/EVIDENCE.md)
- [E3 physical cellular protocol](docs/testing/E3_PHYSICAL_CELLULAR.md)
- [E4 future full-stack protocol](docs/testing/E4_FULL_STACK.md)

Durable architecture decision history is in GitHub Issue #2 and ADR #5. Physical-tree derivation is Issue #6. Current Cellular Egress implementation/acceptance is owned by Issue #10; read that issue for live stage status rather than relying on copied status text in documentation.

## Core laws

```text
one fact -> one natural owner -> one write path -> one observation path
```

```text
Do not add a new architectural layer when an existing natural owner plus one narrow adapter can solve the concrete requirement correctly.
```

The repository is a modular monolith. Capability crates are compile-time ownership boundaries, not separate services or processes. The canonical dependency and minimal-layer rules live in `docs/architecture/DEPENDENCIES.md`.

## Development entry path

This is a navigation procedure, not a second live-status system:

```text
fresh accepted main + current natural-owner Issue
 -> identify the fact owner and the smallest bounded change
 -> prefer existing owner + existing port or one narrow new port + one adapter
 -> short-lived branch
 -> direct tests at the cheapest evidence level that can prove the claim
 -> PR
 -> exact-head required CI
 -> squash merge
 -> fresh post-merge verification
 -> record live stage status only in the natural-owner Issue
```

Physical claims are never promoted from weaker evidence: E3 proves the real rooted-phone/carrier Cellular Egress boundary; E4 proves the Windows -> Mesh -> Android -> proxy -> cellular full stack. New framework/process/control-plane/state layers require a concrete blocking ownership, privilege, lifecycle or failure-isolation fact and direct evidence as defined by `docs/architecture/DEPENDENCIES.md`.
