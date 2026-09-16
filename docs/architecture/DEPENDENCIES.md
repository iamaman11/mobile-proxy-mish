# Dependency boundaries

The dependency graph follows capability ownership rather than platform convenience.

```text
Android/Kotlin presentation + platform effects
        |
        v
android-ffi  -> thin typed UniFFI boundary only
        |
        v
application  -> genuine cross-owner use-cases only
        |
        +-------------------------------+
        |                               |
        v                               v
runtime ---------------------------> transport
  |                                     |
  +-------------------------------> proxy
  |
  +-------------------------------> cellular
  |
  +-------------------------------> configuration

readiness -> pure projection; no effect-owner dependencies
```

## Stable direction rules

- `crates/runtime` may consume domain contracts required to execute already-authorized work, but it does not absorb their policy ownership.
- `crates/transport` owns Mesh endpoint/admission/epoch/external-capacity/session-owner contracts and has no dependency on Tokio/runtime execution machinery.
- `crates/proxy` owns protocol/auth/target semantics and has no dependency on Tokio/runtime execution machinery.
- `crates/runtime` owns the one process-wide Tokio runtime and implements the `mish-transport` execution seam for admitted Mesh work.
- Android/UniFFI may compose the current opaque native runtime with Transport ownership, but may not expose Tokio scheduling or create a second execution owner.
- Cellular Egress remains the only public DNS/socket authority; Mesh and Proxy do not add default-network or fallback public egress.

## U2 Mesh execution seam

The intended dependency direction is deliberately one-way:

```text
mish-transport
  MeshSessionOwner / MeshSessionLease / MeshIngressExecutor contract
        |
        v
mish-runtime
  implements MeshIngressExecutor
  executes TcpListener/session/relay on existing Tokio Runtime
        |
        v
loopback mish-proxy listener
```

`mish-runtime -> mish-transport` is therefore an execution-contract dependency, not a transfer of Transport policy. Transport creates the session generation and owns `active_sessions`; Runtime only consumes leases while executing admitted work.

No reverse `mish-transport -> mish-runtime` dependency, second Tokio runtime, thread-per-session executor, Hyper/Tonic control plane or Android-owned session counter is permitted.

## Vendor/platform boundaries

Vendor/platform adapters remain leaf mechanisms. Android APIs, Magisk/root shell mechanics, Cloudflare observation and generated UniFFI code must not leak into domain ownership crates.

When a new dependency appears, prefer the narrowest existing owner contract. A new manager/service/framework is not justified merely to avoid a direct typed dependency between the natural policy owner and the natural execution owner.
