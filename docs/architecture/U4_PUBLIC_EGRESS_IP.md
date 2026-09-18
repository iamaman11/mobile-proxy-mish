# U4 Generation-bound Public Egress IP

Status: **CLOSED / PASS — ACCEPTED PRODUCT CONTRACT**.

This document refines the U4 stage from `PRODUCT_ROADMAP.md`. U4 is not a capacity-scaling stage.

## Purpose

U4 gives PRODUCT one authoritative answer to this question:

```text
For the current Cellular Egress generation, what public IP address does the Internet observe?
```

That fact is required by U5 rotation and U6 UI. Without it, a `Change IP` operation can only prove that radio/network state changed; it cannot prove whether the public egress identity actually changed.

## Ownership

```text
Cellular Egress -> current generation-bound public egress IP observation
Rotation        -> before/after observations and CHANGED / UNCHANGED / FAILED result
UI              -> projection only
```

No new lifecycle, network or readiness owner is introduced.

## Exact path

The probe must use the same allowed public-egress authority as PRODUCT traffic:

```text
current Cellular owner generation
 -> current root-policy authorization
 -> owner-bound/network-scoped cellular DNS
 -> ordinary PRODUCT-UID public socket
 -> root-policy-gated current cellular route
 -> TLS/HTTPS
 -> bounded public-IP endpoint
```

It must never fall back to Android default networking, Wi-Fi or WARP for the public request. Public-path authority comes from the current Cellular owner generation plus root-policy routing, not from Android per-socket network binding.

## Generation binding

The result is valid only for the Cellular generation that initiated it.

If the Cellular owner changes while DNS/request/response work is in flight, the completion is stale and must be rejected. A stale completion must not update the current public-IP fact.

## Probe contract

The implementation must provide:

- one deliberately selected public-IP endpoint owned in one place;
- owner-bound/network-scoped cellular DNS;
- ordinary PRODUCT-UID public socket through the current root-policy-gated cellular route;
- no `Network.bindSocket`, `android_setsocknetwork` or equivalent per-socket network pinning;
- TLS certificate validation;
- absolute end-to-end deadline;
- tiny bounded response size;
- strict IPv4/IPv6 parsing;
- generation/currentness check before publishing the result;
- typed failure classification;
- no secret/raw-response logging.

Raw public IP may be shown locally to the operator but must not be persisted into GitHub evidence, analytics or durable diagnostic logs. Durable acceptance evidence records only semantic facts such as `KNOWN`, `CHANGED`, `UNCHANGED`, `FAILED`, generation IDs/timings where safe, and failure classification.

## Physical acceptance

On DEVICE-1 prove:

1. baseline PRODUCT is READY on a known current Cellular generation;
2. public-IP observation succeeds through the exact Cellular path;
3. Wi-Fi/default/WARP cannot satisfy the probe if the Cellular authority is unavailable;
4. an in-flight result from an old generation is rejected after a generation transition;
5. a fresh generation can produce a fresh observation;
6. bounded timeout/failure leaves the current owner/readiness model fail-closed and does not create a fallback path;
7. repeated observations do not leak sockets/tasks/workers or create unbounded resource growth.

## Relationship to U5

U5 consumes this fact as:

```text
before_ip @ generation A
 -> bounded rotation
 -> fresh generation B
 -> after_ip @ generation B
 -> CHANGED | UNCHANGED | FAILED
```

U4 therefore measures identity; U5 changes the network and compares identities.

## Non-goals

U4 does not:

- increase the 64-session capacity;
- change Mesh admission policy;
- own rotation;
- own UI state;
- add a second networking stack;
- add Cloudflare control-plane dependencies to PRODUCT.

Capacity exploration belongs to U7 and is defined separately in `U7_CAPACITY_SCALING.md`.

## Exit criteria

U4 exits when the current Cellular generation has one bounded, exact-path, stale-safe public-egress-IP observation API with hosted contract coverage and physical DEVICE-1 evidence, ready for consumption by U5 rotation and U6 presentation.

## Accepted closure

Exit criteria are satisfied.

Accepted PRODUCT candidate:

```text
7ba2f35233c418920ad97885eee9372f7e9117b9
tree = c02f858882c1a6e2be1392a76410d3cd5d897f80
```

Evidence:

- CI #708 = PASS;
- Integration Android Preflight #353 = PASS;
- Device Cycle #289 / run `35373265701` = PASS;
- classification = `U2_RECOVERY_LIFECYCLE_PASS`;
- exact candidate acceptance = `PASS`;
- U4 semantic evidence = positive HTTPS, owner-bound DNS, ordinary PRODUCT-UID socket, stale-generation rejection, no default fallback, fresh-generation recovery, bounded repeated observations and `raw_ip_persisted=false`.

Accepted protected PRODUCT main:

```text
64482bfa1c5ba6bb2980839b58046742c2b13f19
tree = c02f858882c1a6e2be1392a76410d3cd5d897f80
```

The exact candidate and protected-main PRODUCT trees are byte-identical. U5 may consume this API; U4 must not be reopened by adding a second public-IP owner, a second DEVICE control plane or Android per-socket network binding.
