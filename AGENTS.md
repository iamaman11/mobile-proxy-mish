# Executor policy

GitHub is the only durable source of truth. Chat handoffs, copied status text, CI summaries and generated artifacts are not substitutes for a fresh GitHub baseline.

## Required startup baseline

Before planning or mutating:

1. read fresh protected `main` and record its exact SHA;
2. read `docs/architecture/SOURCE_OF_TRUTH.md` from that exact `main`;
3. read `docs/architecture/PRODUCT_ROADMAP.md` from the same `main`;
4. read fresh Issue #135 for the current stage, open implementation PR if any, and immutable evidence ids;
5. inspect an open PR exact head only for the candidate change currently under review;
6. read only the natural-owner contracts, implementation files and executable workflows/tests required by the active slice;
7. distinguish accepted source facts from candidate evidence and physical DEVICE evidence.

One fresh baseline opens one bounded mutation window. Do not re-baseline after every write inside that window.

Issue #134 is historical research/rationale. Issue #135 is the single current execution/checkpoint pointer. `PRODUCT_ROADMAP.md` owns ordered stage direction.

## Product engineering rule

```text
concrete product/operator problem
 -> smallest safe change or smallest missing measurement
 -> measurable result
 -> preserved invariants
 -> stop condition
```

Prefer NO CHANGE when the accepted requirement is already met. Do not introduce a framework, daemon, generic shell API, second owner, second control plane or refactor merely because it is possible.

## Accepted-source rule

Protected `main` is the latest accepted PRODUCT + CONTROL + canonical-documentation boundary.

A feature/slice branch is temporary candidate work. It does not become a second accepted PRODUCT source. Accepted work is merged back to `main` promptly after the required evidence passes.

For accepted repository facts:

```text
ACCEPTED_PRODUCT_SHA = protected main SHA
ACCEPTED_CONTROL_SHA = protected main SHA
```

For an explicit pre-merge physical cycle only:

```text
PRODUCT_SHA = exact candidate PR head
CONTROL_SHA = exact protected-main Device Cycle/control implementation
DEVICE_EVIDENCE = immutable observation tied to both
```

That split is provenance, not durable source-of-truth separation.

## Architecture law

Preserve:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Current PRODUCT is one in-process Rust proxy data plane with one `mish-runtime`/Tokio execution owner. Android/Kotlin is the thin platform/composition/effect/projection boundary. Proxy protocol/auth/target semantics live in `mish-proxy`; Cellular Egress owns current cellular admission/currentness and exact-network DNS/socket authority.

Do not introduce:

- Android sing-box PRODUCT runtime or legacy proxy compatibility/migration/process management;
- a second Android VPN/TUN;
- a second Cellular Egress, Runtime Lifecycle or Readiness owner;
- Kotlin health/recovery supervision that duplicates Rust ownership;
- a generic root shell/control API or root daemon/helper;
- whole-UID/default-route public egress policy;
- Wi-Fi/default/WARP public-egress fallback;
- a mutable runtime/LAB status database;
- false PASS from weaker or stale evidence.

Tokio belongs to runtime execution. Hyper/Tonic or another framework is not added without a demonstrated product requirement.

## Slice and PR rule

A normal implementation slice:

- begins from fresh protected `main`;
- changes one natural owner plus at most one necessary adapter/composition boundary;
- includes direct tests for that boundary;
- targets `main` unless the current roadmap explicitly defines a temporary exceptional base;
- is merged to `main` once the required evidence passes.

Do not keep accepted PRODUCT changes indefinitely on a parallel integration branch merely to record progress.

## CI and candidate production

`docs/architecture/DEVELOPMENT_PIPELINE.md` is the stable development-delivery contract. Executable workflows are the mechanical authority if prose and YAML disagree.

Supported PRODUCT floor:

```text
Android 11 / API 30
armeabi-v7a
```

PRODUCT-changing PRs to `main` must run the exact-head hosted Android/Rust gate and may publish an immutable debug candidate artifact for explicit physical validation.

A successful hosted build is a prerequisite only. It never starts DEVICE-1 automatically.

## DEVICE-1 rule

Physical development cycles are explicit post-analysis actions through the protected-main `Device Cycle` workflow.

Normal shape:

```text
exact successful hosted PRODUCT candidate
 -> explicit /mish-cycle request
 -> verify PRODUCT_SHA + CONTROL_SHA + producer policy + artifact provenance
 -> Windows LAB consumes exact artifact
 -> adb install -r when requested
 -> verify installed exact bytes/signing identity
 -> launch/read-only diagnostic or explicitly named current-function probe
 -> evidence
 -> STOP_FOR_ANALYSIS
```

Do not locally rebuild the APK on the physical runner in the normal path. Do not uninstall as an upgrade mechanism. Do not automatically repair, probe again or start another cycle after a result.

The current supported Device Cycle modes/probes are defined by `.github/workflows/device-cycle.yml`; never rely on an old handoff for that vocabulary.

## Evidence law

```text
E1 < E2 < E3 < E4
```

Weaker evidence cannot close a stronger claim.

An exact-head debug candidate can establish a stage-specific physical development fact when #135 explicitly records that evidence. It is not formal release identity and cannot be promoted as RC/release bytes.

Formal release/promotion follows `docs/architecture/RELEASE.md`.

Do not persist secrets, raw public IPs, unrelated logcat, device identifiers or credential material in durable evidence.

## Local-agent rule

When the next decision depends on a real physical fact that source/hosted CI/current Device Cycle cannot establish, request the smallest bounded local-agent diagnostic.

The local agent is a physical executor, not a second architecture or state authority. Prefer read-only scope, define exact output, and write the sanitized conclusion back to #135 or the appropriate owner/evidence surface when it materially affects the plan.

## Physical uncertainty

Do not guess DEVICE-1, Magisk/root, RPDB, Cloudflare/provider, carrier, process, socket or resource facts from source code. Measure the exact missing fact and stop.
