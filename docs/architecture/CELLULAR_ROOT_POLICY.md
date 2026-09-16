# Cellular root-policy execution contract

This document records the concrete privileged infrastructure contract underneath the **Cellular Egress** natural owner. It does not create another admission, lifecycle or readiness owner.

## Ownership

```text
Android ConnectivityManager observations
 -> Rust crates/cellular
    = sole owner of cellular admission + generation/currentness
 -> Kotlin CellularRootPolicy / narrow typed root effects
    = realization of an already owner-issued decision
 -> kernel mangle/RPDB mechanics

Proxy Serving
 -> Rust mish-runtime direct Cellular connector
 -> current Cellular Egress authority
 -> exact-network DNS adapter
 -> ordinary PRODUCT-UID public socket
 -> root policy forces that socket onto current cellular egress
```

There is no private Cellular SOCKS bridge, Android external proxy child or second Cellular owner in the current L8 topology.

## Admission and fail-closed base

The semantic admission predicate is exactly:

```text
CELLULAR + INTERNET + VALIDATED + NOT_VPN
```

Before that predicate is true, PRODUCT may establish only the fail-closed base after verifying PRODUCT root authority. A permitting IPv4 cellular lookup exists only for the exact current ADMITTED owner generation.

For every owner generation the adapter:

1. snapshots live IPv4/IPv6 RPDB and mangle state;
2. resolves exactly one PRODUCT policy identity from the bounded candidate set or fails closed;
3. ensures matching fail-closed guards;
4. revokes stale PRODUCT IPv4 cellular lookup for that identity;
5. reconciles the exact MISH flow-mark policy;
6. only for ADMITTED, rediscovers and validates the current cellular route table;
7. installs exactly one current IPv4 lookup and verifies the resulting marked route.

Loss/recovery never reuses a stale route-table decision.

## Flow identity and continuity

PRODUCT does not assume one globally fixed mark/priority tuple is available on every supported Android topology. The bounded candidate set is versioned PRODUCT code, currently:

```text
mark 0x200000  -> IPv4 lookup 9500 -> guard 9501
mark 0x400000  -> IPv4 lookup 9520 -> guard 9521
mark 0x800000  -> IPv4 lookup 9540 -> guard 9541
mark 0x1000000 -> IPv4 lookup 9560 -> guard 9561
```

The adapter audits complete IPv4/IPv6 RPDB state plus mangle OUTPUT and user-defined mangle chains transitively reachable from OUTPUT. It selects the first candidate whose bit/priorities do not overlap accepted foreign state.

This is intentionally **not** a generic mark allocator/registry. There is no mutable allocation database and no unbounded search.

If no candidate is clean, relevant parsing/reachability is ambiguous, or materialized PRODUCT state is contradictory, reconciliation returns a typed failure and publishes no permitting state.

## MISH flow classification

PRODUCT owns one dedicated mangle chain:

```text
MISH_EGRESS_V1
```

For PRODUCT-owned OUTPUT traffic the chain is ordered around these semantics:

```text
loopback -> RETURN
CONNMARK restore of selected reserved bit
NEW -> set selected packet bit
NEW + selected bit -> save selected bit to conntrack
```

Consequences:

- loopback (`127.0.0.0/8`, `::1/128`) is outside public cellular routing;
- an already selected public PRODUCT connection restores the same MISH bit on later packets;
- when cellular authority is lost, new and already-marked public flows meet the fail-closed guard rather than falling through to Android default/Wi-Fi/WARP;
- inbound Mesh transport does not acquire the MISH public-egress connmark merely because it is handled by PRODUCT;
- unrelated Android/netd bits are preserved through the exact reserved mask.

## Publication and reconciliation law

`MISH_EGRESS_V1` is a versioned live contract. Reconciliation must not destructively rewrite a referenced chain merely to make current state fit expectations.

Safe publication shape:

```text
fresh live policy-space snapshot + bounded identity selection
 -> fail-closed RPDB guards
 -> stale permitting lookup revoked
 -> create/rebuild expected MISH chain only while detached
 -> verify expected rules
 -> attach exactly one OUTPUT jump
 -> verify published chain + jump
 -> remove only a separately proven PRODUCT-owned superseded selector, when such a migration is explicitly supported
```

A referenced malformed/mismatched PRODUCT chain fails closed and is not guessed into correctness. A future rule-layout change uses a new versioned chain/explicit migration rather than mutating V1 semantics in place.

PRODUCT never deletes, rewrites, reorders or repurposes foreign RPDB/mangle objects to make a candidate fit.

## Reserved-space collision law

