# U7 Capacity Scaling Acceptance

Status: **BOUND U7 EXECUTION / ACCEPTANCE PLAN**.

This document refines the U7 `Efficiency and long-run hardening` stage from `PRODUCT_ROADMAP.md`. It does not change roadmap order, does not change the current U2 stage, and does not change the currently accepted PRODUCT capacity.

## Current production baseline

The accepted external Mesh capacity remains:

```text
64 admitted sessions
65th rejected at the mish-transport edge
```

That value remains the shipped PRODUCT contract until a later capacity promotion satisfies this document and is accepted by a separate PRODUCT change.

Capacity is a `mish-transport` admission policy fact. The one process-wide Tokio runtime in `mish-runtime` owns execution, cancellation and drain, but it must not become a second external-capacity authority.

## Why capacity scaling is U7

U2 proves that the final native/Tokio topology is correct and physically stable at the accepted 64-session PRODUCT limit. U3-U6 then stabilize recovery/observability, add generation-bound public IP, add rotation, and expose backend state in the product UI.

Only after those semantics are stable do we deliberately ask whether the accepted external capacity can be raised without weakening fail-closed behavior, session liveness, recovery, resource headroom or operational safety.

Therefore capacity increase is not part of U4 and is not silently coupled to unrelated feature work.

## Exploration ladder

Run capacity exploration as LAB-only steps:

```text
64 baseline
 -> 128 candidate
 -> 256 candidate
 -> 512 candidate only if prior tiers remain healthy and there is a demonstrated product need
```

Do not skip directly from 64 to 512. A tier is explored only after the previous tier has conclusive accepted evidence.

The candidate limit may be injected only through a bounded LAB/test control surface. Do not mutate the shipped PRODUCT limit merely to explore a larger number.

## Per-tier functional acceptance

For every candidate capacity `N`, prove all of the following on the exact tested PRODUCT bytes and current physical topology:

1. `N` full external Mesh paths become application-live.
2. `mesh.active_sessions == N` and `proxy.active_sessions == N` while all admitted sessions remain live.
3. Attempt `N + 1` is rejected at the `mish-transport` edge before Proxy admission/status.
4. The rejected overflow attempt does not increase accepted owner counts.
5. The original `N` sessions remain application-live after overflow.
6. A bounded overflow burst above `N` does not evict existing sessions or destabilize the runtime.
7. Cleanup returns both natural owner counts to `0`.
8. A fresh post-cleanup Mesh E2E probe passes.
9. No Wi-Fi/default/WARP public-egress fallback occurs.
10. Runtime/PRODUCT PID and owner generation remain stable unless a test explicitly exercises lifecycle recovery.

Collection membership alone is never sufficient. Session liveness must be proved with real application traffic.

## Per-tier resource acceptance

Record the same measurement family at idle, intermediate load points, capacity `N`, overflow and post-cleanup:

- PRODUCT thread count;
- file descriptors;
- RSS/PSS where available;
- CPU and wakeup cost where measurable;
- connect latency distribution;
- DNS latency distribution;
- accept/reject latency;
- cleanup/drain duration;
- recovery-to-fresh-READY duration after a bounded failure/recovery cycle;
- Tokio task/relay cleanup observations available from bounded diagnostics;
- root-shell process count and root reconcile command/latency observations;
- thermal/battery observations during longer physical runs.

The evidence must show bounded return toward the baseline after cleanup. Monotonic resource growth across repeated cycles is a failure even if `N` connections initially work.

## Repetition / long-run gate

A capacity tier is not promotable from one lucky burst.

After the single-cycle functional/resource proof succeeds, run repeated bounded cycles at the candidate tier and verify:

```text
open -> application-live -> overflow rejection -> original sessions remain live -> cleanup -> fresh E2E
```

Repeated cycles must not show unbounded FD/thread/task/memory growth, increasing cleanup time, orphan sessions, detached relay work, root-shell proliferation or progressive latency degradation.

The exact repetition count and duration should be selected from observed runtime cost and the U7 measurement budget; they must be recorded in evidence rather than hidden in the harness.

## Promotion rule

A larger capacity becomes a PRODUCT candidate only if both conditions are true:

```text
physical evidence says the tier is healthy
AND
there is a demonstrated product requirement for the higher limit
```

A technically possible larger number is not by itself a reason to increase the shipped limit.

If a tier is selected for promotion:

1. change the canonical PRODUCT limit in its natural owner (`mish-transport`) in a dedicated PRODUCT PR;
2. update architecture/contract guards for the new explicit value without moving ownership;
3. produce new immutable hosted candidate bytes;
4. rerun exact-head hosted gates;
5. repeat physical capacity/resource/recovery acceptance at the promoted limit;
6. update the current-stage checkpoint with the accepted exact SHA/evidence;
7. only then treat the new value as the production contract.

Until that sequence completes, PRODUCT capacity remains 64.

## Relationship to U8

U8 release/durability acceptance uses whichever production capacity has actually been promoted and accepted by the end of U7.

If no larger tier satisfies the evidence/need threshold, U8 proceeds with 64. There is no roadmap requirement that U7 must increase the limit.

## Exit criteria

U7 capacity work is complete when either:

```text
A) 64 is retained with evidence that higher tiers do not justify promotion
```

or:

```text
B) a higher tier is promoted by a dedicated PRODUCT change and passes exact hosted + physical acceptance
```

The result must leave exactly one canonical external capacity value and exactly one natural capacity owner (`mish-transport`).
