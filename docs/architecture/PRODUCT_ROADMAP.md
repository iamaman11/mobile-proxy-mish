# MISH Product Roadmap

Status: **CANONICAL PRODUCT / ARCHITECTURE ROADMAP**.

This document is the single ordered development plan for Mobile Proxy MISH. It supersedes stage ordering embedded in old issue bodies/comments when later accepted architecture changed the implementation. GitHub issues remain useful for history and execution pointers, but they must not define a competing roadmap.

Authority order:

```text
PRODUCT_ROADMAP.md                 -> ordered product plan and supersession
Issue #135                         -> current stage / exact execution pointer only
stage-specific issue/PR            -> bounded implementation/evidence only
SYSTEM.md / DEPENDENCIES.md         -> accepted architecture
EXECUTION.md / ACCEPTANCE.md        -> process/evidence rules
Issue #134                         -> historical research/rationale archive + roadmap pointer
```

## Product goal

MISH is an industrial rooted-Android mobile proxy appliance that is simple to operate and safe to upgrade/reinstall:

- one in-process Rust proxy data plane;
- one Cellular Egress owner;
- one Runtime Lifecycle owner;
- exact-network cellular DNS and public sockets only;
- Cloudflare One Agent remains the only Android VPN owner;
- one process-wide persistent Magisk `su` transport, with authority cached per live shell generation;
- narrow typed root effects above that transport; no generic shell/control API and no root daemon/helper;
- normal replacement install through `adb install -r`, stable signer/UID, no repeated Magisk prompt after the existing grant;
- bounded fail-closed recovery without Wi-Fi/default/WARP fallback;
- backend-owned product state with a thin Android platform/UI boundary;
- deterministic delivery, physical evidence and release promotion.

Core law:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Do not introduce a second lifecycle/readiness/cellular owner, a generic root command API, a root daemon, a second VPN/TUN, a mutable status database, a fallback public-egress path, or a generic plugin/framework layer without a demonstrated product requirement.

## Accepted foundation

The following foundation is already accepted and is not reopened without contrary evidence:

1. Android 11 / API 30, `armeabi-v7a`, pinned Android/Rust/NDK delivery contract.
2. Exact-head hosted candidate production and Windows LAB as artifact consumer by default.
3. Persistent process-wide Magisk shell semantics; terminal grant/denial is not repeatedly polled within one app process. Magisk + one persistent `su` shell remains the minimal platform privilege boundary unless physical evidence proves a simpler supported mechanism; do not replace it with a root daemon/helper or run the whole application as root merely to remove `su`.
4. Exact stale MISH-owned root-policy identity may self-heal only when the complete known PRODUCT contract is proven; foreign/malformed state stays fail-closed.
5. Canonical external capacity is 64 accepted sessions with deterministic overload rejection.
6. Rust Proxy Serving L1-L7: HTTP CONNECT, SOCKS5, mixed ingress, authentication, unresolved-target preservation, relay, bounded capacity and atomic Android cutover to in-process native listeners.

Historical evidence remains evidence, not a reason to retain mechanisms that no longer exist.

---

# U1 — L8 Architecture Closure — COMPLETED

Accepted implementation: PR #192, integration merge `3a92cc8105737e7bf515e23a0dbf201da2516730`.

L8 establishes the one-way native architecture:

- one owned Tokio listener/session execution tree inside `mish-runtime` for native Proxy Serving;
- blocking handshake + exact-network DNS/connect behind one bounded blocking seam;
- long-lived relay async and owned/drained deterministically;
- direct root-policy-gated Cellular Egress; no private SOCKS bridge;
- no PRODUCT sing-box crate/vendor/materializer/APK bytes/root child lifecycle;
- native `ProxyServingLifecycle` and typed native failures;
- diagnostics v2 with native facts only;
- recovery classification/backoff, Mesh serving eligibility and readiness structural eligibility owned in Rust;
- root authority proof separated from the one process-wide persistent `su` transport;
- architecture constitution prevents regression to removed topology.

U2 physical evidence subsequently exposed one incomplete closure item: pre-L8 sing-box upgrade/process compatibility had survived in PRODUCT startup semantics. That compatibility is **not** part of L8 and is removed in U2 rather than hardened. L8 PRODUCT has no fallback, migration, process scan, marker or failure state for the deleted Android sing-box architecture.

