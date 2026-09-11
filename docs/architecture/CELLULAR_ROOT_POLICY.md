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

1. audits the reserved MISH policy space;
2. ensures the fail-closed guards;
3. revokes any stale IPv4 cellular lookup;
4. reconciles the exact MISH flow-mark policy;
5. only for ADMITTED, rediscovers and validates the current cellular route table;
6. installs exactly one current IPv4 lookup and verifies the resulting marked route.

Loss/recovery therefore cannot reuse a stale route-table decision.

## Flow identity and continuity

PRODUCT reserves only mark bit `0x200000/0x200000` and one dedicated mangle chain:

```text
MISH_EGRESS_V1
```

For PRODUCT-owned OUTPUT traffic the chain is ordered as:

```text
loopback -> RETURN
CONNMARK restore of reserved bit
NEW -> set reserved packet bit
NEW + reserved bit -> save reserved bit to conntrack
```

Consequences:

- loopback (`127.0.0.0/8`, `::1/128`) is explicitly outside cellular routing;
- an already selected public proxy connection restores the same MISH bit on later packets;
- when cellular is lost, both new and already-marked proxy flows meet the unreachable guard rather than falling through to Android default/Wi-Fi/WARP;
- an inbound Mesh connection does not acquire the MISH connmark: its PRODUCT-side reply is ESTABLISHED, not a NEW PRODUCT public flow;
- unrelated Android/netd mark bits are preserved by the mask.

The established-flow guarantee remains physical evidence: E3 keeps a real HTTPS connection open across a newer NOT_ADMITTED generation and requires new application data to fail.

### Publication and reconciliation law

`MISH_EGRESS_V1` is a versioned immutable live contract. Reconciliation must never flush or rewrite that chain while an OUTPUT jump references it.

The only permitted repair/build sequence is:

```text
reserved-space audit
-> fail-closed RPDB guards
-> stale IPv4 lookup revoked
-> create/rebuild MISH_EGRESS_V1 only while detached
-> verify every expected chain rule
-> attach exactly one OUTPUT jump
-> verify published chain + jump
-> remove the preceding legacy selector
```

If a referenced `MISH_EGRESS_V1` is incomplete or differs from the exact V1 contract, reconciliation fails closed and leaves it untouched. A future rule-layout change must use a new versioned chain and an explicit migration; it must not mutate V1 in place.

This avoids relying on unproven Android-specific `iptables-restore` transaction semantics. Deterministic tests require that a failed detached build never publishes a jump and that a referenced malformed chain is never flushed or rewritten.

## Reserved-space collision law

Reserved RPDB priorities are:

```text
9500 = current IPv4 cellular lookup
9501 = same-mark unreachable guard
```

Any foreign/mismatched object at the reserved priorities, any foreign rule using the reserved mark bit, or any foreign content under `MISH_EGRESS_V1` is a typed `ReservedPolicyCollision` and fails closed. PRODUCT does not delete an unknown object merely to make its own policy fit.

The immediately preceding legacy NEW-only selector is recognized only as a one-way migration signature and is removed after the named flow policy is established.

## IPv6

Until a direct-cellular IPv6 path is separately accepted, IPv6 uses the same MISH flow classification but has no permitting lookup. The same-mark IPv6 unreachable guard therefore fails closed.

## Lifecycle

Each PRODUCT process generation creates one `CellularRuntimeBridge`. Startup first verifies PRODUCT root authority and reconciles the fail-closed base, then starts Android network observation. A permitting lookup appears only after a fresh owner ADMITTED observation.

On owner loss or generation change, currentness advances independently of slow root effects. Every root transaction checks the captured owner generation before and after the effect. On intentional close, exact PRODUCT objects are removed and absence is post-verified.

A reboot/process restart never treats persisted kernel objects as admission truth: they are audited/reconciled under fresh PRODUCT root authority and fresh Cellular Egress observations.

## DNS transition

The physically rejected socket-binding path is retired. `android_setsocknetwork` is forbidden by CI.

Until Issue #64 establishes the final resolver/anti-leak mechanism, the private loopback egress bridge retains a narrow read-only `android_getaddrinfofornetwork` DNS adapter bound to the exact owner authority. Public target sockets themselves are ordinary PRODUCT-UID sockets and are routed only by the root policy above.

This transitional DNS adapter is not a second Cellular Egress owner and must disappear or be superseded only under #64's resolver contract.
