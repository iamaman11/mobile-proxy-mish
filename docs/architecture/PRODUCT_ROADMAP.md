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
Issue #134                         -> CLOSED historical research/rationale archive
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
5. Canonical external capacity is 512 accepted sessions with deterministic 513th-session edge rejection; this external admission policy belongs to `mish-transport`, not to Tokio/runtime execution. U7 physical evidence #615 and #617 established the 512 bound, repeated cleanup, and lifecycle stability.
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

# U7 — Efficiency and long-run hardening — COMPLETED

Accepted U7 PRODUCT capacity closure:

- physical PRODUCT head `b865ba7581ad6962cc6b1c5b4d8e89807fd54524` passed bounded 512/513 acceptance in Device Cycle #615 and repeated 512/lifecycle stability in Device Cycle #617;
- strict-up-to-date PR head `2323d6fad678213805d0dc589c150a835016573f` preserved the same five PRODUCT blobs while merging current CONTROL main, and exact-head hosted gate #893 passed;
- accepted protected-main merge `801774794b11cd4544229cfe91927194a963fbeb` / tree `1801251cb7924c7fdca54bd2f8537ed74fc649a2`;
- canonical external capacity is now 512 concurrent external sessions; 513th rejection remains fail-closed at the Mesh edge;
- three same-process 512 high-water cycles returned Mesh/Proxy owners to 0/0, FD to 124 and threads to 24 each time; cleanup memory moved only about +1.1 MiB from first to third cleanup and is retained as observational allocator/high-water evidence rather than a leak claim;
- three normal rotations plus stop-during-airplane-ON -> STOP -> restore -> START passed in the same PID; restart reached PRODUCT with `cellular.reconcile.requested=3`, executed=3, pending=false, root authorized, READY and Mesh running;
- no second runtime, scheduler, connection manager, autoscaler, semaphore authority or Kotlin PRODUCT owner was introduced;
- 1024 is not a current target and requires a future demonstrated requirement rather than automatic scaling.

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

U8 is the final current PRODUCT stage. It proves production durability, real IP-rotation outcome, the narrow authenticated remote rotation command, external privacy/path behavior and exact release/support closure without introducing parallel owners.

Canonical execution/evidence ledger: issue #314. Specialized external proxy/privacy evidence: issue #315.

## Ordered U8 closure

```text
U8-A inventory                                      COMPLETE
U8-B reboot + replacement-install                   COMPLETE
U8-C root-shell death/replacement                    COMPLETE
U8-D public Cellular egress IP rotation proof       COMPLETE
U8-E authenticated remote IP-rotation command       COMPLETE / PASS
U8-F low-impact durability soak                      COMPLETE / PASS
     + reverse-WSS reconnect/heartbeat/traffic/resource budget
     + Mesh peer liveness
     + one long-lived proxy CONNECT/WebSocket lifetime probe
     + controlled Android process/service-death recovery proof
     + bounded latency/error/resource evidence
U8-G external privacy/path closure #315              COMPLETE / PASS
     + clean intended Windows client profile
     + DNS no-bypass proof
     + short final external regression across rotation
U8-H support + exact provenance closure              COMPLETE / PASS
U8 FINAL PASS                                        COMPLETE
```

Already accepted U2-U7 evidence is reused. Do not repeat process restart, ordinary cellular loss/recovery, accepted rotation lifecycle, 512/513 capacity or repeated 512 cleanup merely because U8 names durability again.

## U8 implementation admission rule

Every remaining item starts as `EVIDENCE_ONLY`, `CONTROL/LAB_ONLY` or `MINIMAL_PRODUCT_CHANGE_REQUIRED`. `NO CHANGE` is preferred whenever accepted owners already satisfy the requirement.

```text
U8-B reboot/install       -> CONTROL/LAB first
U8-C root-shell death     -> hosted fault/test seam first
U8-D IP-change proof      -> reuse U4/U5; evidence/CONTROL first
U8-E remote rotation      -> the one justified new feature slice
U8-F soak                 -> CONTROL/LAB first
U8-G privacy/path         -> client/LAB first
U8-H provenance           -> docs/evidence only
```

U8-E v1 is intentionally narrow: device session authentication/registration, `ROTATE_IP`, operation-result retrieval and only the liveness protocol required for those operations. No generic status RPC, arbitrary commands, remote proxy-credential retrieval, fleet scheduler, offline command queue, persistent device-state mirror or proxy data tunneling is part of U8.


### U8-B — reboot and replacement install

Prove on the exact hosted candidate:

- physical device reboot -> expected startup -> Cellular/root/Proxy/Mesh/READY convergence;
- one deliberate `adb install -r`;
- stable package UID and signing identity before/after;
- existing Magisk authority remains sufficient unless Magisk itself revoked it;
- no clean uninstall, second updater or competing deployment path.

### U8-C — persistent root-shell death/replacement

The existing process-wide serialized root transport remains the only root transport.

Prove that an unhealthy/dead shell is discarded, uncertain mutation is never replayed, and the next caller establishes a strictly newer shell generation. Prefer the smallest deterministic hosted fault seam; add one bounded physical fault injection only if hosted evidence cannot close the fact. No root daemon/helper/pool.

### U8-D — public Cellular egress IP rotation correctness

The existing Rust/Tokio rotation owner remains the only rotation owner.

For one explicit operation, observe the public Cellular egress before and after through the accepted Cellular path and return one typed outcome:

- `CHANGED` — bounded rotation completed, PRODUCT reconverged and the externally observed public egress IP differs;
- `UNCHANGED` — bounded rotation completed and PRODUCT reconverged but the carrier assigned the same public IP;
- `FAILED` — operation/recovery failed the required contract;
- `REJECTED` — authorization/precondition/busy/stale request rejection before mutation.

One request means at most one underlying rotation. Never hide repeated airplane/cellular cycles until a different IP appears. A caller may issue a new explicit request after `UNCHANGED`.

Raw public IP may be shown to an authenticated operator/controller, but ordinary GitHub logs/issues/artifacts persist only redacted change/equality and observer-consensus facts.

Current U8-D acceptance shape is CONTROL/LAB-only unless evidence exposes a PRODUCT defect: an independent Windows LAB client observes `checkip.amazonaws.com` through the existing authenticated PRODUCT HTTP CONNECT path immediately before and after exactly one existing Rotation-owner operation. The two raw addresses exist only in memory for equality comparison. Durable evidence records only the PRODUCT terminal result, independent external `CHANGED|UNCHANGED`, observer consensus, owner generations and bounded timing milestones.

### U8-D accepted physical evidence

