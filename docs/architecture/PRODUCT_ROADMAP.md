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
- one process-wide Tokio execution owner for long-lived Mesh + Proxy work, while domain policy ownership remains split by capability;
- owner-bound/network-scoped cellular DNS plus ordinary PRODUCT-UID public sockets through the root-policy-gated current cellular route;
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

Do not introduce a second lifecycle/readiness/cellular owner, a second Tokio/runtime executor, a generic root command API, a root daemon, a second VPN/TUN, a mutable status database, a fallback public-egress path, or a generic plugin/framework layer without a demonstrated product requirement.

## Accepted foundation

The following foundation is already accepted and is not reopened without contrary evidence:

1. Android 11 / API 30, `armeabi-v7a`, pinned Android/Rust/NDK delivery contract.
2. Exact-head hosted candidate production and Windows LAB as artifact consumer by default.
3. Persistent process-wide Magisk shell semantics; terminal grant/denial is not repeatedly polled within one app process. Magisk + one persistent `su` shell remains the minimal platform privilege boundary unless physical evidence proves a simpler supported mechanism; do not replace it with a root daemon/helper or run the whole application as root merely to remove `su`.
4. Exact stale MISH-owned root-policy identity may self-heal only when the complete known PRODUCT contract is proven; foreign/malformed state stays fail-closed.
5. Canonical external capacity is 64 accepted sessions with deterministic overload rejection; this external admission policy belongs to `mish-transport`, not to Tokio/runtime execution.
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

# U2 — Native DEVICE-1 Acceptance and physical re-baseline — COMPLETED

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

The direct Windows upstream-lifetime control has now shown both 64 raw TCP and 64 TLS sessions to the selected target remaining alive for 90 seconds. This removes the simple hypothesis that the target itself closes idle connections on that direct path. It does not by itself prove the Android Cellular/Mesh path, so one bounded pre-change characterization separates native Proxy+Cellular from the full Mesh path before PRODUCT implementation changes. That characterization is for localization and regression design only; it does not reopen the accepted decision to converge on one Tokio executor.

The immediate U2 slice is therefore:

```text
current accepted PRODUCT
 -> bounded read-only pre-Tokio characterization
 -> Mesh execution convergence onto existing mish-runtime Tokio
 -> hosted contract + architecture gates
 -> fresh exact-head DEVICE-1 functional/capacity/resource acceptance
```

Before final 64/65 capacity and resource acceptance:

1. characterize the unchanged current PRODUCT just enough to distinguish `Proxy+Cellular` stability from `Mesh+Proxy+Cellular` stability and to validate real client-session liveness rather than collection membership;
2. move Mesh listener/session execution onto the existing process-wide Tokio runtime owned by `mish-runtime`;
3. keep `mish-transport` as the natural owner of Mesh admission, admission epoch, external capacity=64, active external-session fact and reject-at-edge semantics;
4. keep `mish-proxy` as the owner of HTTP CONNECT / SOCKS5 / mixed protocol, authentication and target semantics; it must not own an executor;
5. make `mish-runtime` the sole PRODUCT execution owner for long-lived Mesh ingress tasks, Proxy Serving tasks, async relays, cancellation and bounded drain;
6. do **not** add another Tokio runtime/executor, executor/thread pool, per-session OS-thread serving subsystem, move external capacity policy into `mish-runtime`, or create a second session/lifecycle owner;
7. replace thread-per-session Mesh relay with retained async tasks / async bidirectional relay inside the one runtime-generation task tree;
8. preserve the current external contract and owner-backed diagnostics (`mesh.active_sessions`, `proxy.active_sessions`);
9. adapt only tests/guards that encode the old thread implementation; protocol/auth/real-Mesh black-box acceptance remains the same contract;
10. add architecture tests/guards that mechanically prohibit a second PRODUCT Tokio runtime/executor or independent long-lived serving thread pool in `mish-transport` / `mish-proxy`, and prohibit external-capacity ownership from drifting out of `mish-transport`;
11. keep the hosted transport black-box proof that 64 sessions can remain admitted while the 65th is rejected before the private backend, independent of the executor mechanism;
12. rerun exact hosted gates and record a **fresh** physical idle/10/32/64/overflow/post-cleanup resource baseline after convergence. Pre-convergence thread/resource numbers remain diagnostic evidence only and cannot close final U2 resource acceptance.

