# U7 Post-Tokio Capacity Envelope Characterization

Status: **BOUNDARY / EVIDENCE PLAN UNDER THE CANONICAL PRODUCT ROADMAP**.

This document elaborates the U7 `Efficiency and long-run hardening` capacity work. It does not change stage ordering and does not replace `docs/architecture/PRODUCT_ROADMAP.md`.

## Purpose

After U2 has converged Mesh ingress/session execution onto the one process-wide Tokio runtime and has physically proven the existing PRODUCT contract of 64 simultaneously application-live full paths with deterministic rejection of the 65th external session, measure the physical capacity headroom of the resulting native architecture.

The purpose is to learn the safe operating envelope before deciding whether any future PRODUCT capacity change is justified.

The characterization must not assume that one proxy user equals one TCP session. Capacity is measured primarily in simultaneously application-live proxy sessions and secondarily in realistic multi-client workload shapes.

## Contract boundary

The shipped PRODUCT contract remains:

```text
external accepted-session budget = 64
65th external session = deterministic reject at mish-transport edge
```

The capacity study must **not** silently raise the shipped PRODUCT limit, move capacity ownership into `mish-runtime`, or create a second capacity authority.

`mish-transport` remains the sole owner of external admission/capacity semantics. If physical characterization above 64 requires a higher ceiling, use a deliberately LAB-only/test-only override at the same `mish-transport` admission boundary. The override must be impossible to activate in release PRODUCT and must not introduce another counter, scheduler, lifecycle owner or runtime.

No production capacity increase is accepted merely because a larger LAB run succeeds once.

## Preconditions

Do not run the >64 envelope characterization until all of the following are true on the exact post-convergence candidate:

```text
ONE mish-runtime Tokio execution owner proven
thread-per-session Mesh execution removed
application_live=64
mesh.active_sessions=64
proxy.active_sessions=64
65th external session rejected at mish-transport edge
original 64 remain application-live after overflow attempt
post-cleanup mesh.active_sessions=0
post-cleanup proxy.active_sessions=0
fresh external Mesh E2E=PASS
```

U2 acceptance remains valid independently of any later >64 result. The mandatory PRODUCT acceptance contract is still 64/65.

## Capacity sweep

Run a bounded LAB characterization on the same physical DEVICE-1 and current real data path:

```text
Windows client(s)
 -> Cloudflare Mesh
 -> exact current Android Mesh endpoint
 -> mish-transport
 -> mish-runtime / one Tokio task tree
 -> mish-proxy
 -> Cellular Egress
 -> Internet
```

Characterize, in order:

```text
64
128
256
512 only if the previous level remains healthy and inside resource/latency budgets
```

Do not jump directly to the largest level. Stop expansion at the first level that loses application liveness, violates a resource/latency budget, destabilizes cleanup/recovery, or makes the device thermally/operationally unhealthy.

Additional intermediate points may be used only to localize the knee after a boundary appears; do not turn this into an unbounded benchmark search.

## Definition of an application-live session

A client object, connected socket flag, completed TCP handshake or one historical TLS handshake is not sufficient.

A session counts as application-live only when a fresh bounded request/response round trip succeeds through the same already-established proxy tunnel and, where applicable, the same TLS connection.

For every reported capacity level, prove that the claimed live count corresponds to real concurrent application traffic rather than retained client objects.

At each milestone, owner observations must be sampled together with client application liveness:

```text
application_live
mesh.active_sessions
proxy.active_sessions
```

Any divergence must be investigated before the milestone can be used as capacity evidence.

## Measurements at every level

Record at minimum:

```text
application-live sessions
aggregate throughput
per-session or workload-normalized throughput
connect latency p50 / p95 / p99
application round-trip latency p50 / p95 / p99
process CPU
system CPU where available
RSS / PSS
FD count
thread count
connection/setup failures
unexpected session terminations
Mesh owner count
Proxy owner count
Cellular throughput
cleanup/drain time
recovery behavior
battery/thermal observations when materially changed
```

Also record whether thread count remains approximately independent of session count after deletion of the old Mesh `session thread + copy thread` execution model.

FD growth is expected to remain at least partly linear because real TCP paths require sockets. Measure the post-Tokio FD-per-live-path slope and distinguish unavoidable path sockets from avoidable duplicate/cloned descriptors before proposing further optimization.

