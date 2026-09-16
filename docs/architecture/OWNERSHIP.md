# Capability ownership

Core law:

```text
one fact -> one natural owner -> one write path -> one observation path
```

| Capability | Physical Rust home | Owns |
| --- | --- | --- |
| Transport Reachability | `crates/transport` | Mesh/private transport admission, exact admitted endpoint/epoch, canonical external accepted-session budget=64, reject-at-edge semantics and active external-session observation |
| Proxy Serving | `crates/proxy` | HTTP CONNECT / SOCKS5 / mixed protocol semantics, authentication, unresolved target semantics and proxy policy |
| Cellular Egress | `crates/cellular` | validated cellular admission, generation/currentness, egress authority and egress observations |
| Runtime Lifecycle / execution | `crates/runtime` | desired running state, runtime generation, the one process-wide Tokio executor/task tree for long-lived Mesh + Proxy work, cancellation/shutdown, internal execution permits/control reserve and runtime recovery decisions |
| IP Rotation | `crates/rotation` | rotation intent, operation identity, reconciliation/result |
| Device Identity | `crates/identity` | logical MISH installation/device identity |
| Desired Configuration | `crates/configuration` | validated non-secret desired state and generation |
| Credentials / Secrets | `crates/credentials` | product secret references and lifecycle semantics |
| Readiness Projection | `crates/readiness` | one derived aggregate projection; no leaf facts |

`crates/application` owns no leaf facts. It is only for genuine cross-owner use-cases.

## Runtime / transport / protocol split

The final native execution topology has one executor but several domain owners. Executor ownership and policy ownership are deliberately separate.

```text
mish-transport
  exact Mesh endpoint / admission epoch
  external accepted-session budget = 64
  reject-at-edge decision
  active external-session fact

mish-proxy
  protocol / auth / target semantics

mish-runtime
  ONE process-wide Tokio runtime
  Mesh ingress/session task execution
  Proxy Serving task execution
  async relay execution
  internal execution permits / control reserve
  terminal runtime failure
  cancellation / bounded shutdown

Cellular Egress
  current cellular authority
  exact-network DNS
  root-policy-gated public socket
```

`mish-transport` and `mish-proxy` do not own async runtimes, schedulers, independent executor pools or per-session OS-thread execution subsystems. Their domain contracts are executed by the one `mish-runtime` Tokio task tree.

The canonical external limit of 64 is **not** a Tokio/runtime business rule. `mish-transport` decides whether an external Mesh session may enter; `mish-runtime` decides how admitted work executes. Internal runtime permits/control reserve may protect execution machinery, but they must not become a second external-capacity authority.

Android/Kotlin does not become a second transport/proxy/runtime lifecycle owner. It executes platform effects and projects typed owner state.

## Architecture enforcement

Architecture tests/guards must prevent regression after the U2 Mesh/Tokio convergence:

- exactly one process-wide PRODUCT Tokio runtime/executor owns long-lived Mesh + Proxy network tasks;
- no `tokio::runtime::Builder`, independent executor/thread pool or thread-per-session serving subsystem may appear in `mish-transport` or `mish-proxy`;
- external accepted-session budget=64 and reject-at-edge ownership remain in `mish-transport`;
- `mish-runtime` consumes the exact Transport-owned session generation and cannot mint a second external Mesh capacity owner;
- a Mesh listener generation becomes healthy only after every retained listener task gives an explicit bounded startup-ready acknowledgement; PRODUCT startup polling/sleep is forbidden;
- `mish-runtime` retains and drains every long-lived listener/session/relay task at the runtime-generation boundary;
- hosted tests must include a real positive bidirectional byte relay through the Mesh listener/backend seam, in addition to 64/65 overflow, failure cleanup, cancellation and fresh-generation restart;
- Android remains an effects/observation adapter and cannot acquire duplicate counters, admission policy or lifecycle ownership.

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