Target execution/ownership split:

```text
Android
   |
   | platform effects / observations / presentation only
   v
Rust Runtime Owner: mish-runtime
   |
   `-- ONE process-wide Tokio runtime / cancellation tree
          |
          |-- Mesh ingress/session execution
          |      domain owner: mish-transport
          |      - exact Mesh endpoint
          |      - admission epoch
          |      - external budget = 64
          |      - active external-session fact
          |      - reject 65+ at the Mesh edge
          |
          |-- Proxy Serving execution
          |      runtime owner: mish-runtime
          |      protocol owner: mish-proxy
          |      - HTTP CONNECT
          |      - SOCKS5 / mixed
          |      - authentication
          |      - target parsing/preservation
          |
          |-- async bidirectional relays
          |      retained / cancelled / drained by mish-runtime
          |
          `-- Cellular Egress
                 - current cellular authority
                 - exact-network DNS
                 - root-policy gate
                 - exact-network public socket
```

Architecture formula:

```text
mish-runtime   = HOW admitted work executes
mish-transport = WHETHER an external Mesh session may enter
mish-proxy     = WHAT the proxy protocol/auth/target semantics mean
Cellular Egress= WHERE public outbound traffic may go
Android        = platform effects + observation + presentation
```

`ONE Tokio runtime` does **not** mean one semantic/domain owner. It means one execution engine and one cancellation/drain tree. Domain facts remain with their natural owners.

The canonical external limit of 64 is not a Tokio business rule. `mish-transport` owns the permit/admission decision; `mish-runtime` may own separate internal execution permits/control reserve only to protect the executor. Those internal permits must never become a second external-capacity authority.

Architecture regression guards are part of U2 DoD, not optional cleanup. After convergence, hosted gates must fail if PRODUCT reintroduces any of the following without an explicitly accepted architecture change:

- `tokio::runtime::Builder` or another runtime/executor owner outside `mish-runtime` for long-lived PRODUCT network work;
- an independent executor/thread pool in `mish-transport` or `mish-proxy`;
- thread-per-session Mesh serving/relay;
- a second external session counter/budget authority outside `mish-transport`;
- detached long-lived listener/session/relay tasks not retained by the runtime-generation owner;
- Android-owned duplicate Mesh/proxy admission, counters or lifecycle state.

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
- `mesh.active_sessions` and `proxy.active_sessions` agree for admitted full paths while each remains an observation from its natural owner;
- stop/start/restart and cellular loss/recovery are bounded and fail closed;
- runtime-generation shutdown cancels/drains every retained Mesh/Proxy/relay task without detached long-lived work;
- stable signer/UID and no repeated Magisk prompt on normal replacement install;
- one process-wide root shell is reused through repeated root-policy reads/reconciliations within the app process instead of creating one `su` process per command/recovery event;
- process restart establishes a fresh shell generation while the already-granted Magisk policy remains sufficient and does not require another interactive grant;
- repeated recovery cycles do not reopen Magisk prompts or create unbounded root-shell/process growth;
- fresh post-convergence baseline/peak/post-cleanup thread count, FD count and RSS/PSS at idle / 10 / 32 / 64 sessions;
- thread count no longer scales as the deleted Mesh `session thread + copy thread` model;
- startup, failure-to-fresh-READY, normal stop and recovery timings.

DEVICE-1 diagnostics are current-product health diagnostics. Canonical acceptance observes current runtime, Cellular, root authority/policy, native Proxy Serving, credentials, Mesh, readiness and functional E2E behavior. Historical sing-box PID/config identity is not a current PRODUCT health fact.

Exit: exact native topology, including one process-wide Tokio execution model for long-lived Mesh + Proxy session work, is physically proven and mechanically guarded against regression; the current resource/recovery baseline is recorded without secret/raw-IP leakage. The Magisk/su privilege boundary is considered physically accepted only after the replacement-install, restart and repeated-recovery evidence above passes.

## U2 closure evidence

U2 closed on exact PRODUCT head `6c5391957882ad2d16614a2ee4a66289a0cc4b7d` with canonical Device Cycle run `35289244271` / run number `222` and classification `U2_RECOVERY_LIFECYCLE_PASS`.