U8-D closed without a PRODUCT code change. CONTROL PR #320 merged as `c348f8f03180452b37d1f273a5855a5b4b29f047`; exact PRODUCT remained PR #319 head `aea2fc7ad90adf5b68680aefd60e71b3e82bcb9e`. Device Cycle #650 / run `35769781964` passed with one explicit rotation: PRODUCT terminal `CHANGED`, independent authenticated-proxy external observation `CHANGED`, `observer_consensus=true`, `rotation_requests=1`, exact-candidate acceptance PASS, and no raw IP/secrets persisted. Current physical baseline: `total_rotation_ms=17516`, airplane-OFF -> fresh owner/root authorization `15587 ms`, functional public-IP `17166 ms`, READY `18541 ms`.

### U8-E — authenticated remote IP-rotation command

Production control transport is **MISH-initiated outbound WSS -> Cloudflare Worker -> Durable Object per device**, with **no Workers VPC dependency**:

```text
Remote Manager
      | HTTPS + manager authentication
      v
Cloudflare Worker / API
      |
      v
Durable Object(device_id)
      ^
      || authenticated long-lived outbound WSS
      ||
MISH control client on the existing Tokio runtime
      |
      v
existing Rotation owner
```

Design rules:

- MISH initiates the connection; Worker never needs to dial the Android Mesh IP;
- no public Android control listener, Workers VPC binding, second runtime, root daemon/helper, scheduler, lifecycle owner or generic RPC framework;
- reuse the existing Android Keystore/storage effect boundary for the per-device control key where applicable; do not create a second secrets database;
- Durable Object is a broker/coordinator for the live device connection and bounded recent operation correlation, not a second PRODUCT state authority;
- proxy credentials remain owned by MISH; do not persist plaintext proxy password in DO by default;
- Remote Manager -> Worker and MISH -> Worker/DO have separate reviewed authentication boundaries;
- one explicit remote command maps to at most one existing rotation operation; replay/duplicate/concurrent requests remain bounded and fail closed;
- WSS may survive or may drop across Cellular/underlay changes; correctness depends on neither outcome. If it drops, reconnect uses bounded backoff and the same device identity, then publishes the terminal result for the same `operation_id`;
- raw old/new public IP is privileged response data only; ordinary durable evidence stays redacted.

U8-E v1 concrete identity/transport decision:

- device authentication is asymmetric: one non-exportable Android Keystore P-256 signing key (`secp256r1`, SHA-256), with `device_id = SHA-256(public SPKI)`; Cloudflare receives only the public SPKI, never the private key or a shared device HMAC secret;
- this supersedes the earlier provisional HMAC idea because it removes a duplicated long-lived shared secret from the Worker/DO while preserving challenge-response authentication;
- manager authentication is a separate Cloudflare Worker secret (`MISH_MANAGER_TOKEN` in v1) and is never embedded in the APK or committed as a Wrangler variable;
- DeviceControl uses the Durable Object WebSocket Hibernation API and SQLite-backed bounded storage: one active operation plus at most 32 recent terminal correlations; there is no offline command queue;
- the Android control socket is an ordinary outbound management TLS/WebSocket path. It does not borrow the proxy/Cellular outbound connector or create a second data-plane owner;
- remote acceptance is two-phase at the existing Rotation owner boundary: reserve `operation_id` with no effect -> flush `ACCEPTED(request_id, operation_id)` -> activate exactly that prepared operation. A failed ACCEPTED write fails the prepared operation before mutation;
- the client does not generate an application heartbeat in U8-E. It responds to WebSocket protocol PING when received; any proactive heartbeat is admitted only later from U8-F physical NAT/carrier evidence.

Hosted contracts cover authentication, expiry/tamper/replay, idempotency, BUSY/rejection, acceptance-before-mutation, WSS loss/reconnect, deterministic terminal result, redaction, no VPC/public-listener dependency and proof that the existing Rotation owner remains the sole mutation owner.

Physical E2E: invalid command -> no mutation; valid command -> operation id; WSS may disappear during rotation; reconnect; terminal `CHANGED|UNCHANGED|FAILED|REJECTED`; READY/root/Proxy/Mesh recovery; before/after public egress result; short external proxy smoke.

### U8-E accepted evidence

U8-E closed on PR #322, squash-merged as `a093fb5293afa94cec821170f891bfb49630d02e`.

Canonical physical acceptance used exact PRODUCT `8325994be5ab8727ccf238794ef8f729923ac7bb` with CONTROL `15feab66ba14c10ca3c056f6adffa3dbdbbd6264`:

- Device Cycle #680 / run `35799515235` = `U8_REMOTE_CONTROL_ROTATION_PASS`;
- exact candidate install/provenance and installed bytes/signing identity PASS;
- baseline READY/root/Proxy/Mesh plus loopback+Mesh E2E PASS;
- wrong manager auth -> HTTP 401 and zero Rotation mutation;
- authenticated malformed request -> HTTP 400 and zero Rotation mutation;
- exactly one valid remote `ROTATE_IP` -> exactly one logical rotation request;
- one `operation_id`, terminal `CHANGED`;
- replay of the same `request_id` returned the same terminal operation with no second rotation;
- post-rotation READY/root/Proxy/Mesh and loopback+Mesh E2E PASS;
- raw public IP, manager token, private key and proxy credentials were not persisted in durable evidence.

Evidence artifact: `10725073120`, digest `sha256:6e8e3891682a4ff34fa9d5a3a87afa91494559c502fa9621d8df6e70188bc1fa`.

Final hosted PR head `76f768b32e9acbef38a3b5f7f4dc96952ca61c29` passed PR Validation + PRODUCT Candidate #944 / run `35800002205` and U8 Control Static #6. Commits after the physically tested PRODUCT SHA were CONTROL/LAB/docs/guard only; PRODUCT source remained unchanged.

U8-E must not be rerun merely for closure. U8-F is next and remains CONTROL/LAB-first.


Control-session efficiency is part of U8 rather than an unmeasured background cost:

- push-driven channel; no status polling;
- do not add app-level heartbeat unless physical carrier/NAT behavior requires it; if required, evaluate **2–5 minutes** first and shorten only from measured evidence;
- target idle control traffic **<10 MB/month/device**, preferably **<5 MB/month/device**;
- bounded reconnect backoff; no reconnect storms;
- expose bounded typed observations for session age/state, reconnect count, heartbeat count, bytes TX/RX and last RX/TX age;
- U8-F correlates those with CPU/radio wakeup/thread/FD/task/RSS/PSS behavior.

Workers VPC remains only a possible future data-plane gateway capability if a Worker later needs to initiate private connections to MISH proxy services; it is not part of the U8 control dependency.


### U8-F — low-impact durability soak

Run only after B-E are accepted.