## Throughput and latency discipline

A capacity point is not healthy merely because N tunnels can remain idle.

Each point must include sustained application traffic sufficient to exercise bidirectional relay and Cellular egress. Report both concurrency and traffic intensity so that a high-session/near-zero-traffic run cannot be mistaken for a useful operating envelope.

Track latency distributions rather than only averages. A point with all sessions technically alive but severe p95/p99 degradation is not equivalent to a healthy operating point.

## Real-client workload shapes

Session capacity is not user capacity. In addition to the raw session-count sweep, characterize at least these workload shapes with comparable total concurrency/traffic where practical:

```text
1 heavy client
10 medium clients
25-50 light clients
```

Define each workload explicitly in the test artifact by:

```text
number of clients
sessions per client
request rate / traffic rate
request size or bounded workload profile
total concurrent application-live sessions
```

The goal is to understand how the appliance behaves when the same session budget is distributed differently across real proxy clients, not to assign a fixed number of users to a session count.

## Cleanup and recovery at every stress boundary

After each major level, close all test clients and require bounded convergence to:

```text
mesh.active_sessions=0
proxy.active_sessions=0
no detached long-lived Mesh/Proxy tasks
FD near baseline
threads near baseline
PID/runtime generation stable unless the test explicitly includes restart/recovery
fresh authenticated external Mesh E2E=PASS
```

A capacity level that works only until cleanup or recovery is not a healthy capacity level.

## Safe operating envelope

The characterization output must identify at least:

```text
highest level with full application liveness
first observed degradation level, if any
resource slope vs live sessions
latency slope vs live sessions
throughput saturation point, if observed
cleanup/recovery behavior
thermal/battery constraint, if observed
```

Do not set the PRODUCT limit equal to the absolute maximum observed successful point.

If a future capacity increase is considered, choose a production value below the demonstrated physical boundary with explicit operational headroom for control work, recovery, traffic bursts and device variability.

## Decision rule for changing PRODUCT capacity

After the characterization, one of these outcomes is recorded:

```text
KEEP_64
RAISE_TO_FIXED_PROVEN_LIMIT
MAKE_CAPACITY_CONFIGURABLE_WITH_BOUNDED_RANGE
INCONCLUSIVE_KEEP_64
```

Default to the simpler fixed limit when 64 comfortably satisfies the product requirement.

A change above 64 requires a separate accepted PRODUCT change with:

- demonstrated product need, not benchmark curiosity;
- repeated physical evidence on the supported device;
- explicit safety/headroom margin below the observed degradation boundary;
- preserved `mish-transport` ownership of the external capacity decision;
- updated 64/65-style boundary tests for the new limit (`N accepted`, `N+1` rejected);
- updated resource/recovery acceptance;
- no second executor, counter, lifecycle owner or Android-side admission policy.

A configurable capacity is justified only if multiple supported deployment profiles materially need different limits. Do not add configuration merely because the Tokio architecture can technically support it.

## Expected evidence shape

The final U7 report should make comparison easy, for example:

```text
level | app-live | mesh | proxy | throughput | p50 | p95 | p99 | CPU | RSS/PSS | FD | threads | cleanup
64    | ...
128   | ...
256   | ...
512   | ... or NOT_RUN
```

and separately:

```text
workload             | clients | sessions | traffic | throughput | p95/p99 | failures | resources
1 heavy client       | ...
10 medium clients    | ...
25-50 light clients  | ...
```

## Non-goals

This characterization is not permission to:

- increase PRODUCT capacity before evidence exists;
- optimize around synthetic connection count while real application traffic regresses;
- add another Tokio runtime or thread pool;
- move external admission policy from `mish-transport` to `mish-runtime`;
- introduce a generic scalability framework;
- remove clean ownership boundaries merely to reduce one metric without profiling evidence.

The sequence is:

```text
U2: prove PRODUCT 64 live + reject 65th
 -> record exact post-Tokio resource baseline
 -> U7 LAB characterization at 64 / 128 / 256 / optionally 512
 -> realistic multi-client workloads
 -> determine safe operating envelope
 -> only then decide whether PRODUCT capacity should remain 64 or change
```