Collision authority for each candidate is exactly:

```text
complete IPv4/IPv6 RPDB
+
mangle OUTPUT
+
all user-defined mangle chains transitively reachable from OUTPUT
```

Collision includes:

- foreign RPDB objects at either candidate priority;
- foreign RPDB `fwmark` masks overlapping the candidate bit;
- foreign MARK/CONNMARK read/write on OUTPUT or an OUTPUT-reachable user chain overlapping the candidate bit;
- malformed/ambiguous relevant mark or reachability semantics;
- foreign/mismatched content under the PRODUCT chain;
- contradictory candidate-specific materialized state.

State reachable only from unrelated INPUT/FORWARD paths is not automatically a PRODUCT public-egress collision, but PRODUCT never claims ownership of that foreign state.

## IPv6

Until a direct-cellular IPv6 public path is separately accepted, IPv6 has no permitting public lookup. Matching fail-closed policy prevents silent IPv6 escape through another network.

## Direct L8 outbound data path

Current Proxy Serving is in-process Rust. `mish-runtime` obtains the exact `CellularController`/`CellularEgress` owner handle; no admission/currentness state is copied into a second proxy-specific owner.

For one public target operation:

```text
issue current CellularNetworkAuthority
 -> if domain: resolve only with exact-network DNS adapter
 -> validate the same authority after DNS
 -> bound IPv4 candidates
 -> before each connect: validate authority
 -> ordinary PRODUCT-UID TcpStream connect
 -> kernel root policy routes marked flow via current cellular table
 -> validate authority again after external effect
```

If no admitted authority exists or the generation/network changes, the connector returns unavailable/fail-closed. It never retries through Android default routing, Wi-Fi or WARP.

The runtime owner provides the bounded blocking seam for DNS/connect setup; Cellular Egress remains the natural owner of network authority.

## Exact-network DNS

Android socket binding (`Network.bindSocket` / `android_setsocknetwork`) is not the PRODUCT mechanism and remains forbidden by the accepted architecture.

The narrow `crates/android-network` adapter exposes only network-scoped DNS through `android_getaddrinfofornetwork` using an already owner-issued `CellularNetworkAuthority`.

It cannot select/bind/connect a public socket and owns no lifecycle/admission policy. Runtime validates the authority before/after the DNS effect. The public socket itself is an ordinary PRODUCT-UID socket governed by the root policy above.

This exact-network DNS mechanic remains subject to later resolver/anti-leak hardening only where the roadmap/current evidence demonstrates a concrete need; it is **not** a private bridge and must not recreate one.

## Generation / mutation sequencing

`CellularRuntimeBridge` is a process-generation adapter between Android observations, Rust Cellular ownership and typed root-policy effects. It owns no cellular admission policy.

Owner currentness advances independently of slow privileged effects. Root-policy work validates the captured generation around the effect, and permitting state is published only for the still-current admitted generation.

The Rust cellular/runtime gate quiesces in-flight outbound setup before root-policy mutation/revocation where required. That mechanism is infrastructure serialization, not a second readiness/admission owner.

Process restart/reboot never treats persisted kernel objects as admission truth: they are audited/reconciled under fresh process/root authority and fresh Cellular Egress observations.

## Magisk/root transport

Current architecture has one process-wide persistent Magisk `su` transport underneath typed root-policy adapters:

```text
ProcessBuilder("su")
 -> one serialized live shell generation
 -> bounded framed commands/results
 -> authority proof cached only for that live shell generation
```

Transport/session generation change invalidates cached authority. Transport failure invalidates the shared shell and **does not automatically replay a mutating command**, because the kernel effect may already have occurred.

Higher layers must not gain a generic privileged RPC/control API, root daemon/helper or whole-app-root execution merely to simplify this boundary.

The remaining shell-shaped internal transport form is an implementation-cleanup target after U2 physical proof; changing that API must preserve exactly one persistent `su` transport, serialization, bounded output/deadlines, generation invalidation and fail-closed uncertainty semantics.

## Acceptance status

Architecture/code semantics do not substitute for required U2 physical proof. Issue #135 / `PRODUCT_ROADMAP.md` own the remaining evidence requirements, including:

- exact Cellular DNS/public egress and no Wi-Fi/default/WARP fallback;
- cellular loss/recovery fail-closed behavior;
- replace-install/process-restart/repeated-recovery Magisk grant persistence;
- one bounded persistent `su` transport without unbounded process growth;
- required resource/timing baseline.

Historical private-bridge or Android sing-box evidence is not current PRODUCT acceptance evidence.
