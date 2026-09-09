# Architecture decision index

This file is a navigation index, not a second source of truth. Durable architecture decisions and stage acceptance live in GitHub Issues/PRs; code and versioned contracts live in Git.

## Planning and architecture authority

- Issue #1 — planning baseline for VM-free Android mobile proxy via Cloudflare Mesh.
- Issue #2 — completed architecture owner containing A1-A14 and A13.5 decision history.
- Issue #5 — completed ADR locking Rust-first core, Protobuf policy, Kotlin/Jetpack Compose/Material 3/StateFlow, UniFFI direction and related technology decisions.
- Issue #4 — vendor facts that must be revalidated when implementation reaches the relevant external boundary.
- Issue #22 — managed physical-lab prerequisite index; it is not a second CURRENT/product-stage pointer.
- Issue #24 — Cloudflare IaC/bootstrap authority for supported provider desired configuration.
- Issue #27 — Windows pre-Android Cloudflare/sing-box routing ownership contract and validation boundary.

## Physical repository derivation and governance

- Issue #6 — completed B0 physical-tree derivation from capability ownership/dependency rules.
- Issue #7 / PR #8 — completed B1 repository/bootstrap implementation.
- Issue #9 — completed main protection/ruleset blocker.
- `docs/lab/PLAN.md` — stable managed-lab execution sequence and ownership boundaries; live stage status remains in Issues.

## Current implementation line

- Issue #10 — single owner for B2 Cellular Egress + Android Network boundary.
- PR #11 — B2a cellular natural-owner semantics and Android observation seam.
- PR #12 — B2b-1 stable UniFFI typed cellular contract.
- PR #13 — B2b-2 Android native packaging/runtime bridge + owner-derived Compose projection.
- PR #14 — B2c-1 opaque exact-network authority lease, NDK DNS/socket binding seam.

The live status of B2 must be read from Issue #10 rather than copied into this file.

## Windows / Mesh contract navigation

- `docs/architecture/SYSTEM.md` — canonical product path and destination-based Windows route ownership: ordinary Internet via sing-box TUN, Mesh/device destinations via Cloudflare One Traffic only.
- Issue #27 — bounded pre-Android Windows acceptance; MASQUE is primary and Cloudflare One WireGuard is only a concrete-defect fallback.
- `docs/testing/E4_FULL_STACK.md` — later physical proof for the real Android Mesh proxy endpoint, cellular DNS/egress, browser compatibility and selected-app fail-closed behavior.

## Test/evidence navigation

- `docs/architecture/ACCEPTANCE.md` — E1/E2/E3/E4 evidence domains and readiness/acceptance separation.
- `docs/testing/E3_PHYSICAL_CELLULAR.md` — executable physical cellular acceptance protocol.
- `docs/testing/E4_FULL_STACK.md` — future Windows/Cloudflare/Mesh/Kameleo/Camoufox full-stack execution contract.
- `.github/workflows/e3-physical-cellular.yml` — manual self-hosted E3 runner workflow once a physical lab runner is connected.

## Non-authority rule

Do not turn this index, README text, CI logs, test summaries, or generated artifacts into a mutable product-state authority. The project law remains:

```text
one fact -> one natural owner -> one write path -> one observation path
```