---

# U2 — Native DEVICE-1 Acceptance and physical re-baseline — ACTIVE

This is the first authoritative physical baseline for the final direct native topology. Old resource numbers and process identities from the sing-box/private-bridge/thread-per-session architecture are not current-product truth.

Use the exact hosted candidate only and normal replacement install:

```text
adb install -r
no clean uninstall
stable signing identity / UID
existing Magisk grant remains sufficient
```

Pre-L8 PRODUCT compatibility rule:

- PRODUCT does not scan, classify, stop, migrate or otherwise manage historical Android sing-box processes/files;
- PRODUCT startup is determined only by current L8 owners and current native effects;
- historical processes/files left on a development phone are LAB residue, not PRODUCT state;
- if LAB residue physically conflicts with current listeners or routing, it is cleaned as an explicit bounded LAB-maintenance action and never becomes an application startup dependency or fallback mechanism.

## U2 execution refinement — converge Mesh ingress onto the one Tokio executor

Current `mish-transport` correctly owns the external Mesh boundary, exact admitted endpoint/epoch, the canonical external capacity of 64 sessions and deterministic overload rejection. That policy ownership remains in `mish-transport`.

Current implementation still executes Mesh ingress with a separate `std::net` / `std::thread` concurrency subsystem: listener threads plus per-session blocking relay threads. This is a known current-topology implementation split, not the target resource/lifetime model for final U2 acceptance.

Begin this convergence immediately in U2. The already-requested upstream-lifetime attribution for the inconclusive `example.com:443` hold-open experiment is an independent read-only evidence task: it does **not** block implementation of the accepted Tokio convergence, but it must be resolved before the next final physical capacity/resource acceptance so the harness itself cannot recreate the same ambiguity.

Before final 64/65 capacity and resource acceptance:

1. move Mesh listener/session execution onto the existing process-wide Tokio runtime owned by `mish-runtime`;
2. keep `mish-transport` as the natural owner of Mesh admission, admission epoch, external capacity=64 and reject-at-edge semantics;
3. do **not** add another Tokio runtime/executor, move external capacity policy into `mish-runtime`, or create a second session/lifecycle owner;
4. replace thread-per-session relay with owned async tasks / async bidirectional relay and deterministic cancellation/drain;
5. preserve the current external contract and owner-backed diagnostics (`mesh.active_sessions`, `proxy.active_sessions`);
6. adapt only tests/guards that encode the old thread implementation; protocol/auth/real-Mesh black-box acceptance remains the same contract;
7. resolve the independent upstream-lifetime attribution and make the final capacity fixture protocol-valid and deterministically long-lived before rerunning DEVICE-1 capacity;
8. rerun exact hosted gates and record a **fresh** physical idle/10/32/64/overflow/post-cleanup resource baseline after convergence. Pre-convergence thread/resource numbers remain diagnostic evidence only and cannot close final U2 resource acceptance.

Target execution/ownership split:

```text
mish-runtime
  -> one process-wide Tokio runtime / cancellation tree
       -> Mesh ingress/session tasks     [policy owner: mish-transport]
       -> native Proxy Serving tasks     [protocol owner: mish-proxy]
       -> async relays
            -> Cellular Egress           [egress owner: mish-cellular/runtime boundary]

mish-transport retains:
  exact Mesh endpoint + admission epoch
  external session budget = 64
  deterministic overload rejection at the Mesh edge
```

The reason for doing this inside U2 rather than after it is evidence validity: accepting thread/FD/RSS/PSS at 64 on a thread-per-session Mesh implementation and then replacing that implementation immediately afterward would invalidate the physical baseline U2 is supposed to establish.

Prove on DEVICE-1 after the Mesh/Tokio convergence:

