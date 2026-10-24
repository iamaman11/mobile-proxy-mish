# MISH Product Roadmap

Status: **CANONICAL PRODUCT / ARCHITECTURE ROADMAP**.

This document is the single ordered development plan for Mobile Proxy MISH. It intentionally stays compact. Detailed historical evidence belongs in the stage/research issues, pull requests and immutable workflow artifacts, not in a second competing roadmap.

Authority order:

```text
PRODUCT_ROADMAP.md                  -> accepted architecture + ordered product direction
Issue #135                          -> current exact execution pointer only
stage/research issue + PR           -> bounded implementation/evidence
SYSTEM.md / DEPENDENCIES.md         -> accepted system/dependency detail
EXECUTION.md / ACCEPTANCE.md        -> process/evidence rules
Git history / closed issues         -> historical rationale and superseded mechanisms
```

When an older issue body/comment conflicts with a later accepted implementation and evidence, the later accepted authority recorded here wins. Historical text is evidence of what was known at the time; it must not resurrect removed mechanisms.

---

# Current accepted authority

The live `PROTECTED_MAIN` SHA/tree is read directly from GitHub; Issue #135 is the sole exact execution checkpoint. Do not freeze a moving branch pointer in this roadmap. The fixed SHA below is the historical **final accepted PRODUCT-changing commit**, not today's `main` ref.

```text
FINAL_ACCEPTED_PRODUCT = 523f5d1c616bd92b404ad30c136308d2a0ae0e40
FINAL_ACCEPTED_PRODUCT_TREE = 9676b88a418682d497249225552f6b4fe370cdf0
CURRENT_STAGE = Candidate A rotation authority accepted; no active PRODUCT implementation stage
CURRENT_IMPLEMENTATION_ISSUE = #450 CLOSED / PASS
CURRENT_IMPLEMENTATION_PR = #451 MERGED
CURRENT_RESEARCH_ISSUE = #425 CLOSED / PASS / promoted
```

The accepted PRODUCT IP-rotation primitive is now:

```text
before public-IP proof
 -> observe mobile data ENABLED
 -> exactly one mobile-data DISABLE
 -> wait for authoritative Android NetworkCallback.onLost()
 -> typed Cellular NetworkLost
 -> exactly one mobile-data ENABLE
 -> strictly fresh Cellular generation B > A
 -> exact root-policy authorization for B
 -> readiness / Proxy / Mesh recovery
 -> after public-IP proof
 -> CHANGED | UNCHANGED observable terminal result
```

Critical accepted invariant:

```text
NotValidated / generic NotAdmitted != detach complete
NetworkCallback.onLost() / typed NetworkLost = detach complete
```

The previous airplane + typed POWER_OFF path is **historical rollback evidence**, not an active PRODUCT algorithm and not a runtime fallback. Do not reintroduce a dual algorithm, feature flag or automatic airplane fallback without new contrary physical evidence and an explicit architecture decision.

## Final Candidate A acceptance

Physical promotion proof:

```text
Device Cycle #923
run_id = 38516316171
PRODUCT source = 35a39fa748fe73f25ae409d4fd064eefb044983a
CONTROL = e810075593981b7ff8e4130ef1e95322688e472e
result = PASS
PRODUCT terminal = CHANGED
independent external observer = CHANGED
observer consensus = true
Cellular generation = 1 -> 4
```

Key monotonic timing evidence:

```text
data disable start             461 ms
authoritative NetworkLost     1352 ms
data enable start             1357 ms
fresh Cellular generation 4   4167 ms
root authorized generation 4  6163 ms
post-IP probe start            6168 ms
Rotation terminal              6572 ms
```

Evidence artifact:

```text
id = 11871449205
sha256 = 8aad0390fe615315fd8c6b6c71965f7242c7f56a6d632854c02d49bf68136e50
```

Post-acceptance health proof:

```text
Device Cycle #925
run_id = 38516560931
mode = diagnose_only
result = PASS / READY
no install
no Rotation
no reboot/replacement mutation
```

