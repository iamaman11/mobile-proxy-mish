# GitHub source-of-truth map

Status: **STABLE RECONSTRUCTION ENTRYPOINT**.

This file contains no live stage SHA or mutable status. It exists so a new executor can reconstruct the project after total chat/context loss using GitHub only.

## Durable authority order

```text
protected main
  -> this file: stable authority/reconstruction rules
  -> docs/architecture/PRODUCT_ROADMAP.md: ordered PRODUCT/architecture plan
  -> Issue #135: current stage + explicit CONTROL/PRODUCT identities + immutable evidence ids
  -> PRODUCT_SOURCE_SHA / current slice PR named by #135: current PRODUCT implementation
  -> SYSTEM.md / DEPENDENCIES.md / OWNERSHIP.md: architecture contracts
  -> DEVELOPMENT_PIPELINE.md / EXECUTION.md / ACCEPTANCE.md: development/evidence process
  -> docs/lab/PLAN.md: physical execution boundary
  -> executable workflows/tests/guards: exact mechanical contract
```

Issue #134 is historical research/rationale. It may explain why a decision was made, but it does not own current stage ordering after `PRODUCT_ROADMAP.md` supersedes it.

Historical issue comments, chat handoffs, copied CI summaries and device notes are evidence/history only. They never override the authorities above.

## Fresh reconstruction procedure

Before planning, diagnosis or mutation:

1. Read fresh protected `main` and record its SHA as `CONTROL_SHA_BASELINE`.
2. Read this file from that exact `main`.
3. Read fresh Issue #135 and resolve its reconstruction identity block.
4. Verify `CONTROL_MAIN_SHA` in #135 matches the fresh protected-main SHA or explicitly update #135 before proceeding.
5. Resolve `PRODUCT_SOURCE_REF`, `PRODUCT_SOURCE_SHA`, `PRODUCT_ON_PROTECTED_MAIN`, `CURRENT_STAGE`, `OPEN_IMPLEMENTATION_PR` and `CURRENT_PRODUCT_CANDIDATE_SHA` from #135.
6. If `PRODUCT_ON_PROTECTED_MAIN = NO`, do **not** inspect protected-main Rust/Android source to determine current PRODUCT composition. Read `PRODUCT_SOURCE_SHA` first.
7. Read `PRODUCT_ROADMAP.md` from protected `main` for stage ordering and architecture direction.
8. Inspect the exact PRODUCT source/current PR before making any claim about PRODUCT composition.
9. Read only the natural-owner contracts and executable workflow/tests needed for the active slice.
10. If a physical fact is required, use immutable run/evidence ids from #135 or obtain one new bounded physical observation.

One fresh baseline opens one bounded mutation window. Do not re-baseline after every write performed inside that same window.

## Required live pointer schema in Issue #135

Issue #135 must keep these semantic roles explicit even when compatibility aliases are also retained:

```text
CONTROL_MAIN_SHA
  exact protected-main identity for control/process/canonical docs

PRODUCT_SOURCE_REF
  branch/ref containing the current accepted PRODUCT implementation lineage

PRODUCT_SOURCE_SHA
  exact source tree that defines current PRODUCT composition

PRODUCT_ON_PROTECTED_MAIN = YES|NO
  whether protected main and current PRODUCT source are intentionally the same implementation boundary

CURRENT_PRODUCT_CANDIDATE_SHA
  exact build-source identity physically exercised by the currently recorded candidate evidence
```

Compatibility aliases such as `PROTECTED_MAIN`, `WORKING_LINEAGE`, `ACCEPTED_INTEGRATION_HEAD`, and `ACCEPTED_PRODUCT_CANDIDATE_SHA` may remain for existing automation/history, but they do not replace the explicit semantic names above.

Reconstruction is **fail closed** if any required role is missing or contradictory. Fix #135 before making PRODUCT claims or mutations.

### Critical branch rule

`main` has two possible roles depending on #135:

```text
PRODUCT_ON_PROTECTED_MAIN = YES
  protected main may be used as both CONTROL and current PRODUCT source

PRODUCT_ON_PROTECTED_MAIN = NO
  protected main is CONTROL/process/canonical-docs only for current reconstruction
  current PRODUCT composition MUST be read from PRODUCT_SOURCE_SHA
```

Therefore old Rust/Android code, dependencies, build guards, or historical vendor checks still present on `main` do not become current PRODUCT facts merely because they are on the protected branch. Likewise, a docs/control merge to `main` never implies that an unmerged PRODUCT lineage has been accepted into `main`.

