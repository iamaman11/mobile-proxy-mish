# Capability ownership

Core law:

```text
one fact -> one natural owner -> one write path -> one observation path
```

| Capability | Physical Rust home | Owns |
| --- | --- | --- |
| Transport Reachability | `crates/transport` | Mesh/private transport admission and transport observations |
| Proxy Serving | `crates/proxy` | HTTP CONNECT / SOCKS5 / mixed protocol semantics, authentication, unresolved target semantics and proxy policy |
| Cellular Egress | `crates/cellular` | validated cellular admission, generation/currentness, egress authority and egress observations |
| Runtime Lifecycle / execution | `crates/runtime` | desired running state, runtime generation, Tokio listener/session/task ownership, cancellation/shutdown and runtime recovery decisions |
| IP Rotation | `crates/rotation` | rotation intent, operation identity, reconciliation/result |
| Device Identity | `crates/identity` | logical MISH installation/device identity |
| Desired Configuration | `crates/configuration` | validated non-secret desired state and generation |
| Credentials / Secrets | `crates/credentials` | product secret references and lifecycle semantics |
| Readiness Projection | `crates/readiness` | one derived aggregate projection; no leaf facts |

`crates/application` owns no leaf facts. It is only for genuine cross-owner use-cases.

## Runtime / protocol split

`mish-proxy` does not own an async runtime or scheduler. `mish-runtime` owns Tokio execution and composes the natural-owner contracts.

```text
mish-proxy
  protocol / auth / target semantics

mish-runtime
  listeners
  session admission budget
  task tree
  blocking setup seam
  async relay execution
  terminal runtime failure
  cancellation / bounded shutdown
```

Android/Kotlin does not become a second proxy/runtime lifecycle owner. It executes platform effects and projects typed owner state.

## Cellular/root boundary

Root policy-routing, route-table discovery, firewall/RPDB mutation and exact-network DNS execution are infrastructure mechanisms underneath Cellular Egress ownership. They do not own a second cellular admission/currentness/readiness state machine.

PRODUCT root authority is one process-wide persistent Magisk `su` transport. Higher layers expose narrow typed root effects; no generic root RPC/control plane or root daemon/helper is a natural owner.

## Readiness

Readiness consumes immutable current projections from natural owners and owns only the aggregate derived result. It owns no sockets, timers, mutable readiness cache, root state or lifecycle transitions.

## Historical Android proxy residue

There is no natural owner for pre-L8 Android sing-box process/config/migration state because that state is not part of current PRODUCT.

Historical Android proxy files/processes on a development device are LAB hygiene only. They are not modeled, scanned, stopped, migrated or observed as PRODUCT state.

## Extension rule

Vendor/platform/presentation boundaries are adapters, not additional semantic owners.

Do not create a new owner, manager/service layer, registry, daemon, framework or status store when the existing natural owner plus one narrow adapter can satisfy the concrete requirement correctly.
