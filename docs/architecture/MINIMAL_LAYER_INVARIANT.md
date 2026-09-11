# Minimal-layer extension invariant

Canonical application rule:

```text
Do not add a new architectural layer when an existing natural owner plus one narrow adapter can solve the concrete requirement correctly.
```

Default implementation order:

```text
existing natural owner
        -> existing public port or one new narrow consumer/platform port
        -> one concrete adapter
```

A new capability owner, framework, manager/service layer, long-lived process, control plane, mutable status store, generic helper abstraction, or additional orchestration tier is forbidden by default.

A new layer is justified only when a concrete requirement cannot be satisfied correctly by the existing natural owner plus one narrow adapter because of an independently necessary ownership, security/privilege, lifecycle, failure-isolation, or process boundary.

Before introducing such a layer, the change must identify:

- the concrete blocking fact;
- the natural owner that cannot own it;
- the required new boundary;
- the direct test or physical evidence proving that boundary is necessary.

Convenience, anticipated reuse, naming symmetry, or hypothetical future variants are not sufficient justification.

This invariant applies across PRODUCT code, Android integration, root/network execution, runtime lifecycle, proxy serving, DNS, Mesh integration, and operations code.

Infrastructure mechanisms remain adapters to their natural owner. They must not become competing semantic owners or second state machines.

A later second real implementation may justify extracting a shared abstraction. The first implementation must not pre-build a generic framework for that possibility.