## Three authority namespaces

Never mix these:

```text
PRODUCT_SHA
  exact source/build identity used to reason about application composition and PRODUCT behavior

CONTROL_SHA
  protected-main identity whose workflow/LAB/diagnostic orchestration is executing

DEVICE_EVIDENCE
  one immutable physical observation/run tied to explicit PRODUCT_SHA + CONTROL_SHA provenance
```

Rules:

- Do not infer PRODUCT composition from protected `main` when #135 says `PRODUCT_ON_PROTECTED_MAIN = NO`.
- Do not infer PRODUCT architecture from historical processes/files found on a development phone.
- Do not infer current physical state from source code.
- Do not promote a successful read-only probe into exact PRODUCT acceptance.
- Do not silently substitute `CONTROL_SHA` for `PRODUCT_SHA`, even when both are Git commit SHAs.

## Canonical product architecture

Core law:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Current Android PRODUCT shape:

```text
Android/Kotlin
  thin platform/composition/effect/projection boundary
        |
        v
thin UniFFI
        |
        v
Rust / mish-runtime
  one runtime generation/lifecycle owner
  one Tokio listener/session/task tree
  terminal health/failure and recovery ownership
        |
        +--> mish-proxy: protocol/auth/target semantics
        +--> Cellular Egress: admission/currentness/exact-network DNS/socket authority
        +--> Transport/Mesh owner
        +--> Readiness pure projection
        +--> Credentials owner
        `--> narrow Android/root/network effects
```

Stable invariants:

- one in-process Rust proxy data plane;
- no Android external proxy child process;
- no Android sing-box PRODUCT dependency, compatibility runtime, migration state, process scan or kill path;
- Tokio belongs to runtime execution; do not add Hyper/Tonic or another framework without a concrete requirement;
- Cloudflare One Agent is the only Android VPN/VpnService owner;
- public target DNS and sockets use only current Cellular Egress authority;
- no Wi-Fi/default/WARP public-egress fallback;
- one process-wide persistent Magisk `su` transport with authority cached per live shell generation;
- root operations are narrow typed effects, not a generic privileged RPC/control plane;
- Android/Kotlin does not become a second runtime/readiness/recovery owner.

Historical Android `/data/adb/mobile-proxy-node` / sing-box residue is LAB hygiene only. If present on a development phone it is diagnosed/cleaned outside PRODUCT; it must never re-enter PRODUCT startup semantics.

## Development process

Current development delivery shape:

```text
bounded PRODUCT slice
 -> integration PR/head on the working lineage named by #135
 -> exact-head Integration Android Preflight
 -> immutable debug candidate artifact
 -> explicit post-analysis /mish-cycle request when a physical fact is required
 -> protected-main Device Cycle consumes exact artifact
 -> install -r + installed-byte/signature verification
 -> launch/read-only diagnostics/current-function probe as requested
 -> typed evidence
 -> STOP_FOR_ANALYSIS
```

No successful build, merge, artifact publication or CI completion automatically mutates DEVICE-1.

`Device Cycle` is the executable authority for currently supported modes/probes. Prose must be corrected if it disagrees with the workflow.

Development exact-head debug candidates may establish stage-specific physical facts when #135 explicitly records them. They are not formal RC/release identity and cannot be promoted as release bytes.

Formal release promotion remains governed by `RELEASE.md` and immutable build-once/hash/sign/attest/test/promote semantics.

## Local-agent rule

The local/Windows agent is a bounded physical diagnostic executor, not a second architecture or product-state authority.

Use it only when source/CI/current Device Cycle cannot establish a material physical fact. Give one exact question, smallest necessary read-only scope by default, explicit allowed mutations when required, and a fixed evidence format. Write the sanitized conclusion back to #135 or the appropriate natural-owner contract/evidence surface.

## Conflict rule

If documents disagree:

1. executable source/workflow defines mechanics for its own exact SHA;
2. `PRODUCT_ROADMAP.md` defines ordered product direction;
3. #135 defines the live stage and explicit CONTROL/PRODUCT/evidence identities;
4. PRODUCT composition comes only from `PRODUCT_SOURCE_SHA` resolved from #135;
5. SYSTEM/DEPENDENCIES/OWNERSHIP define architecture contracts;
6. EXECUTION/DEVELOPMENT_PIPELINE/ACCEPTANCE/LAB PLAN define process;
7. older issue/comment prose is historical unless explicitly re-adopted.

When a contradiction is found, correct GitHub immediately rather than carrying an unwritten exception in chat memory.
