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
- PR #73 — application-wide minimal-layer extension invariant: existing natural owner + one narrow adapter before any new architectural layer.
- `AGENTS.md` — executor rules for baselining, batching, draft PRs, CI, `main` and LAB boundaries.
- `docs/architecture/EXECUTION.md` — stable evidence-milestone integration policy; live status remains in Issues.
- `docs/lab/PLAN.md` — stable managed-lab execution sequence and ownership boundaries; live stage status remains in Issues.

## Current implementation line

- Issue #86 — current cross-component execution tracker to `PROXY_ON_PHONE_WORKING=YES`; it owns execution order and milestone gates only, not component semantics.
- Issue #10 — single owner for B2 Cellular Egress implementation and E3 acceptance.
- Issue #63 — physical Android/device behavior and root-policy characterization evidence owner.
- Issue #75 — bounded PRODUCT root-policy mechanism/correction owner.
- Issue #64 — final proxy-destination DNS ownership / anti-leak acceptance owner; early E1/E2 implementation work may be prepared before its final physical acceptance gate.
- PR #11 — B2a cellular natural-owner semantics and Android observation seam.
- PR #12 — B2b-1 stable UniFFI typed cellular contract.
- PR #13 — B2b-2 Android native packaging/runtime bridge + owner-derived Compose projection.
- PR #14 — historical B2c-1 exact-network lease/NDK bind seam. Physical target-topology evidence later showed the bind mechanism fails with `EPERM`; Issue #10 owns its replacement by the accepted root-policy path while preserving the existing Cellular Egress owner.

Read live cross-component order from Issue #86. Read semantic/acceptance status from the relevant natural-owner issue. Device-specific findings live in Issue #63. Historical PRs and older closure plans remain implementation/evidence history and do not override later accepted execution disposition.

## Windows / Mesh contract navigation

- `docs/architecture/SYSTEM.md` — canonical product path and destination-based Windows route ownership: ordinary Internet via sing-box TUN, Mesh/device destinations via Cloudflare One Traffic only; Android public proxy egress is independently cellular-owned and fail-closed.
- Issue #27 — bounded pre-Android Windows acceptance; MASQUE is primary and Cloudflare One WireGuard is only a concrete-defect fallback.
- `docs/testing/E4_FULL_STACK.md` — later physical proof for the real Android Mesh proxy endpoint, cellular DNS/egress, browser compatibility and selected-app fail-closed behavior.

## Test/evidence navigation

- `docs/architecture/ACCEPTANCE.md` — E1/E2/E3/E4 evidence domains and readiness/acceptance separation.
- `docs/testing/E3_PHYSICAL_CELLULAR.md` — executable physical Cellular Egress acceptance protocol for the current PRODUCT mechanism; old bind-based RC/harness evidence cannot satisfy the revised root-policy acceptance path.
- `docs/testing/E4_FULL_STACK.md` — future Windows/Cloudflare/Mesh/Kameleo/Camoufox full-stack contract.
- `.github/workflows/e3-physical-cellular.yml` — manual self-hosted E3 runner workflow; the workflow/harness must match the accepted PRODUCT mechanism before a future run may claim E3 PASS.

## Non-authority rule

Do not turn this index, README text, CI logs, test summaries, generated artifacts or chat handoffs into a mutable product-state authority. The project law remains:

```text
one fact -> one natural owner -> one write path -> one observation path
```