Soak proves lifetime/leak behavior, not throughput:

- no unbounded FD/thread/task/memory growth;
- Mesh peer liveness is checked, not merely local WARP/adapter “Connected” status;
- one bounded long-lived **proxy data-plane** CONNECT/WebSocket lifetime probe;
- one controlled Android process/service-death proof: start from READY, terminate the current MISH process/service through the bounded LAB fault seam, perform no user action or explicit recovery launch, require Android's existing service/lifecycle path to produce a fresh PID/runtime and reconverge Cellular/root/Proxy/Mesh to READY, then prove external proxy E2E again;
- the process-death proof must reuse the existing foreground-Service/platform lifecycle; no watchdog process, second scheduler, root daemon or alternate lifecycle owner;
- summarized latency/error/resource evidence;
- no repeated 512-session stress unless a concrete new durability failure requires it.

### U8-F accepted evidence

Canonical physical acceptance:
- PRODUCT `94a9f4993b524b0388f0e2216e9e78183c8a3a4f`;
- CONTROL `f5f3b84ba3754a5591950e26da67914d6cd799a6`;
- Device Cycle #683 / run `35804498003` = `U8_DURABILITY_SOAK_PASS`;
- exact candidate acceptance PASS with post-merge PRODUCT identity exact-match proof;
- one authenticated Mesh HTTP CONNECT/TLS session remained application-live for 14 pulses over the bounded soak;
- reverse control remained READY with reconnect delta 0 and application heartbeat count 0;
- control application TEXT payload did not grow during the idle soak; evidence deliberately does not claim TLS/IP wire bytes;
- sole Tokio executor tasks stayed at 2; threads stayed within 24-25;
- FD count returned to baseline after the long-lived proxy session (125 -> 129 active -> 125);
- RSS/PSS were recorded as observational only and were not converted into a leak claim from one bounded run;
- controlled Android process death produced a fresh PID `32210 -> 5560`, recovered to READY in 11894 ms without explicit Activity launch or user recovery action, preserved credential version, restored control READY and passed loopback + Mesh proxy E2E;
- no 512-session stress was repeated;
- evidence artifact `10726874501`, digest `sha256:8ee59911499d0a1d1c2b786d29d98491021d7db82b461a9d79254ffd296bc69d`.

U8-F is closed. Its lifetime/soak evidence is reused by U8-G and must not be duplicated.

### U8-G — external privacy/path closure — COMPLETE / PASS

Issue #315 is closed `completed`. It remains the specialized external-client/browser evidence ledger rather than duplicating its full historical matrix here.

Canonical final physical acceptance:

- accepted PRODUCT source: `94a9f4993b524b0388f0e2216e9e78183c8a3a4f`;
- Device Cycle #731 / run `35936228660`;
- physical CONTROL: `a2036eaeb60f0e766d9593bb62bb25e6d302091c`;
- cycle result/classification: `PASS / U8_G_FINAL_CLEAN_CLIENT_PASS`;
- exact-candidate acceptance: PASS;
- evidence artifact: `10783212513`;
- evidence digest: `sha256:b1df63bb6b15a7afc91e993d253ffd94cf9412471da26c18d8dadae868cd11ca`.

Accepted clean-client facts:

- wrong auth fails closed; the next valid authenticated request succeeds;
- canonical HTTPS CONNECT :443 passes;
- before and after the one explicit rotation, PRODUCT DNS counters advance exactly once for the clean target while the Windows DNS cache remains free of that target, proving the intended DNS no-bypass path;
- browser public-egress observers agree with the canonical authenticated MISH proxy observation and do not match host-default egress;
- exactly one PRODUCT-owned rotation returns `CHANGED`; canonical proxy and browser external observations also return `CHANGED`;
- post-rotation PRODUCT returns READY;
- raw public/private/DNS addresses and proxy credentials are not persisted.

The earlier `NAVIGATION_0` failures were CONTROL/LAB serialization defects, not PRODUCT failures: a one-element PowerShell URL array had been serialized as a JSON string. The accepted harness preserves one URL as a JSON array and has a deterministic static regression guard.

Previously accepted #315 evidence remains in force for the four intended ingress modes, bounded reliability, WebRTC, IPv6 and identity-header behavior. Long-lived lifetime evidence is reused from U8-F and was not duplicated.

Population-level fingerprint anonymity and cosmetic anti-detect scores are not PRODUCT blockers.

### U8-H — support and provenance closure — COMPLETE / PASS

U8-H is docs/evidence-only. No new runtime, release candidate, support daemon, mutable support database or second acceptance lineage is introduced.

Final exact provenance:

- protected main at U8-H entry: `a2036eaeb60f0e766d9593bb62bb25e6d302091c`;
- protected-main Git tree: `aab9c797f65cda7f1df3c4e1b52c73a6e527b50f`;
- accepted final PRODUCT source: `94a9f4993b524b0388f0e2216e9e78183c8a3a4f`;
- accepted PRODUCT source tree: `d4f467c8a5c7d793835448eddd7cb0d6753b877e`;
- current protected main and the accepted PRODUCT source are blob-identical for `android/`, `crates/`, `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `config/` and `contracts/`;
- immutable hosted candidate producer: PR Validation run `35803074208`;
- canonical candidate artifact: `10726024554`;
- candidate digest: `sha256:a60bf25bc02413e4f93aad8bf62abedbf8db0e7a097806e261df3dd2428b336b`.

U8 evidence ledger:

| Slice | Accepted evidence |
|---|---|
| U8-B reboot/install | PRODUCT `2323d6fad678213805d0dc589c150a835016573f`; CONTROL `772316d364ad9358dd864ed1be23edff7c6f084e`; Device Cycle #649 / `35760950837`; artifact `10710425908`, digest `sha256:ddecb250e2afda118c54daccec093a39fe5781f1e163d7e1a70a579b9e47e0c1`; `U8_REBOOT_INSTALL_DURABILITY_PASS`. |
| U8-C root-shell replacement | PR #319 head `aea2fc7ad90adf5b68680aefd60e71b3e82bcb9e`; merge `78655109d75235f7d767550af15a0b8f47d36522`; hosted run `35764084003`; uncertain mutation not replayed and shell generation strictly replaced. |
| U8-D public egress rotation | PRODUCT `aea2fc7ad90adf5b68680aefd60e71b3e82bcb9e`; CONTROL `c348f8f03180452b37d1f273a5855a5b4b29f047`; Device Cycle #650 / `35769781964`; artifact `10713642471`, digest `sha256:8a09e2cb65f8c00c6fa55d563e510729746c269b0e573558d3a41d971fdeaca0`; `U8_PUBLIC_EGRESS_ROTATION_PASS`. |
| U8-E authenticated remote rotation | PRODUCT `8325994be5ab8727ccf238794ef8f729923ac7bb`; CONTROL `15feab66ba14c10ca3c056f6adffa3dbdbbd6264`; Device Cycle #680 / `35799515235`; artifact `10725073120`, digest `sha256:6e8e3891682a4ff34fa9d5a3a87afa91494559c502fa9621d8df6e70188bc1fa`; `U8_REMOTE_CONTROL_ROTATION_PASS`. |
| U8-F durability soak | PRODUCT `94a9f4993b524b0388f0e2216e9e78183c8a3a4f`; CONTROL `f5f3b84ba3754a5591950e26da67914d6cd799a6`; Device Cycle #683 / `35804498003`; artifact `10726874501`, digest `sha256:8ee59911499d0a1d1c2b786d29d98491021d7db82b461a9d79254ffd296bc69d`; `U8_DURABILITY_SOAK_PASS`. |
| U8-G external privacy/path | PRODUCT `94a9f4993b524b0388f0e2216e9e78183c8a3a4f`; CONTROL `a2036eaeb60f0e766d9593bb62bb25e6d302091c`; Device Cycle #731 / `35936228660`; artifact `10783212513`, digest `sha256:b1df63bb6b15a7afc91e993d253ffd94cf9412471da26c18d8dadae868cd11ca`; `U8_G_FINAL_CLEAN_CLIENT_PASS`. |

Bounded support evidence is the already accepted typed observation surface: `mish.diagnostics/v2`, immutable Device Cycle reports/artifacts, and stage-specific redacted evidence. This is sufficient for U8 support/provenance closure; adding a second support bundle state store would duplicate accepted owners and is prohibited.

External distribution/store signing may derive later from the accepted source/artifact, but it is a delivery concern and must not retroactively create a competing RC/development acceptance lineage.

## U8 architecture invariants

- Rust/Tokio remains sole PRODUCT lifecycle/execution/rotation authority;
- Kotlin remains thin Android platform/effect/presentation boundary;
- exactly one process-wide Tokio runtime;
- exactly one persistent serialized root transport;
- no second VPN/TUN, root daemon/helper, lifecycle/recovery/rotation owner, mutable status database, connection manager, scheduler or autoscaler;
- proxy credentials and control credentials are separate durable authorities and change only by explicit commands;
- no Wi-Fi/default/WARP fallback for PRODUCT public egress;
- physical Device Cycle remains explicit owner-controlled only; no automatic physical trigger.

Exit: **U8 CLOSED / PASS.** B-H are accepted on exact provenance. U8 is the final stage in the current PRODUCT roadmap; no further PRODUCT stage is implied by this closure.

## Post-U8 explicit CONTROL refinement — issue #366 — COMPLETE / PASS

This is **not** a new PRODUCT stage and does not reopen U8. It is an explicitly requested manager-API simplification over the already accepted U8-E control plane.

Public remote-manager contract:

```text
POST https://api.alegria.by/v1/rotate
Authorization: Bearer <MISH_MANAGER_TOKEN>
body: empty
        |
        v
