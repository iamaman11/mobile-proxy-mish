# GitHub source-of-truth map

Status: **STABLE RECONSTRUCTION ENTRYPOINT**.

GitHub is the only durable source of truth. Chat handoffs, copied status summaries, old issue comments and local notes are never authoritative substitutes for a fresh repository baseline.

## Single accepted source of truth

Protected `main` is the latest accepted PRODUCT + CONTROL + canonical-documentation boundary.

```text
protected main
  = latest accepted PRODUCT source
  + latest accepted CONTROL/workflow/LAB source
  + canonical architecture/process documentation
```

A feature or implementation branch is a **candidate**, not a second accepted PRODUCT source. It becomes accepted only after its required hosted/physical evidence passes and the change is merged to `main`.

Issue #135 is the single live checkpoint pointer. It owns the current roadmap stage, current open implementation PR when one exists, and immutable evidence identifiers. It does not define a second long-lived source tree.

Issue #134 is historical research/rationale only.

## Fresh reconstruction procedure

Before planning, diagnosis or mutation:

1. read fresh protected `main` and record its exact SHA as `ACCEPTED_MAIN_SHA`;
2. read this file from that exact `main`;
3. read `docs/architecture/PRODUCT_ROADMAP.md` from the same `main`;
4. read fresh Issue #135 for `CURRENT_STAGE`, `OPEN_IMPLEMENTATION_PR` and immutable evidence ids;
5. if an implementation PR is open, inspect its exact head only for the candidate change currently under review;
6. read only the natural-owner contracts and executable workflows/tests needed for the active slice;
7. if a physical fact is required, use the exact immutable evidence already recorded or obtain one new bounded physical observation.

One fresh baseline opens one bounded mutation window. Do not re-baseline after every write inside that same window.

## Identity and evidence rule

For accepted repository facts:

```text
ACCEPTED_PRODUCT_SHA = protected main SHA
ACCEPTED_CONTROL_SHA = protected main SHA
```

During a pre-merge physical candidate cycle, provenance may intentionally contain two identities:

```text
PRODUCT_SHA = exact candidate PR head being exercised
CONTROL_SHA = exact protected-main workflow/LAB implementation executing the cycle
DEVICE_EVIDENCE = immutable observation tied to both
```

That provenance split is temporary evidence bookkeeping. It does **not** create two accepted product sources. After the candidate is accepted and merged, protected `main` again contains the accepted PRODUCT and CONTROL state together.

Never infer physical state from source code, and never infer current PRODUCT architecture from historical processes/files found on a development phone.

## Canonical product architecture

Core law:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Current Android PRODUCT shape:

```text
Android / Kotlin
  thin platform/composition/effect/projection boundary
        |
        v
thin UniFFI
        |
        v
Rust / mish-runtime
  one runtime generation/lifecycle owner
  one Tokio listener/session/task tree
  terminal health/failure/recovery ownership
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
- Tokio owns runtime execution; do not add Hyper/Tonic or another framework without a concrete requirement;
- Cloudflare One Agent is the only Android VPN/VpnService owner;
- public target DNS and sockets use only current Cellular Egress authority;
- no Wi-Fi/default/WARP public-egress fallback;
- one process-wide persistent Magisk `su` transport with authority cached per live shell generation;
- root operations are narrow typed effects, not a generic privileged RPC/control plane;
- Android/Kotlin does not become a second runtime/readiness/recovery owner.

Historical `/data/adb/mobile-proxy-node` / sing-box residue is LAB hygiene only. It must never re-enter PRODUCT startup or recovery semantics.

## Development process

Normal development is short-lived branch -> acceptance -> `main`:

```text
fresh main
 -> one bounded owner-aligned slice branch / PR to main
 -> exact-head hosted PRODUCT gate when PRODUCT inputs change
 -> immutable candidate artifact
 -> explicit post-analysis /mish-cycle only when a physical fact is required
 -> exact artifact install/verification
 -> typed evidence
 -> STOP_FOR_ANALYSIS
 -> merge accepted change to main
```

No successful build, merge, artifact publication or CI completion automatically mutates DEVICE-1.

The Windows LAB is an exact-artifact consumer/evidence executor, not a normal Android PRODUCT builder.

`Device Cycle` is the executable authority for supported modes/probes. If prose disagrees with executable workflow, correct the prose or workflow immediately rather than carrying an unwritten exception.

Development debug candidates may establish exact stage-specific physical facts, but they are not external-distribution identity. There is no current RC/prerelease/promotion path. If a future distribution requirement is introduced, `RELEASE.md` remains the single authority for that identity and must reuse the existing exact source/build/physical lineage rather than create a parallel development authority.

## U8 support/provenance reconstruction

Support reconstruction is evidence composition, not a new runtime or database. Start from fresh
protected `main` and Issue #135, then bind only the immutable identities needed by the claim:

```text
ACCEPTED_MAIN_SHA
PRODUCT_SHA / CONTROL_SHA when candidate evidence intentionally differs
HOSTED_RUN_ID + artifact id/digest when bytes were consumed
DEVICE_CYCLE_RUN_ID
installed digest/signing identity when installation is part of the claim
typed result/classification + the smallest relevant observations
```

Existing GitHub checks/artifacts plus typed PRODUCT diagnostics are the support packet. Do not add a
mutable support registry, duplicate readiness store, unbounded log bundle or second release pointer.

## Local-agent rule

The local/Windows agent is a bounded physical diagnostic executor, not a second architecture or state authority.

Use it only when source/CI/current Device Cycle cannot establish a material physical fact. Give one exact question, the smallest necessary read-only scope by default, explicit allowed mutations when required, and a fixed evidence format. Persist the sanitized conclusion in GitHub when it materially affects the roadmap/checkpoint.

## Conflict rule

If durable sources disagree:

1. exact executable source/workflow defines mechanics for its SHA;
2. `PRODUCT_ROADMAP.md` defines ordered product direction;
3. #135 defines the live stage / open PR / immutable evidence ids;
4. accepted PRODUCT + CONTROL composition comes from protected `main`;
5. SYSTEM / DEPENDENCIES / OWNERSHIP define architecture contracts;
6. EXECUTION / DEVELOPMENT_PIPELINE / ACCEPTANCE / LAB PLAN define process;
7. older issue/comment prose is historical unless explicitly re-adopted.

When a contradiction is found, correct GitHub immediately.