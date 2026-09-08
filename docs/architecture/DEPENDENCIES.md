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