one typed mish.control.rotate/v1 response
```

Accepted boundary:

- the remote application knows only the manager token; host/path are application constants;
- `device_id`, caller-owned `request_id`, polling and WebSocket correlation are not part of the public application API;
- Worker generates the internal `request_id` cryptographically and returns it only as typed support/correlation metadata;
- one fixed-name existing `DeviceControl("primary")` Durable Object is used for the single-device deployment; no KV/D1/device registry/second Durable Object state owner was added;
- the existing Android Keystore identity, Rust/Tokio control runtime, WSS authentication, `ROTATE_IP -> ACCEPTED -> RESULT` wire protocol and Rotation owner remain unchanged;
- one public POST maps to at most one PRODUCT rotation;
- manager wait is event-driven and manager polling is zero;
- transport uncertainty is represented explicitly as typed `UNKNOWN` and is non-retryable;
- old manager `/devices/{device_id}/rotate` and `/operations/{request_id}` paths are not public application APIs;
- privileged enrollment remains an explicit operator/LAB provisioning seam.

Accepted implementation/evidence:

- implementation PR #367, head `d8e09d04970df00382c3edc1c12eb2ae17a20fa6`, merged;
- post-merge exact-head deployment-gate fix PR #368, merge `b043231de7f65ce5c4a6edf3d4bc72d77f892737`; no Worker runtime/API or PRODUCT behavior change;
- PR Validation run `35940720497` = PASS;
- U8 Control Static run `35940720510` = PASS;
- exact Worker deployment run `35941127306` = PASS;
- deployed Worker version `a9c58bd4-bb1f-49af-941a-155196f42a7b` on `api.alegria.by`;
- deployment smoke: unauthenticated POST = 401, wrong manager token = 401, authorized caller-supplied body = 400 before dispatch;
- physical Device Cycle #741 / run `35941217166` on CONTROL `b043231de7f65ce5c4a6edf3d4bc72d77f892737` with accepted PRODUCT `94a9f4993b524b0388f0e2216e9e78183c8a3a4f` = `U8_REMOTE_CONTROL_ROTATION_PASS`;
- physical result: exactly one public manager command, exactly one logical rotation request, server-generated request id PASS, manager polling = 0, operation_id = 1, terminal result `CHANGED`;
- post-rotation runtime/Cellular/root/Proxy/Mesh/readiness returned healthy/READY and loopback + Mesh proxy E2E passed;
- physical evidence artifact `10784683552`, digest `sha256:3d6823ef81c8d2abb7598fbf7fe91fd96626878b1e55288ac81f917ee1ac137f`;
- raw public IP and secrets were not persisted;
- no PRODUCT rebuild or PRODUCT source change was required.

Disposition: **issue #366 = COMPLETE / PASS.** The remote application contract is now one manager token, one POST command and one typed `mish.control.rotate/v1` response.

## Post-U8 CONTROL reliability refinement — issue #370 — COMPLETE / PASS

This is **not** a new PRODUCT stage and does not reopen U8. It bounds the server-owned manager-operation lease after a real external test demonstrated that an abandoned manager HTTP request could leave `DeviceControl.active_operation` BUSY indefinitely if terminal delivery were permanently lost.

Accepted boundary:

- CONTROL-only; Android/Rust/Rotation owner behavior remains unchanged;
- public manager API remains one empty-body `POST /v1/rotate` with one typed `mish.control.rotate/v1` response;
- the existing `DeviceControl("primary")` Durable Object remains the only server-side operation state owner;
- PRODUCT retains its canonical 90 s rotation safety deadline;
- accepted operations use a 120 s result-delivery lease (90 s PRODUCT safety + 30 s delivery margin);
- historical #370 implementation used a 180 s manager/dispatch window before `FENCED`; **this delivery timing is superseded by issue #373**. The retained #370 guarantee is the bounded fail-closed stale-operation lease and 120 s PRODUCT drain;
- Durable Object Alarms own the persistent lease deadlines across hibernation/restart;
- stale expiry is represented as typed `UNKNOWN/TIMEOUT`, `dispatched=true`, `retryable=false`;
- a late real PRODUCT `RESULT` upgrades the bounded UNKNOWN correlation and receives `RESULT_ACK`;
- legacy persisted DISPATCHED/ACCEPTED records self-heal conservatively;
- no KV/D1/device registry/second scheduler/second mutation owner was added.

Accepted implementation/evidence:

- implementation PR #371, merged as `99f023d38f0871f496d2f747f912b5af14a5647e`;
- PR Validation #1012 / run `36004396343` = PASS;
- U8 Control Static #33 / run `36004396302` = PASS;
- Worker deploy #85 / run `36004561223` = PASS;
- deployed Worker version `09e56152-f505-43f6-9c2c-06a31fceee53`;
- deployed Worker source blob is byte-identical to merged-main Worker source;
- first targeted physical Device Cycle #743 / run `36004727826` correctly remained fail-closed with `409 BUSY` while the legacy active operation was still inside the conservative recovery lease; exact install and pre-rotation PRODUCT diagnostics were healthy;
- after bounded recovery expiry, Device Cycle #744 / run `36005767863` = `U8_REMOTE_CONTROL_ROTATION_PASS`;
- #744 physical result: exactly one public command, exactly one logical rotation request, server-generated request id PASS, manager polling = 0, operation_id = 1, terminal result `CHANGED`;
- post-rotation runtime/Cellular/root/Proxy/Mesh/readiness = healthy/READY, loopback proxy E2E = PASS, Mesh proxy E2E = PASS;
- #744 evidence artifact `10810821035`, digest `sha256:40a07f0fb593a4fe90e42b8705ec2e4749d6efac8ec9fed640e5700988d75f38`;
- raw public IP and secrets were not persisted;
- accepted PRODUCT remains `94a9f4993b524b0388f0e2216e9e78183c8a3a4f`; no PRODUCT rebuild/source change was required.

Disposition: **issue #370 = COMPLETE / PASS.** Permanent stale BUSY is bounded without weakening fail-closed semantics or adding a second rotation/state owner.

## Post-U8 CONTROL delivery refinement — issue #373 — COMPLETE / PASS

This is **not** a new PRODUCT stage and does not reopen U8. It fixes the real external failure mode where Manager authentication succeeded, `POST /v1/rotate` received no bytes for 195 s, and the phone did not rotate.

Root cause and accepted boundary:

- Worker-side `socket.send(ROTATE_IP)` is only local server dispatch and is **not** treated as proof that PRODUCT received the command;
- Rust `ACCEPTED(request_id, operation_id)` is the authoritative delivery/mutation-start boundary because PRODUCT flushes ACCEPTED before `rotation.activate_prepared()`;
- initial delivery-ACK deadline = **10 s**;
- if still DISPATCHED, Worker closes only the current authenticated WSS to force the existing Rust reconnect lifecycle;
- reconnect redelivers **exactly the same request_id once**; PRODUCT idempotency returns the known operation if the first delivery actually crossed the wire, so no second mutation is created;
- recovery delivery-ACK deadline = **15 s**;
- if still unaccepted, operation becomes `FENCED`, redelivery stops, manager receives typed `UNKNOWN/TIMEOUT`, and the existing 120 s PRODUCT drain remains authoritative before BUSY release;
- manager HTTP overall wait = **55 s**, deliberately below the Durable Object inactive-eviction window;
- after manager timeout, Durable Object Alarm continues server-owned correlation independently;
- no application heartbeat, polling endpoint, manager polling, KV/D1, second scheduler service, second state owner or second rotation owner was added.

Accepted implementation/evidence:

- implementation PR #374, merged as `6ac9e646de77377892a0442148f36a0a316ba19a`;
- PR Validation #1014 / run `36010752753` = PASS;
- U8 Control Static #34 / run `36010752435` = PASS;
- exact Worker deploy #88 / run `36010905104` = PASS;
- deployed Worker version `29b5f927-b30c-4a42-b392-4eed6c243d46`;
- physical Device Cycle #746 / run `36011081527` = `U8_REMOTE_CONTROL_ROTATION_PASS`;
- physical result: exactly one public command, exactly one logical rotation request, server-generated request id PASS, manager polling = 0, operation_id = 1, terminal result `CHANGED`;
- from the physical log, the interval from the completed pre-rotation invalid-request diagnostic to completed post-rotation diagnostic was under 20 s, including the actual manager command, rotation and post-diagnostic collection;
- post-rotation runtime/Cellular/root/Proxy/Mesh/readiness = healthy/READY, loopback proxy E2E = PASS, Mesh proxy E2E = PASS;
- evidence artifact `10812292899`, digest `sha256:8f1d60d8589af92c68c63615ebcf27ba09ff51bad04e8e303765aa0400d65a20`;
- raw public IP and secrets were not persisted;
- accepted PRODUCT remains `94a9f4993b524b0388f0e2216e9e78183c8a3a4f`; no PRODUCT rebuild/source change was required;
- operator/LAB client timeout is aligned to **65 s** (55 s Worker bound + 10 s transport margin), replacing the obsolete 195 s value.

Disposition: **issue #373 = COMPLETE / PASS.** Remote rotation is now delivery-acknowledged, performs one safe same-request reconnect recovery, and cannot hold one manager HTTP request for three minutes.

## Post-U8 CONTROL reconnect-budget alignment — issue #376 — COMPLETE / PASS

A real external WSL request exposed one remaining cross-layer timing mismatch after #373: Worker had already dispatched the command to an authenticated device WSS, but no PRODUCT `ACCEPTED` arrived before the 10 s initial + 15 s recovery windows expired. The manager received typed `UNKNOWN/TIMEOUT` after 25 s with `dispatched=true`, `operation_id=null` and `device_online=false`.

The failure was not on the Manager -> Worker path. The mismatch was between the server recovery fence and the already-accepted PRODUCT reconnect budget:

- first PRODUCT reconnect backoff after a READY session = **1 s**;
- control transport connect timeout = **15 s**;
- challenge wait = **10 s**;
- READY wait = **10 s**;
- therefore one valid reconnect/auth path may consume up to **36 s**;
- old Worker recovery ACK window = **15 s**, which could fence a slow but contract-valid reconnect.

Accepted correction:

- initial delivery ACK remains **10 s**;
- exactly one same-request reconnect/redelivery remains the only recovery;
- recovery delivery ACK window = **40 s** = 36 s PRODUCT reconnect/auth budget + 4 s CONTROL/wire margin;
- total unaccepted delivery fence is therefore about **50 s**, still below the **55 s** manager HTTP bound;
- operator/LAB client bound remains **65 s**;
- PRODUCT rotation safety remains **90 s**;
- accepted-result and FENCED drain remain **120 s**;
- `ACCEPTED` remains the authoritative delivery/mutation-start boundary;
- no heartbeat, polling endpoint, queue, KV/D1, second scheduler, second state owner or second rotation owner was added.

The architecture guard now pins the PRODUCT connect/auth/reconnect constants together with the Worker 40 s recovery envelope so the layers cannot silently drift back into an impossible timing contract.

Accepted implementation/evidence:

- issue #376 = CLOSED / PASS;
- implementation PR #377 merged as `9fc1370c1d543012beaa32d492f9a17f77a8bee0`;
- U8 Control Static #35 / run `36015428459` = PASS;
- PR Validation + PRODUCT Candidate #1016 / run `36015428517` = PASS;
- exact Worker deploy #90 / run `36015588008` = PASS;
- deployed Worker version `655f2c2c-fb74-4bfd-ac3a-cb0fd38cd5c6`;
- physical Device Cycle #748 / run `36015839535` = `U8_REMOTE_CONTROL_ROTATION_PASS`;
- physical result: exactly one public command, exactly one logical rotation request, server-generated request id PASS, manager polling = 0, operation_id = 1, terminal result `CHANGED`;
- after rotation runtime/Cellular/root/Proxy/Mesh/readiness = healthy/READY, loopback proxy E2E = PASS, Mesh proxy E2E = PASS;
- interval from completed authenticated-invalid-request diagnostic to completed post-rotation diagnostic was under 18 s, including the real manager request, rotation and post-diagnostic collection, proving the 40/55 s values are upper bounds rather than fixed waits;
- evidence artifact `10814567741`, digest `sha256:0aa825f17776a6a06c0782e5ea45e71de336a243fe245692c30c26aaed3040bd`;
- raw public IP and secrets were not persisted;
- accepted PRODUCT remains `94a9f4993b524b0388f0e2216e9e78183c8a3a4f`; no PRODUCT source change or rebuild was required.

Disposition: **issue #376 = COMPLETE / PASS.** CONTROL recovery timing now covers the PRODUCT reconnect/auth contract while remaining bounded below the manager HTTP deadline.

## Post-U8 CONTROL long-lived session liveness — issue #379 — COMPLETE / PASS

A repeated real WSL request after idle showed that the #376 timing correction still treated a broker-visible hibernated WebSocket object as proof of a live mobile session. The request reached the Worker and authenticated correctly, but returned typed `UNKNOWN/TIMEOUT` after the full 50 s unaccepted-delivery window.

Root cause:

- Durable Object `getWebSockets()`/serialized `authenticated=true` proved only that a socket object existed;
- a mobile NAT/TCP/WSS path could already be half-open/stale after idle;
- manager-triggered reconnect/redelivery could not reliably repair that state because the Close used to force reconnect travelled over the same potentially stale path;
- increasing timeout therefore extended the symptom rather than proving liveness.

Accepted architecture correction:

- Android/Kotlin remains only the Android lifecycle/platform/Keystore/diagnostics boundary;
- the existing Rust/Tokio `ControlRuntimeCoordinator` remains the sole CONTROL session owner;
- one 4 s application heartbeat runs as one branch of that existing Tokio task; no second runtime/thread/scheduler is created;
- Cloudflare Durable Object uses hibernation WebSocket auto-response and its timestamp as freshness evidence without keeping the object awake;
- freshly authenticated sockets receive an explicit authentication timestamp for the initial heartbeat grace period;
- Worker/DO dispatches only to an authenticated session fresh within 10 s;
- Worker no longer owns reconnect/redelivery policy;
- one fresh-session command gets one 2 s `ACCEPTED` boundary;
- connect timeout = 3 s, auth timeout = 3 s, reconnect backoff = 0.5/1/2/3/5 s;
- manager HTTP ceiling = 18 s;
- LAB/client ceiling = 20 s;
- accepted-operation correlation/FENCED safety remains independently bounded at 120 s;
- Rotation remains the sole IP-mutation owner;
- no Hyper, Tonic, polling API, heartbeat service, KV/D1, second state owner or second rotation owner was added.

Accepted implementation/evidence:

- issue #379 = CLOSED / PASS;
- implementation PR #380 merged as `2ed94e001bcce2b05efa5bea689185bd76b9a7eb`;
- exact accepted PRODUCT candidate source = `b2b022d66a7ddd8501502b981cad4058ae668bf5`;
- protected-main and candidate-source trees are identical: `b4dd93fb6256be7030c5e073e92ea1dd3de674ca`;
- U8 Control Static #46 / run `36024413518` = PASS;
- PR Validation + PRODUCT Candidate #1029 / run `36024413605` = PASS;
- candidate artifact `10818148287`, digest `sha256:81b0d81c373a354e3bd5ffc621f35f0cf2c176dd850689fa29f8860676b69278`;
- Control Worker Deploy #95 / run `36025137947` = PASS;
- deployed Worker version `4168ec20-dcd0-4a23-b3c9-842a64b2f787`;
- post-merge physical Device Cycle #754 / run `36025715172` = `U8_REMOTE_CONTROL_ROTATION_PASS`;
- 12 s idle proof: heartbeat delta = **+3**, reconnect delta = **0**, proving a long-lived READY WSS rather than fresh socket presence;
- physical result: one public command -> one logical rotation, operation_id = 1, terminal = `CHANGED`, server-generated request id PASS, manager polling = 0;
- manager response duration = **17,376 ms**, below the 18,000 ms server ceiling and 20 s client ceiling;
- post-rotation runtime/Cellular/root/Proxy/Mesh/readiness = healthy/READY;
- loopback proxy E2E = PASS, Mesh proxy E2E = PASS;
- evidence artifact `10819318630`, digest `sha256:7a605680c6b06d9c5e714498c1cb945faa9c715dafe489f1e201aaee67372fff`;
- raw public IP and secrets were not persisted.

Disposition: **issue #379 = COMPLETE / PASS.** Long-lived CONTROL liveness is now continuously proven by the existing native owner, stale socket presence is fail-closed before dispatch, and the public rotation path is bounded to 20 s end-to-end.


---

## Post-U8 — Consumer-facing remote rotation SDK — COMPLETED / PASS

A demonstrated integration requirement after U8 was to expose the already accepted public remote-rotation contract to future applications through one thin typed client without moving any command, retry, polling, device or Rotation ownership out of the existing Cloudflare Worker/DO + Rust/Tokio path.

Accepted boundary:

```text
future application
  -> MishControlClient.RotateIpAsync()
     -> one POST https://mish.alegria.by/v1/rotate
        -> existing Worker/DO
           -> existing reverse WSS CONTROL
              -> existing Rust Rotation SM