The accepted physical evidence includes:

- post-Tokio capacity/resource acceptance at 64 with deterministic 65th rejection;
- positive / loss / recovery Cellular E3 phases;
- loss blocks established flow, DNS and public sockets with no default fallback;
- fresh recovery generation, exact root-policy reconciliation and cleanup;
- fresh post-restart READY with root policy authorized, Proxy healthy, Mesh admitted/epoch/ingress, owner sessions 0/0 and loopback + Mesh E2E PASS.

PR #235 fixed dependency-safe root-policy teardown and was accepted on that exact candidate. PR #236 made installed DEVICE bytes authoritative after host install timeout. PR #237 made E3 evidence deterministic and debug-namespace exact.

Protected main after acceptance is `470e26ba483e5596bb06069e982036247d738c61`; its Git tree is byte-identical to the physically accepted head.

---

# U3 — Recovery, observability and lifetime convergence — CLOSED / PASS

U3 is formally closed. No active U3 implementation PR remains, and no rejected/obsolete U3 branch is a valid base for later stages.

Accepted closing slices:

- PR #258 — owner-backed Mesh capacity reject diagnostics;
- PR #259 — bounded generation/recovery diagnostics and consistent owner-backed projection;
- PR #260 — typed `RootObservation` / `RootMutation` effects over the single persistent `ProcessBuilder("su")` transport; shell-shaped `RootProcess.run(["su","-c", ...])` PRODUCT calls removed;
- PR #261 — deterministic recovery-instrumentation process handoff;
- PR #262 — exactly one fresh retry for a non-authoritative read-only root observation; uncertain mutations remain non-replayable and reconcile only through fresh observation.

Rejected optimization PR #244 (`u3/stable-mangle-verification`) remains rejected. It must not be revived, rebased or merged without new evidence demonstrating a current PRODUCT constraint.

Final accepted PRODUCT candidate:

```text
20b5177a3bd1c0ed5547e4813c5cb9cdfb1d928e
tree = 5901ae41e431ee299c32dea2e8e528d300becce5
```

Hosted exact-head gates:

- CI #672 / run `35362830544` = PASS;
- Integration Android Preflight #317 / run `35362830236` = PASS.

Canonical physical acceptance:

```text
Device Cycle #263
run_id = 35363568653
source_sha = 20b5177a3bd1c0ed5547e4813c5cb9cdfb1d928e
classification = U2_RECOVERY_LIFECYCLE_PASS
exact_candidate_acceptance = PASS
```

The physical evidence proves explicit instrumentation handoff; E3 positive/loss/recovery; established-flow, DNS and public-socket blocking during loss; no default fallback; fresh recovery generation; root-policy reconciliation and cleanup; restart READY; root policy authorized; Proxy healthy; Mesh admitted/epoch/ingress; and loopback + Mesh E2E PASS.

The squash-merged protected PRODUCT main is:

```text
c779aa72f919af6fe1664bce9e111a5029965516
tree = 5901ae41e431ee299c32dea2e8e528d300becce5
```

Therefore the physically accepted candidate tree and accepted protected-main tree are byte-identical.

U3 closure changes no route/mark/priority/table semantics and introduces no second Tokio runtime/executor, Cellular owner, root daemon/helper/RPC/control plane, privileged state machine, mutable status store or Android-owned duplicate admission/recovery authority.

Next stage: **U4 — Generation-bound Public Egress IP**. U4 starts only after U3 branch hygiene is complete, from fresh protected `main`, with one linear implementation branch/PR.


---

# U4 — Generation-bound Public Egress IP — CLOSED / PASS

Add one bounded public-IP observation through the exact PRODUCT cellular path.

Ownership:

```text
Cellular Egress -> current generation-bound public egress IP observation
Rotation        -> before/after observations and terminal comparison
UI              -> projection only
```

Requirements:

- current Cellular generation + current root-policy authorization;
- owner-bound/network-scoped cellular DNS;
- ordinary PRODUCT-UID public socket through the root-policy-gated current cellular route; no `Network.bindSocket` / `android_setsocknetwork` path pinning;
- HTTPS/TLS, absolute deadline and tiny bounded response;
- strict IP parsing;
- generation/currentness rejection after cellular change;
- no Android default/Wi-Fi/WARP fallback;
- one deliberately selected endpoint, not scattered service literals;
- raw public IP may be shown locally but is not persisted to logs/GitHub/analytics; durable evidence stores only changed/unchanged/failure.

## U4 closure evidence

U4 is closed on physically accepted exact PRODUCT head:

```text
7ba2f35233c418920ad97885eee9372f7e9117b9
tree = c02f858882c1a6e2be1392a76410d3cd5d897f80
```

Hosted exact-head gates:

- CI #708 = PASS;
- Integration Android Preflight #353 = PASS.

Canonical physical acceptance:

```text
Device Cycle #289
run_id = 35373265701
source_sha = 7ba2f35233c418920ad97885eee9372f7e9117b9
classification = U2_RECOVERY_LIFECYCLE_PASS
exact_candidate_acceptance = PASS
```

The existing accepted `recovery_lifecycle` physically proved U4 without adding a second DEVICE control plane. Its exact-head `CellularE3InstrumentedTest` proved:

- bounded positive HTTPS observations on the current owner generation;
- owner-bound/network-scoped DNS and ordinary PRODUCT-UID socket semantics;
- stale ticket rejection after a real cellular loss generation;
- no default/Wi-Fi/WARP fallback while Cellular Egress is not admitted;
- fresh-generation observation after recovery;
- repeated observations remain bounded;
- `raw_ip_persisted=false`.

The squash-merged protected PRODUCT main is:

```text
64482bfa1c5ba6bb2980839b58046742c2b13f19
tree = c02f858882c1a6e2be1392a76410d3cd5d897f80
```

Therefore the physically accepted candidate tree and accepted protected-main tree are byte-identical.

U4 introduces no second Cellular owner, networking stack, Tokio runtime/executor, readiness/lifecycle owner, Android per-socket network binding, fallback public-egress path, rotation owner or UI state owner.

U5 is **CLOSED / PASS**. Next stage: **U6 — Backend-driven Product UI**.

---

# U5 — First-class IP Rotation

`crates/rotation` remains the natural semantic owner. `mish-runtime` executes the sealed airplane observe/ON/OFF effects through the existing persistent Rust/Tokio root session; Android/Kotlin owns no airplane command or rotation policy.

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
- airplane observe / enable / disable are sealed Rust effects over the existing persistent root session; Android/Kotlin owns no airplane command or generic root command API;
- effective ON requires observed airplane ON plus cellular loss, not only shell exit 0;
- bounded best-effort restore to airplane OFF after any failure;
- fresh cellular generation -> fresh root policy -> native proxy/readiness -> public-IP probe;
- terminal result distinguishes IP changed, IP unchanged and failure;
- one bounded cycle per user request by default; no infinite retry-until-changed policy.

Physical capability proof on the supported rooted device is mandatory before PRODUCT acceptance.

## U5 final acceptance — CLOSED / PASS

Accepted PRODUCT source and protected-main identity:

```text
source_head = 429ba59d01d9db2e1fc84ed64cd5daf5e54198d8
accepted_product_main = a08214b3eb61403b92bc236d47d0abdd24533c4b
accepted_product_tree = b47832714ed5debddcdb776b8460c5183a250849
```

Hosted acceptance:

- PR Validation + PRODUCT Candidate #840 / run `35478614702`: PASS;
- LAB Host Static #567 / run `35478614707`: PASS;
- canonical candidate artifact id `10595362726`;
- candidate digest `sha256:29fcb915a0ec9b7b808c19827aae2345acd3e4c37efc6ff097a051b8b6b5df6e`.

Canonical physical acceptance:

```text
Device Cycle #596
run_id = 35479143756
source_sha = 429ba59d01d9db2e1fc84ed64cd5daf5e54198d8
classification = U5_ROTATION_PHYSICAL_ACCEPTANCE_PASS
exact_candidate_acceptance = PASS
```

