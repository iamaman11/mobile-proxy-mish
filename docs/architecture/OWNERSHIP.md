# Capability ownership

Core law:

```text
one fact -> one natural owner -> one write path -> one observation path
```

| Capability | Physical Rust home | Owns |
| --- | --- | --- |
| Transport Reachability | `crates/transport` | admitted Mesh endpoint and product-visible transport readiness |
| Proxy Serving | `crates/proxy` | proxy listener/auth policy and serving readiness |
| Cellular Egress | `crates/cellular` | validated cellular selection/admission, egress policy, generation/currentness and egress observations |
| IP Rotation | `crates/rotation` | rotation intent, operation identity, reconciliation/result |
| Runtime Lifecycle | `crates/runtime` | desired-running and owned-process reconciliation |
| Device Identity | `crates/identity` | logical MISH installation/device identity |
| Desired Configuration | `crates/configuration` | validated non-secret desired state and generation |
| Credentials / Secrets | `crates/credentials` | product secret references and lifecycle semantics |
| Readiness Projection | `crates/readiness` | one derived aggregate projection, no leaf facts |

`crates/application` owns no leaf facts. It is only for genuine cross-owner use-cases.

Vendor/platform/presentation boundaries are adapters, not additional natural owners. Root policy-routing, Android routing-table discovery, firewall/RPDB mutation and DNS execution mechanisms remain infrastructure adapters to Cellular Egress; they do not own admission, generation, availability or a second readiness state.