```

Accepted implementation/evidence:

- issue #410 = CLOSED / PASS;
- implementation PR #411 merged as `54c5b44e6a4d1d11396f3fabb87b02a4af4b77ff`;
- SDK lives only under `sdk/dotnet/**` with dedicated `.github/workflows/sdk-dotnet.yml`;
- public typed models: `RotateIpResponse`, `RotateResult`, `RotateReason`;
- consumer call surface: `await client.RotateIpAsync()`;
- caller cannot provide request id, operation id, device id, WSS/session details or Android/PRODUCT internals;
- one SDK call performs one empty-body public POST, with no SDK polling, hidden retry, redirect replay or replay after `UNKNOWN`;
- valid `CHANGED`, `UNCHANGED`, `FAILED`, `REJECTED` and `UNKNOWN` remain typed results;
- unknown schema/version, malformed JSON, transport failure and HTTP/body mismatch are typed errors;
- SDK .NET #2 / run `36152559730` = PASS, build 0 warnings / 0 errors, contract tests 16/16 PASS;
- general PR validation #1096 / run `36152559646` = PASS with `PRODUCT_CHANGED=false`, heavy Rust validation NO, heavy Android build NO, device candidate NO;
- no Cloudflare Worker/DO behavior changed;
- no Android/Rust/Rotation/CONTROL/POWER_OFF/Cellular/root behavior changed;
- no APK rebuild or physical DEVICE cycle was required for this SDK slice.

The accepted PRODUCT immediately before this external SDK slice remains commit `3c5d337243eeeb12c18fb09bf881489d54c6d7ee`, physically accepted by Device Cycle #823 / run `36142620609`. The subsequent SDK merge changes only SDK/SDK-CI files and does not reopen PRODUCT acceptance.


## Post-U8 — Unified remote-control hostname — COMPLETED / PASS

Issue #413 converged the entire remote-control surface onto one canonical hostname:

```text
mish.alegria.by
├── /v1/device/connect
├── /v1/devices/{device_id}
└── /v1/rotate
```

The previous split-host deployment was an intermediate migration state only and is superseded. No permanent `api.alegria.by` control surface or fallback remains.

Accepted implementation and deployment:

- issue #413 = CLOSED / PASS;
- final implementation PR #416 exact accepted head = `b650ce8ce5ddc9cc7bce2e7f2ebd12fe739576d4`;
- protected-main merge = `db3abd4ec7225f46004afa8b3dd54a1d391fa958`;
- accepted candidate tree = protected-main tree = `eb0530caf9e81ff15485d26ece5899e5b93c43b1`;
- `config/deployment/control-host.txt = mish.alegria.by`;
- Worker owns exactly one custom domain: `mish.alegria.by`;
- SDK fixed endpoint and LAB remote-control path use the same hostname;
- U8 Control Static #101 / run `36155418650` = PASS;
- PR Validation #1100 / run `36155418667` = PASS;
- Rust Workspace, Android Build/Test and Android Compose Shell = PASS;
- `PRODUCT_CHANGED=true` only because the repository-owned CONTROL hostname is compiled into PRODUCT;
- canonical exact PRODUCT candidate artifact `10873528228`, digest `sha256:5a397344f619c33ca4cd7dcbc1a7f42babf0e94e30cf6970d186cf4eae4590f3`.

The migration used one temporary Worker-only bridge, PR #417, solely to avoid a CONTROL blackout while DEVICE-1 moved from the old hostname to the new PRODUCT candidate. The bridge was deployed as Worker version `26f69057-2ac7-4072-a599-62a93192d8f2`, was never merged, and was closed after the final Worker deployment.

Physical acceptance before removing the legacy route:

- Device Cycle #839 / run `36159146523` = PASS;
- exact #416 installed bytes/signing identity = PASS;
- CONTROL host = `mish.alegria.by`;
- one remote command / one logical Rotation / polling=0;
- terminal = `CHANGED`;
- heartbeat delta=3 / reconnect delta=0;
- POWER_OFF gate = PASS;
- independent external public-IP proof = CHANGED / consensus=true;
- post PRODUCT health = Cellular ADMITTED, root authorized, Proxy RUNNING/healthy, Mesh ADMITTED, readiness READY, loopback E2E PASS, Mesh E2E PASS;
- evidence artifact `10874093566`, digest `sha256:9b351c8f5580fb7d024d7685528e486a877df180f9197d15d3d2849a29a27839`.

Final Worker deployment:

- Control Worker Deploy #183 / run `36159592728` = PASS;
- Worker exact source = #416 head `b650ce8...`;
- deployed trigger list contains only `mish.alegria.by (custom domain)`;
- Worker version = `cd481e60-a625-4c78-9eaf-5bec630a4308`.

Final physical acceptance after removing the legacy route:

- Device Cycle #841 / run `36159721069` = PASS;
- exact installed bytes/signing identity = PASS;
- CONTROL host = `mish.alegria.by`;
- remote classification = `U8_REMOTE_CONTROL_ROTATION_PASS`;
- terminal = `CHANGED`;
- one logical/public command; polling=0;
- manager duration = 14881 ms;
- heartbeat delta=3 / reconnect delta=0;
- POWER_OFF gate = PASS;
- independent external public-IP proof = CHANGED / consensus=true;
- final Cellular/root/Proxy/Mesh/readiness and both proxy E2E checks = PASS;
- final evidence artifact `10874304341`, digest `sha256:e0e0fe1bf009ab396d2e3987229b044b1004ce9cbcf65a048aceca0f905c6b19`.

No Rotation state machine, Cellular/root policy, retry/polling owner or Worker/DO ownership boundary was added by this migration. The only PRODUCT semantic input changed is the canonical CONTROL hostname.


## Post-U8 — CONTROL same-request delivery recovery — COMPLETED / PASS

Issue #419 was opened from a real production delivery race observed after the unified `mish.alegria.by` migration:

```text
one public POST
 -> Worker socket.send()
 -> no PRODUCT ACCEPTED inside 2 s
 -> UNKNOWN / TIMEOUT / dispatched=true / device_online=false

later manual public POST
 -> BUSY / device_online=true
```

The evidence showed that the initial Worker dispatch crossed the broker boundary, the PRODUCT delivery ACK was not observed before the short delivery deadline, and the Rust/Tokio session later recovered naturally while the existing fail-closed drain correctly prevented a second logical Rotation.

The accepted refinement remains Worker/DO-only:

```text
DISPATCHED attempt 1
 -> ACCEPTED
 -> or 2 s ACK miss -> RECOVERING

RECOVERING
 -> late ACCEPTED/RESULT: accept normally
 -> natural authenticated Rust/Tokio reconnect:
      READY
      redeliver the SAME request_id exactly once
      DISPATCHED attempt 2
 -> bounded recovery expiry -> FENCED

DISPATCHED attempt 2
 -> ACCEPTED
 -> or 2 s ACK miss -> existing 120 s FENCED drain
```

Ownership invariants remain unchanged:

- Rust/Tokio remains the only WSS reconnect/heartbeat owner;
- Rust/Tokio remains the only Rotation owner;
- PRODUCT request-id idempotency remains authoritative;
- Worker never initiates reconnect;
- Worker never creates a replacement request_id for recovery;
- one public POST still represents one logical command;
- no manager polling, retry-until-CHANGED or Android/Kotlin recovery owner was introduced.

Accepted implementation/evidence:

- issue #419 = CLOSED / PASS;
- implementation PR #420 exact accepted head = `222eaf79b3187a8b516414cc21127a0d6204ce17`;
- protected-main merge = `a102ad4c313ccc3035f2fc14869d9eb01679ecbb`;
- accepted PR tree = protected-main tree = `94c124c9da0d4bf4e3319bc00c18fde5ffffb3d0`;
- U8 Control Static #103 / run `36163220525` = PASS;
- PR Validation #1103 / run `36163220584` = PASS;
- `PRODUCT_CHANGED=false`;
- deterministic Durable Object tests cover RECOVERING, no forced reconnect, one same-request redelivery, late ACCEPTED, second-ACK fencing, recovery expiry, BUSY during uncertainty, and manager completion through recovered delivery;
- Control Worker Deploy #190 / run `36163352981` = PASS;
- deployed Worker version = `fa4da7ee-8c99-4022-85d6-675baaa577e2`;
- physical no-regression Device Cycle #849 / run `36163926660` = PASS / `U8_REMOTE_CONTROL_ROTATION_PASS`;
- physical result = CHANGED, one public command, one logical Rotation, polling=0;
- manager duration = 13277 ms;
- heartbeat delta=3 / reconnect delta=0;
- POWER_OFF gate = PASS;
- independent public-IP proof = CHANGED / consensus=true;
- post PRODUCT Cellular/root/Proxy/Mesh/readiness and both proxy E2E checks = PASS;
- physical evidence artifact `10876549670`, digest `sha256:72ae554daaafbdf512d5af3be6ab1f9771e4feb515fed7e7aea97e0c2857644c`.

The physical run intentionally validates normal production behavior after the Worker change. The rare reconnect race itself is proven deterministically in the hosted Durable Object harness rather than by artificially breaking DEVICE-1 WSS.


## Current accepted post-U8 remote-rotation contract

The historical #373/#376 recovery sections below remain evidence of how the design evolved. They are **not** the current runtime contract.

Current accepted remote-control boundary after #379, #413 and #419:

```text
host = mish.alegria.by

Rust/Tokio
  = sole WSS reconnect + heartbeat owner
  = sole Rotation owner
  = PRODUCT request-id idempotency owner

Worker / Durable Object
  = manager auth + correlation
  = fresh-session proof
  = one 2 s initial delivery-ACK boundary
  = if first ACK is lost: bounded RECOVERING
  = on natural authenticated Rust reconnect:
      redeliver the SAME request_id at most once
  = no Worker-triggered reconnect
  = no replacement request_id
  = existing fail-closed FENCED drain if uncertainty remains

public manager
  = POST https://mish.alegria.by/v1/rotate
  = empty body
  = one typed response
  = no polling
  = no hidden retry/replay
```

Current accepted timing/safety constants:

- Rust/Tokio CONTROL heartbeat interval = **4 s**;
- Worker fresh-session window = **10 s**;
- initial delivery ACK boundary = **2 s**;
- manager HTTP ceiling = **18 s**;
- SDK/LAB client ceiling = **20 s**;
- accepted-result / fail-closed drain remains **120 s**;
- typed POWER_OFF remains mandatory before airplane restore;
- CHANGED and UNCHANGED are equally valid successful Rotation outcomes.

Current accepted identities:

- protected main at research start = `05a57f7988295a6af3e7fadcef0f35023ea7c618`;
- accepted Android/Rust PRODUCT = `db3abd4ec7225f46004afa8b3dd54a1d391fa958`;
- live Worker after #419 = `fa4da7ee-8c99-4022-85d6-675baaa577e2`.

### Current measurement-only research — issue #422

Issue #422 is the **only active latency/stability research owner**. It does not define a new PRODUCT stage and authorizes no code or timeout change.

Triggering external sample after #419:

| sample | terminal | server duration | external HTTP total |
|---|---|---:|---:|
| op 2 | CHANGED | 16,951 ms | 17.337 s |
| op 3 | CHANGED | 11,205 ms | 11.521 s |
| op 4 | CHANGED | 11,647 ms | 11.965 s |
| op 5 | CHANGED | 16,984 ms | 17.351 s |

For this small N=4 sample:

- success = 4/4;
- server min / median / max = **11,205 / 14,299 / 16,984 ms**;
- server mean = **14,196.75 ms**;
- observed spread = **5,779 ms**.

Do not infer a stable bimodal distribution from four observations.

The next research question is whether the ~11 s versus ~17 s spread is still dominated by the already-attributed physical phase:

```text
rearm complete
 -> modem/carrier + Android framework reacquisition
 -> first Cellular callback enters Rust
```

The research must use a bounded predeclared sample, preserve one public command -> one logical Rotation, stop on UNKNOWN/BUSY/unhealthy post-state, and make no implementation change unless a repeated material `PRODUCT_AVOIDABLE` phase is demonstrated.

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

Do not open a planning issue for every subtask. A stage-specific issue exists only when it materially improves execution/evidence traceability. Issue #135 is the single live pointer. A bounded research issue such as #422 may be active without creating or reopening a PRODUCT stage.

A failed gate does not create a new roadmap stage: fix only the surfaced defect on the same line and rerun the exact gate.

## Supersession rule

When old #134 archive comments or older #135 checkpoints conflict with this document because architecture has since changed, this document defines the current order. Historical comments remain useful rationale/evidence but must not resurrect removed components or obsolete optimization targets.