- current native runtime starts without any pre-L8 process/migration prerequisite;
- PRODUCT creates zero external/root proxy child processes in steady state;
- HTTP CONNECT, SOCKS5 and mixed ingress function through the real current path;
- correct authentication succeeds, wrong authentication is rejected, and relay is bidirectional;
- public target DNS occurs only through the exact Cellular owner and public sockets use the root-policy-gated cellular path;
- no Wi-Fi/default/WARP fallback during uncertainty/loss;
- 64 accepted full paths and deterministic rejection of the 65th external session at the `mish-transport` edge;
- a bounded overflow burst beyond 65 does not increase accepted owner counts, evict existing sessions or destabilize the runtime;
- stop/start/restart and cellular loss/recovery are bounded and fail closed;
- stable signer/UID and no repeated Magisk prompt on normal replacement install;
- one process-wide root shell is reused through repeated root-policy reads/reconciliations within the app process instead of creating one `su` process per command/recovery event;
- process restart establishes a fresh shell generation while the already-granted Magisk policy remains sufficient and does not require another interactive grant;
- repeated recovery cycles do not reopen Magisk prompts or create unbounded root-shell/process growth;
- fresh post-convergence baseline/peak/post-cleanup thread count, FD count and RSS/PSS at idle / 10 / 32 / 64 sessions;
- startup, failure-to-fresh-READY, normal stop and recovery timings.

DEVICE-1 diagnostics are current-product health diagnostics. Canonical acceptance observes current runtime, Cellular, root authority/policy, native Proxy Serving, credentials, Mesh, readiness and functional E2E behavior. Historical sing-box PID/config identity is not a current PRODUCT health fact.

Exit: exact native topology, including one process-wide Tokio execution model for long-lived Mesh + Proxy session work, is physically proven and the current resource/recovery baseline is recorded without secret/raw-IP leakage. The Magisk/su privilege boundary is considered physically accepted only after the replacement-install, restart and repeated-recovery evidence above passes.

---

# U3 — Recovery, observability and lifetime convergence

Only current-topology findings survive into this stage. Implement from evidence, not from historical mechanism assumptions.

Still-live questions from #134/S0:

- latest-state/coalesced Android reconciliation where callback backlog can delay the newest generation;
- cleanup must supersede stale queued reconciliation rather than wait behind arbitrary backlog;
- Android network-scoped DNS worker occupancy/cancellation under a stuck `android_getaddrinfofornetwork` call;
- root-policy reconcile command count / duplicate snapshots / elapsed time;
- one end-to-end startup/recovery/stop latency budget with per-stage observations;
- long-effect lock scope only where direct tests prove exact identity remains safe;
- readiness behavior for a silent upstream public-path failure that leaves structural facts unchanged;
- bounded diagnostics for generations, recovery attempt/backoff, coalescing, root timing/count, DNS occupancy/rejects, capacity rejects and lifecycle durations;
- after U2 proves the persistent Magisk boundary on DEVICE-1, remove the remaining shell-shaped internal API form such as `RootProcess.run(["su", "-c", command])` and expose narrow typed root effects instead, while retaining exactly one persistent `ProcessBuilder("su")` transport underneath;
- the typed-root cleanup must preserve serialized execution, bounded output/deadlines, shell-generation authority invalidation, no automatic mutation replay after transport uncertainty, and fail-closed policy verification;
- do not replace this cleanup with a generic privileged RPC service, root daemon/helper, second privilege state machine, or whole-app root execution.

Superseded by the native cutover and **not** carried forward as work items:

- sing-box child launch/PID/config lifecycle optimization;
- private Cellular SOCKS bridge lifetime/resources;
- old four-thread-per-full-path estimate spanning Mesh + private bridge;
- stale private-bridge 16-session stress fixture;
- duplicate Kotlin proxy recovery allow-lists after Rust becomes the canonical policy owner.

Optimization is accepted only when U2/U3 evidence demonstrates a real constraint.

---

# U4 — Generation-bound Public Egress IP

Add one bounded public-IP observation through the exact PRODUCT cellular path.

Ownership:

```text
Cellular Egress -> current generation-bound public egress IP observation
Rotation        -> before/after observations and terminal comparison
UI              -> projection only
```

Requirements:

- exact-network cellular DNS + current root-policy authorization;
- HTTPS/TLS, absolute deadline and tiny bounded response;
- strict IP parsing;
- generation/currentness rejection after cellular change;
- no Android default/Wi-Fi/WARP fallback;
- one deliberately selected endpoint, not scattered service literals;
- raw public IP may be shown locally but is not persisted to logs/GitHub/analytics; durable evidence stores only changed/unchanged/failure.

---

# U5 — First-class IP Rotation