The run physically proved three successful PRODUCT-owned rotations, real airplane ON/OFF observation, fail-closed readiness/Mesh during accepted Cellular loss, fresh owner generations, exact root re-authorization, readiness/Mesh recovery, unchanged credential material/version, no raw-IP persistence, bounded resources/session quiescence, and the stop-during-observed-ON restore case. The previously failing restart path now returns to READY through the explicit debug-only normal Service-start seam without introducing Kotlin recovery/timing ownership.

U5 is closed. Do not reopen Rust/Tokio/rotation ownership while implementing U6 unless new contradictory physical evidence appears.

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

## U6 final acceptance — CLOSED / PASS

Accepted exact PRODUCT source:

```text
source_head = a8710e001569d67939bca0c3dac75c834ffef107
accepted_product_main = 03c20e98405f9afd43241448fc88a19f02eec7d1
accepted_product_tree = 089ac8c69b12bcd76d6e1555e98cfaf41feb2e16
```

The exact candidate source head and squash-merged protected main are byte-identical at the Git tree boundary.

Hosted acceptance:

- PR Validation + PRODUCT Candidate #871 / run `35486746100`: PASS;
- candidate artifact id `10598110709`;
- candidate digest `sha256:d67ec87537b9ef1b973b478404ed07c5118708c53644efb2bedb2ad3a047d2cb`.

Canonical physical acceptance:

```text
Device Cycle #604
run_id = 35486973765
source_sha = a8710e001569d67939bca0c3dac75c834ffef107
control_sha = 5deda831d89f0d34c671e14e363bbb721bfb4754
probe = u5_rotation
cycle_result = PASS
classification = U5_ROTATION_PHYSICAL_ACCEPTANCE_PASS
exact_candidate_acceptance = PASS
```

Physical evidence artifact:

- artifact id `10598041688`;
- digest `sha256:3f68b47277fde2527b49e12eae48c859ff8968b8030a6e3e00b10444baa7f285`.

The final physical run was clean: no external DEVICE interaction occurred during the run. It proved exact installed-candidate identity, stable startup diagnostics, three PRODUCT-owned rotations with fail-closed Cellular/Readiness/Mesh behavior during loss, fresh owner/root generations, stable credential material/version, no raw-IP persistence, stop during observed airplane ON, runtime-active credential projection cleared before restart, airplane restored OFF, same-process restart to runtime generation 2 and READY, and bounded thread/FD/session/task quiescence with zero forbidden Kotlin owner threads.

The startup-order follow-up keeps the ownership boundary explicit:

```text
Application.attachBaseContext(base)
 -> one process-local MishRuntimeController
 -> NativeProductRuntime / Rust PRODUCT process handle

Application.onCreate()
 -> normal ProxyRuntimeService start request

MishDiagnosticsProvider
 -> read-only access to the already-created controller
```

The attached base Context is the process composition context. PRODUCT descendants do not re-resolve `applicationContext` during pre-`onCreate()` bootstrap. Diagnostics cannot construct PRODUCT state. Rust/Tokio remains the sole owner of lifecycle, generation, recovery, readiness and rotation semantics; Kotlin retains Android process/service/platform-effect/presentation boundaries only.

U6 is closed. Advance to U7 only from this accepted PRODUCT identity.

---

# U7 — Efficiency and long-run hardening

Measure the **current** direct native Tokio architecture, not deleted topology.

Evaluate:

- idle CPU/wakeup cost;
- the one Tokio runtime's Mesh + Proxy accept/task scheduling, cancellation and drain behavior;
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

# U8 — Production durability and deployment closure

Prove the appliance can remain operational across normal lifecycle events:

- app/process restart;
- device reboot and expected startup path;
- repeated `adb install -r` upgrades using the same signing identity;
- no repeated Magisk authorization after the existing grant unless Magisk itself revokes it;
- one persistent `su` transport remains bounded and replaceable on shell death without becoming a second privileged daemon/lifecycle;
- bounded recovery from cellular/provider loss;
- long soak with no unbounded FD/thread/task/memory growth;
- exact accepted Android artifact provenance remains reproducible through the single hosted candidate -> Device Cycle path; any future external distribution/signing is downstream packaging, not an RC acceptance lineage;
- diagnostics/support bundle remains typed, bounded and secret-safe.

Exit: production durability is accepted on exact artifact provenance plus accepted physical evidence; any external distribution package must derive from accepted source without creating a competing acceptance pipeline.

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