Evidence artifact:

```text
id = 11871357860
sha256 = 2908936cf335fcbf5a6897536752693e8438bc1319532bce0c78f0ea73c7ada8
```

Strict current-main hosted validation after CONTROL synchronization:

```text
PR Validation + PRODUCT Candidate #1186
run_id = 38517050780
head = 1c096957b3887652622067c2ee5e83752a5075a4
Rust Workspace = PASS
Android Build/Test = PASS
Android Compose Shell = PASS
U8 Control Static = PASS
```

The strict-sync head changed only the already accepted two CONTROL acceptance files relative to the physically tested PRODUCT tree; Rust/Android PRODUCT source remained identical. Hosted APK containers may carry transient Android-debug signing-block differences between builds, but DEVICE-1 delivery re-signs candidates with the durable LAB PKCS#12 identity and verifies installed bytes/signing identity before physical acceptance.

## Rotation result semantics

`CHANGED` and `UNCHANGED` are both honest observable terminal API/state-machine results. They must never be hidden or retried away.

However:

```text
PRODUCT operation semantics:
  CHANGED or UNCHANGED = valid measured terminal result

promotion/effectiveness acceptance of an IP-changing primitive:
  requires one bounded real CHANGED confirmed by an independent observer
```

Therefore `UNCHANGED` is evidence, not Candidate A promotion PASS. No retry-until-CHANGED is permitted.

---

# Product architecture laws

MISH is a rooted-Android mobile proxy appliance optimized for simple ownership, deterministic recovery and exact physical evidence.

Core law:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Accepted ownership model:

```text
Android / Kotlin
  = platform effects, platform observations, presentation
  != PRODUCT state machine / retry / recovery owner

mish-runtime
  = one process-wide Tokio execution owner
  = retained task/cancellation/drain tree

mish-rotation
  = sole IP Rotation semantic owner

mish-cellular
  = Cellular admission/currentness/generation owner

root policy + RootSessionManager
  = exact current-generation route authority
  = one persistent process-wide su transport

mish-transport
  = external Mesh admission and external capacity authority

mish-proxy
  = HTTP CONNECT / SOCKS5 / mixed protocol, auth and target semantics

Cloudflare One Agent
  = only Android VPN owner

Worker / Durable Object
  = remote manager auth, correlation and bounded delivery state
  != Rotation owner
```

Do not introduce without a demonstrated requirement:

- a second Rotation/lifecycle/readiness/Cellular owner;
- a second Tokio runtime or long-lived executor;
- a generic root shell API or root daemon/helper;
- a second VPN/TUN owner;
- a mutable duplicate status database;
- Wi-Fi/default/WARP public-egress fallback;
- Android/Kotlin retry/recovery state machines;
- generic plugin/framework abstractions without a concrete product need;
- blind retries of uncertain mutations;
- sleeps/dwell used to manufacture correctness.

---

# Accepted delivery model

Candidate production and physical acceptance remain evidence-first:

```text
source PR exact head
 -> hosted compile/lint/tests
 -> exact candidate artifact
 -> Windows LAB downloads artifact
 -> durable LAB signing identity
 -> install without local rebuild
 -> verify installed bytes + signer
 -> one explicitly authorized physical mutation when required
 -> bounded evidence
 -> post-health diagnostic
 -> merge exact accepted source authority
```

Promotion must not rebuild a logically different candidate. A physical failure is evidence: stop, inspect read-only evidence, fix the demonstrated defect, then run a new deliberately authorized bounded attempt. Never blind-retry a physical operation merely to obtain a preferred result.

---

# Accepted remote-control contract

Canonical host:

```text
mish.alegria.by
```

Public manager contract:

```text
POST https://mish.alegria.by/v1/rotate
empty body
one typed response
no manager polling
no caller-provided request_id
no hidden replay/retry
```

Ownership:

```text
Rust/Tokio
  = sole WSS reconnect + heartbeat owner
  = sole Rotation owner
  = PRODUCT request-id idempotency owner

Worker / Durable Object
  = manager authentication
  = session freshness proof
  = request correlation
  = bounded same-request delivery recovery
```

Accepted CONTROL timing/safety constants remain governed by the completed CONTROL issues (#379, #413, #419 and successors). Candidate A changed only the physical middle of Rotation; it did not move CONTROL, manager, credential or provider ownership.

A temporary WSS/CONTROL failure must not be confused with a physical-rotation failure. Candidate A effectiveness can be tested locally through the same Rust Rotation owner plus independent public-egress observation, as proven by #923.

---

# Completed product stages

The detailed evidence for these stages remains in their issues/PRs and Git history. They are not reopened by default.

```text
U1  L8 architecture closure                                  COMPLETED
U2  native DEVICE-1 acceptance / physical re-baseline        COMPLETED
U3  recovery, observability and lifetime convergence         COMPLETED
U4  cellular/public-egress ownership and exact networking    COMPLETED
U5  IP Rotation state machine / public egress proof          COMPLETED
U6  deterministic delivery / lifecycle hardening             COMPLETED
U7  capacity, resource and durability acceptance             COMPLETED
U8  remote control / final clean-client acceptance           COMPLETED
```

Post-U8 accepted work includes:

- consumer-facing typed .NET rotation SDK (#410/#411);
- unified `mish.alegria.by` control hostname (#413/#416);
- CONTROL same-request delivery recovery (#419/#420);
- bounded rotation timing research (#422);
- narrower cellular primitive research (#425);
- Candidate A PRODUCT promotion (#450/#451).

Historical airplane/POWER_OFF evidence remains useful for regression archaeology and Git rollback, but it is no longer the current physical Rotation contract.

---

# Current operating baseline

A healthy current PRODUCT instance requires owner-backed facts, not historical implementation artifacts:

- runtime running;
- Cellular ADMITTED/current;
- exact-generation root policy authorized;
- Proxy RUNNING / healthy;
- Mesh ADMITTED with current epoch and ingress healthy;
- Android readiness READY;
- credential lease available;
- loopback proxy E2E PASS;
- Mesh proxy E2E PASS;
- no leaked active Rotation/recovery tasks;
- no raw public IP or secret persistence.

The post-Candidate-A `diagnose_only` #925 proves this baseline after a successful real IP change.

---

# Change discipline

Use the smallest logical owner-local change, not the smallest textual diff and not a chain of micro-PRs.

For any new work:

```text
1. restore live authority from protected main + #135;
2. state the concrete product requirement or observed failure;
3. identify the natural owner;
4. prefer deletion/simplification over another compatibility layer;
5. complete independent hosted work in one logical slice;
6. run one exact hosted gate;
7. use DEVICE-1 only for facts impossible to prove hosted;
8. on first physical failure: STOP and classify read-only evidence;
9. record accepted evidence and update #135 only after acceptance;
10. merge exact accepted authority; no speculative follow-on mutation.
```

No new stage exists merely because an old issue remains open. Close research/implementation issues once their question is resolved so they cannot become accidental competing authority.

---

# Current next-step rule

There is **no active PRODUCT implementation stage after Candidate A acceptance** at this checkpoint.

Do not invent another optimization stage. The next PRODUCT slice starts only from a concrete user/product requirement, observed defect, or explicitly chosen roadmap goal. Until then:

```text
protected main = latest accepted PRODUCT + CONTROL authority (fetch live SHA)
523f5d1c... = historical final PRODUCT-changing commit at this checkpoint
Candidate A = active IP-rotation primitive
#425 = closed research history
#450/#451 = closed accepted implementation
#923 = physical effectiveness proof
#925 = post-change health proof
```

Issue #135 is the only dynamic execution cursor for the current `main` SHA, accepted PRODUCT lineage and active PR, without replaying historical evidence in this roadmap.
