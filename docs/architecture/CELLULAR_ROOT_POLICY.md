# Cellular root-policy execution contract

This document records the concrete infrastructure contract below the existing Cellular Egress natural owner. It does not create another owner or readiness state.

## Ownership

```text
ConnectivityManager observations
 -> Rust `crates/cellular`
    = sole owner of admission + generation/currentness
 -> Kotlin `CellularRootPolicy`
    = one typed PRODUCT root adapter
 -> kernel mangle/RPDB mechanics
```

The adapter exposes no arbitrary shell API. Root commands are private implementation details behind typed results and typed failures.

## Admission and fail-closed base

The semantic admission predicate is exactly:

```text
CELLULAR + INTERNET + VALIDATED + NOT_VPN
```

Before that predicate is true, PRODUCT may establish only the fail-closed base after verifying PRODUCT root authority. A permitting IPv4 cellular lookup is installed only for the exact current ADMITTED owner generation.

For every new owner generation the adapter:

1. snapshots live IPv4/IPv6 RPDB and mangle state;
2. resolves exactly one PRODUCT policy identity from the bounded candidate set or fails closed;
3. ensures the matching fail-closed guards;
4. revokes any stale PRODUCT IPv4 cellular lookup for that identity;
5. reconciles the exact MISH flow-mark policy;
6. only for ADMITTED, rediscovers and validates the current cellular route table;
7. installs exactly one current IPv4 lookup and verifies the resulting marked route.

Loss/recovery therefore cannot reuse a stale route-table decision.

## Flow identity and continuity

PRODUCT does not assume that one globally fixed mark/priority tuple is available on every supported target topology. The DEVICE-1 QA finding proved that the original `0x200000 / 9500 / 9501` tuple can collide with pre-existing foreign policy state. The accepted infrastructure contract is therefore one **small deterministic candidate set**, currently ordered as:

```text
mark 0x200000  -> IPv4 lookup 9500 -> guard 9501
mark 0x400000  -> IPv4 lookup 9520 -> guard 9521
mark 0x800000  -> IPv4 lookup 9540 -> guard 9541
mark 0x1000000 -> IPv4 lookup 9560 -> guard 9561
```

The adapter snapshots the complete relevant RPDB/mangle state and selects the first candidate whose mark bit and priority pair do not overlap any foreign object. The selected identity is retained for the live policy lifecycle and can be rediscovered from the exact materialized `MISH_EGRESS_V1` rules after process restart. If no candidate is clean, or materialized PRODUCT state is ambiguous, reconciliation returns typed `ReservedPolicyCollision` and publishes nothing new.

This is intentionally **not** a generic mark allocator or registry. Candidate count/order is versioned product code; there is no durable mutable allocation database and no search outside the bounded set.

PRODUCT owns one dedicated mangle chain:

```text
MISH_EGRESS_V1
```

For PRODUCT-owned OUTPUT traffic the chain is ordered as:

```text
loopback -> RETURN
CONNMARK restore of selected reserved bit
NEW -> set selected packet bit
NEW + selected bit -> save selected bit to conntrack
```

Consequences:

- loopback (`127.0.0.0/8`, `::1/128`) is explicitly outside cellular routing;
- an already selected public proxy connection restores the same MISH bit on later packets;
- when cellular is lost, both new and already-marked proxy flows meet the unreachable guard rather than falling through to Android default/Wi-Fi/WARP;
- an inbound Mesh connection does not acquire the MISH connmark: its PRODUCT-side reply is ESTABLISHED, not a NEW PRODUCT public flow;
- unrelated Android/netd mark bits are preserved because one audited bit is read/written through an exact mask.

The established-flow guarantee remains physical evidence: E3 keeps a real HTTPS connection open across a newer NOT_ADMITTED generation and requires new application data to fail.

### Publication and reconciliation law

`MISH_EGRESS_V1` is a versioned immutable live contract. Reconciliation must never flush or rewrite that chain while an OUTPUT jump references it.

The only permitted repair/build sequence is:

```text
live policy-space snapshot + bounded identity selection
-> fail-closed RPDB guards
-> stale IPv4 lookup revoked
-> create/rebuild MISH_EGRESS_V1 only while detached
-> verify every expected chain rule
-> attach exactly one OUTPUT jump
-> verify published chain + jump
-> remove the preceding legacy selector
```

If a referenced `MISH_EGRESS_V1` is incomplete or differs from every exact candidate-specific V1 contract, reconciliation fails closed and leaves it untouched. A future rule-layout change must use a new versioned chain and an explicit migration; it must not mutate V1 in place.

This avoids relying on unproven Android-specific `iptables-restore` transaction semantics. Deterministic tests require that a failed detached build never publishes a jump and that a referenced malformed chain is never flushed or rewritten.

## Reserved-space collision law

For each candidate, both its mark bit and its lookup/guard priorities are reserved only after a fresh complete audit. Collision includes:

- a foreign RPDB object at either candidate priority;
- any foreign RPDB `fwmark` whose mask overlaps the candidate bit;
- any foreign mangle MARK/CONNMARK rule whose read/write mask overlaps the candidate bit, even if the foreign value for that bit is zero;
- foreign or mismatched content under `MISH_EGRESS_V1`;
- contradictory candidate-specific materialized state.

PRODUCT never deletes, rewrites, reorders or repurposes a foreign object merely to make a candidate fit. Collision of one candidate advances only to the next bounded candidate. Collision/ambiguity of all candidates fails closed without publication.

The original NEW-only `0x200000` selector is recognized only as a narrow one-way migration signature and is removed after the named flow policy is safely established. It does not grant ownership over arbitrary foreign `0x200000` state.

## IPv6

Until a direct-cellular IPv6 path is separately accepted, IPv6 uses the same selected MISH flow classification but has no permitting lookup. The matching IPv6 unreachable guard therefore fails closed.

## Lifecycle

Each PRODUCT process generation creates one `CellularRuntimeBridge`. Startup first verifies PRODUCT root authority and reconciles the fail-closed base, then starts Android network observation. A permitting lookup appears only after a fresh owner ADMITTED observation.

The same `CellularController` / `CellularEgress` instance is also supplied to the private loopback egress bridge used by the Android proxy runtime. Starting the proxy bridge must not instantiate a second Cellular Egress owner or a second admission/generation state machine.

On owner loss or generation change, currentness advances independently of slow root effects. Every root transaction checks the captured owner generation before and after the effect. On intentional close, exact PRODUCT objects are removed and absence is post-verified.

A reboot/process restart never treats persisted kernel objects as admission truth: they are audited/reconciled under fresh PRODUCT root authority and fresh Cellular Egress observations.

## DNS transition

The physically rejected socket-binding path is retired. `android_setsocknetwork` is forbidden by CI.

Until Issue #64 establishes the final resolver/anti-leak mechanism, the private loopback egress bridge retains the narrow read-only `android_getaddrinfofornetwork` DNS adapter bound to the exact owner authority. Public target sockets themselves are ordinary PRODUCT-UID sockets and are routed only by the root policy above.

This transitional DNS adapter is not a second Cellular Egress owner and must disappear or be superseded only under #64's resolver contract.
