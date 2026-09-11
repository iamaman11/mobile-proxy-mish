# Allowed dependency graph

Policy dependencies point inward. Domain semantics do not depend on Android, Cloudflare, sing-box, Compose, a DB driver, or process-manager technology.

Canonical direction:

```text
platform/vendor adapters
        -> capability/application ports
        -> owner policy
```

Cross-owner access uses narrow public APIs or consumer-owned ports. Capability crates must not reach into another crate's private internals.

Special cases:

- `readiness` is a terminal projection sink and may consume public owner snapshots; no owner depends back on it.
- `application` may coordinate owner public APIs but owns no leaf facts.
- `sing-box-adapter` translates typed product input to disposable vendor JSON.
- `android-ffi` is the narrow platform/FFI seam, not a business layer.

Cycles, service locators, global registries, and shared mutable state are architecture failures.

## Minimal-layer extension invariant

Canonical application rule:

```text
Do not add a new architectural layer when an existing natural owner plus one narrow adapter can solve the concrete requirement correctly.
```

For every new requirement, the default implementation order is:

```text
existing natural owner
        -> existing public port or one new narrow consumer/platform port
        -> one concrete adapter
```

A new capability owner, framework, manager/service layer, long-lived process, control plane, mutable status store, generic helper abstraction, or additional orchestration tier is forbidden by default. It is justified only when a concrete requirement cannot be satisfied correctly by the existing natural owner plus one narrow adapter because of an independently necessary ownership, security/privilege, lifecycle, failure-isolation, or process boundary.

Before introducing such a layer, the change must identify the concrete blocking fact, the natural owner that cannot own it, the required new boundary, and the direct test or physical evidence that proves the boundary is necessary. Convenience, anticipated reuse, naming symmetry, or hypothetical future variants are not sufficient justification.

This rule applies to PRODUCT code, Android integration, root/network execution, runtime lifecycle, proxy serving, DNS, Mesh integration, and operations code. Infrastructure mechanisms remain adapters to their natural owner and must not become competing semantic owners or second state machines.

A later second real implementation may justify extracting a shared abstraction. The first implementation must not pre-build a generic framework for that possibility.
