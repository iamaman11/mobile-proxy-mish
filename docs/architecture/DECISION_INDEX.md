# Architecture decision index

This file is navigation only. It is not a second live-status system.

## Current authorities

- `docs/architecture/SOURCE_OF_TRUTH.md` — stable reconstruction and conflict-resolution entrypoint.
- Issue #135 — single live execution/checkpoint pointer: current roadmap stage, working lineage, exact implementation pointer and immutable evidence ids.
- `docs/architecture/PRODUCT_ROADMAP.md` — canonical ordered PRODUCT/architecture plan.
- `AGENTS.md` — executor startup and bounded-work policy.
- `docs/architecture/SYSTEM.md` — canonical current system topology.
- `docs/architecture/OWNERSHIP.md` — natural-owner map.
- `docs/architecture/DEPENDENCIES.md` — dependency direction and minimal-layer invariant.
- `docs/architecture/CONTRACTS.md` — serialization/interface boundary rules.
- `docs/architecture/EXECUTION.md` — stable implementation/integration policy.
- `docs/architecture/DEVELOPMENT_PIPELINE.md` — hosted exact-head candidate + explicit Device Cycle contract.
- `docs/architecture/ACCEPTANCE.md` — evidence levels and development-vs-formal acceptance.
- `docs/architecture/RELEASE.md` — immutable RC/release identity and promotion.
- `docs/lab/PLAN.md` — physical LAB execution boundary.

Issue #134 is historical research/rationale. It does not own current stage order after `PRODUCT_ROADMAP.md` superseded that role.

## Current architecture law

```text
one fact -> one natural owner -> one write path -> one observation path
```

Current Android PRODUCT is one in-process Rust proxy data plane. Android/Kotlin is the thin platform/effect/projection boundary. `mish-runtime` owns Tokio runtime execution/lifecycle; `mish-proxy` owns protocol/auth/target semantics; Cellular Egress owns cellular admission/currentness/exact-network DNS/socket authority.

Cloudflare One Agent is the only Android VPN/VpnService owner. Android PRODUCT has no sing-box runtime/compatibility/migration/process-management path. Historical phone residue is LAB hygiene only.

## PRODUCT vs CONTROL vs DEVICE

```text
PRODUCT_SHA
  exact current application implementation/build identity

CONTROL_SHA
  protected-main workflow/LAB/diagnostic identity

DEVICE_EVIDENCE
  immutable physical observation tied to explicit provenance
```

Protected `main` may lag current PRODUCT implementation during an active roadmap stage. Use Issue #135 to resolve the accepted working-lineage/current PRODUCT head before reasoning about application composition.

## Android development delivery

Supported floor:

```text
Android 11 / API 30
armeabi-v7a
```

Stable mechanics:

```text
Integration Android Preflight
  -> exact-head hosted build/test/candidate producer

Device Cycle
  -> explicit protected-main physical consumer/orchestrator
  -> exact artifact/provenance verification
  -> adb install -r when requested
  -> installed-byte/signature verification
  -> launch/current-L8 diagnostics/current-function probe
  -> STOP_FOR_ANALYSIS
```

The executable workflow `.github/workflows/device-cycle.yml` owns the supported Device Cycle command/mode/probe vocabulary. There is no separate `device-candidate-physical.yml` normal path.

No successful build/merge/artifact automatically starts the phone.

## Development physical evidence vs release acceptance

Exact-head debug candidates may establish stage-specific physical facts when #135 records the exact provenance. They are not release identity and cannot be promoted.

Formal release acceptance remains:

```text
PIN -> BUILD ONCE -> HASH -> SIGN -> ATTEST -> TEST EXACT BYTES -> PROMOTE EXACT BYTES
```

under `RELEASE.md`.

## Historical material

Older issues, branches, E3/E4 protocols and comments remain useful history/evidence, but they do not override the current authority map. Before reusing an older physical/test protocol, verify that it matches the current native topology and active roadmap stage.

## Non-authority rule

Chat handoffs, copied CI summaries, README prose, generated artifacts and this index never own mutable live stage status. Always reconstruct from fresh GitHub using `SOURCE_OF_TRUTH.md` and #135.