`crates/rotation` remains the natural owner. Android executes only the narrow airplane-mode effect.

One operation at a time:

```text
IDLE
 -> REQUESTED
 -> PREPARING
 -> AIRPLANE_ENABLING
 -> WAITING_RADIO_DOWN
 -> AIRPLANE_DISABLING
 -> WAITING_CELLULAR_RECOVERY
 -> RECONCILING_PRODUCT
 -> PROBING_PUBLIC_IP
 -> CHANGED | UNCHANGED | FAILED
```

Requirements:

- monotonic operation id and stale-completion rejection;
- fail-closed serving before/during cellular loss;
- narrow typed Android adapter: observe / enable / disable; no generic root command API;
- effective ON requires observed airplane ON plus cellular loss, not only shell exit 0;
- bounded best-effort restore to airplane OFF after any failure;
- fresh cellular generation -> fresh root policy -> native proxy/readiness -> public-IP probe;
- terminal result distinguishes IP changed, IP unchanged and failure;
- one bounded cycle per user request by default; no infinite retry-until-changed policy.

Physical capability proof on the supported rooted device is mandatory before PRODUCT acceptance.

---

# U6 — Backend-driven Product UI

Compose/Material 3 remains the UI stack. UI owns presentation state only.

Production dashboard:

- overall READY / DEGRADED / NOT READY / UNKNOWN;
- human-readable typed cause;
- current public IP and previous rotation IP;
- `Change IP` action driven by the Rotation owner;
- semantic rotation progress, never fake percentages;
- cellular / root policy / proxy / Mesh concise health;
- non-secret proxy endpoint/protocol information;
- advanced diagnostics collapsed by default;
- accessible light/dark UI, no status conveyed only by color, no secrets rendered.

Pure projection tests and Compose tests cover readiness states, IP known/unknown, first-use previous unknown, duplicate rotation prevention, changed/unchanged/failed rotation, root unavailable, cellular recovery, long text/accessibility and secret absence.

---

# U7 — Efficiency and long-run hardening

Measure the **current** direct native Tokio architecture, not deleted topology.

Evaluate:

- idle CPU/wakeup cost;
- Tokio Mesh accept/task scheduling, cancellation and drain behavior;
- native health observation cadence/cost;
- thread/FD/RSS/PSS headroom at 64 sessions;
- connect/DNS latency distribution;
- battery and thermal behavior;
- root reconcile round trips;
- root-shell lifetime/process count and command serialization overhead;
- long-lived relay cleanup and cancellation;
- repeated recovery/rotation cycles.

Keep simpler mechanisms when budgets are healthy. Do not add frameworks for hypothetical scalability.

---

# U8 — Production durability and release closure

Prove the appliance can remain operational across normal lifecycle events:

- app/process restart;
- device reboot and expected startup path;
- repeated `adb install -r` upgrades using the same signing identity;
- no repeated Magisk authorization after the existing grant unless Magisk itself revokes it;
- one persistent `su` transport remains bounded and replaceable on shell death without becoming a second privileged daemon/lifecycle;
- bounded recovery from cellular/provider loss;
- long soak with no unbounded FD/thread/task/memory growth;
- immutable RC/release bytes, formal release gates and rollback/recovery documentation;
- diagnostics/support bundle remains typed, bounded and secret-safe.

Exit: formal release acceptance on immutable bytes and accepted physical evidence.

---

## Single-pass execution rule

Development proceeds linearly through `U1 -> U2 -> ... -> U8` with **one current stage** and no parallel roadmap hierarchy.

Within a stage:

```text
fresh exact baseline
 -> complete all independent hosted/code work for the stage
 -> one exact-head full hosted gate
 -> use a physical/real-network gate only when the next required fact cannot be proven hosted
 -> record accepted evidence
 -> advance the single current-stage pointer
```

Do not open a planning issue for every subtask. A stage-specific issue exists only when it materially improves execution/evidence traceability. Issue #135 is the single current-stage pointer.

A failed gate does not create a new roadmap stage: fix only the surfaced defect on the same line and rerun the exact gate.

## Supersession rule

When old #134/#135 comments conflict with this document because architecture has since changed, this document defines the current order. Historical comments remain useful rationale/evidence but must not resurrect removed components or obsolete optimization targets.
