# Executor policy

GitHub is the only durable source of truth. Chat handoffs, copied status text, CI summaries and generated artifacts are not substitutes for a fresh GitHub baseline.

## Required startup baseline

Before planning or mutating:

1. read fresh protected `main`;
2. read `docs/architecture/SOURCE_OF_TRUTH.md`;
3. read fresh Issue #135;
4. read `docs/architecture/PRODUCT_ROADMAP.md` from protected `main`;
5. inspect the exact working/integration head and current slice PR named by #135, when one exists;
6. read only the natural-owner contracts, implementation files and executable workflows/tests required by the active slice;
7. distinguish PRODUCT source facts, CONTROL/process facts and DEVICE evidence.

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

## Authority separation

Always keep three identities separate:

```text
PRODUCT_SHA   -> exact application source/build identity
CONTROL_SHA   -> protected-main workflow/LAB/diagnostic identity
DEVICE_EVIDENCE -> immutable physical observation tied to explicit provenance
```

Do not infer PRODUCT composition from a stale control branch. Do not infer current architecture from historical device residue. Do not infer physical state from source code.

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

## Working lineage and slice rule

`main` is the protected control/process/canonical-documentation boundary and a milestone acceptance boundary; it is not a scratch branch and it may lag the current PRODUCT implementation while a roadmap stage is still active.

The current PRODUCT implementation lineage is the exact working/integration head recorded by #135.

A normal implementation slice:

- begins from that exact integration head;
- has one natural owner and at most one necessary adapter/composition boundary;
- includes direct tests for that boundary;
- targets the current integration branch named by #135, not `main`, unless #135 explicitly says otherwise.

Do not merge the working lineage to `main` merely to record progress. Docs/control changes whose only purpose is to keep the protected source-of-truth/process boundary accurate may land on `main` independently, but they must not imply that unmerged PRODUCT implementation is already on `main`.

## CI and candidate production

`docs/architecture/DEVELOPMENT_PIPELINE.md` is the stable development-delivery contract. Executable workflows are the mechanical authority if prose and YAML disagree.

Supported PRODUCT floor:

```text
Android 11 / API 30
armeabi-v7a
```

For integration PRs targeting the working lineage, `Integration Android Preflight` builds/tests the exact head and publishes a candidate only after the configured complete gate passes.

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

The local agent is a physical executor, not a second architecture or state authority. Prefer read-only scope, define exact output, and write the sanitized conclusion back to #135 or the appropriate owner/evidence surface.

## Physical uncertainty

Do not guess DEVICE-1, Magisk/root, RPDB, Cloudflare/provider, carrier, process, socket or resource facts from source code. Measure the exact missing fact and stop.
