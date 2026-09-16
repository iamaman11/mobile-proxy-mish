# L8 Architecture Closure

Status: **COMPLETED architecture contract; U2 physical re-baseline enforces the one-way cutover**.

This document defines the architectural boundary between the accepted L7 native Rust proxy cutover and the final L8 implementation. L8 is complete only when the obsolete Android proxy dataplane, its compatibility/process-management semantics, obsolete terminology, accidental Kotlin orchestration ownership and non-deterministic runtime task ownership are gone.

## Goal

The final Android product is one process with a thin Android platform boundary and Rust natural owners:

```text
Android platform effects
  Foreground Service / ConnectivityManager / Android Keystore / Magisk transport / TLS effect
        |
        v
thin Kotlin adapters
        |
        v
mish-runtime
  |- one runtime generation/lifecycle owner
  |- one Tokio execution tree
  |- one cancellation/shutdown tree
  |- Cellular Egress composition
  |- Proxy Serving composition
  |- Mesh/Transport composition
  `- Readiness composition
        |
        +--> mish-cellular     owner of cellular admission/currentness
        +--> mish-proxy        owner of proxy protocol/auth/target semantics
        +--> mish-transport    owner of Mesh admission/ingress semantics
        +--> mish-readiness    pure terminal readiness projection
        +--> mish-credentials  owner of credential lifecycle semantics
        `--> narrow Android/root/network effects
```

Core law:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Kotlin is the mechanism boundary. Rust owns product semantics, state and decisions. No generic framework, event bus, root daemon, second VPN, second lifecycle machine, second scheduler or plugin abstraction is introduced.

## Non-negotiable invariants

1. Public proxy target DNS and sockets remain cellular-owned and fail closed.
2. No Wi-Fi/default/WARP public-egress fallback.
3. Cloudflare One Agent remains the only Android VPN/VpnService owner.
4. No arbitrary root shell/control API; only typed PRODUCT root-policy effects.
5. One process-wide persistent `su` session; authority proof cached per live shell generation.
6. Terminal Magisk denial/interactive-grant state is never polled repeatedly in one app process.
7. Proxy Serving is the sole owner of canonical loopback listeners and protocol/auth/target semantics.
8. Runtime Lifecycle owns generation replacement, start/stop/restart and recovery decisions.
9. Readiness owns one derived terminal projection and no leaf facts.
10. DEVICE-1 mutation remains blocked until exact-head hosted acceptance and deliberate physical execution.
11. **The L8 cutover is one-way:** PRODUCT contains no pre-L8 Android proxy compatibility runtime, migration state, process scan/kill path, marker or migration failure semantic.

## Closure work

### A. Deterministic Tokio execution ownership

`mish-runtime` owns every listener/session task it creates.

Required final shape:

```text
ProxyServingRuntime
  -> owned accept tasks
     -> owned session JoinSet(s)
        -> bounded blocking setup
        -> async bidirectional relay
```

Requirements:

- no detached long-lived session task;
- one shared bounded session admission budget;
- blocking proxy handshake / exact-network DNS / connect behind one bounded `spawn_blocking` seam;
- shutdown closes admission, signals cancellation, aborts/drains session tasks, joins acceptors and then destroys the Tokio runtime;
- `active_sessions` is observation/verification only, not ownership;
- bounded shutdown failure is typed and fail closed.

### B. Remove obsolete external Android proxy dataplane completely

The following are not PRODUCT dependencies or compatibility mechanisms after L8:

- `crates/sing-box-adapter`;
- `vendor/sing-box`;
- `tools/materialize_sing_box_android.py`;
- Gradle sing-box materialization/packaging/verifier tasks;
- private Cellular SOCKS bridge implementation/credentials/connector;
- child PID/launcher/process reconciliation machinery;
- Android sing-box upgrade/migration recognizers;
- `/proc` scans or TERM/KILL effects for historical proxy children;
- old proxy generation/PID/config files or migration markers as startup inputs;
- any Proxy Serving failure enum or FFI field describing legacy migration.

Historical residue on a development phone is LAB hygiene. It cannot block, authorize, repair or otherwise participate in PRODUCT startup. If residue physically conflicts with current listeners/routing, LAB removes it outside PRODUCT before the physical acceptance cycle.

### C. Native semantic cleanup

Private bridge, external-child and migration vocabulary must not describe the native runtime.

Current PRODUCT semantics are limited to current owners and current native effects, including:

- native runtime availability;
- external credential availability;
- listener availability;
- serving health;
- shutdown success/failure;
- Cellular/root-policy authority/currentness;
- Mesh and Readiness current facts.

Diagnostics use `mish.diagnostics/v2` and expose current native facts only. Producer, LAB consumer and executable schema guards change together when the current schema changes.

### D. Kotlin architecture closure

File size alone is not a split criterion. A Kotlin file is split when it contains multiple independent reasons to change, effect classes or test strategies.

Target decomposition:

```text
CellularRootPolicy
  RootPolicyContract
  RootPolicySnapshot/parser
  RootPolicyAudit (pure)
  DirectCellularRouteInspector
  RootPolicyExecutor (typed root effects)
  CellularRootPolicy transaction facade

Magisk root boundary
  MagiskRootAuthority (capability/proof cache)
  RootCommandSession contract
  PersistentSuSession transport/framing

Readiness Android effect
  ReadinessFactsAssembler
  AuthenticatedEgressProbe
  HttpConnectTlsProbe
  thin ProductReadinessAdapter

Credentials Android effect
  CredentialMetadataStore
  AndroidKeystoreRoot
  CredentialMaterializer
  thin ExternalProxyCredentialStore facade

Mesh Android effect
  AndroidVpnObserver
  thin MeshPlatformAdapter
```

No split may create a new natural owner. Pure parsing/audit components are unit-tested without Android/root effects.

### E. Move cross-owner decisions out of Kotlin

Kotlin must not independently own product policy merely because it executes Android effects.

Move/keep in Rust natural owners/runtime composition:

- proxy unexpected-failure recovery/backoff decision;
- readiness probe eligibility/freshness decision;
- Mesh public-ingress serving eligibility from Proxy + Readiness + Mesh facts;
- runtime generation/restart disposition.

Kotlin may execute a requested timer/effect and return a typed result, but the owner decides whether that result is current and what follows.

### F. Documentation and executable architecture constitution

Canonical architecture path:

```text
Cloudflare Mesh
 -> Rust Mesh ingress
 -> Rust Proxy Serving
 -> direct root-policy-gated Cellular Egress connector
 -> exact cellular DNS
 -> PRODUCT-UID public socket
 -> direct LTE/5G
```

Executable guards must fail on regression to:

- PRODUCT Android sing-box dependency/package/compatibility code;
- pre-L8 migration/process scan/kill/marker semantics;
- legacy migration failures in Rust or UniFFI;
- `privateBridge*` PRODUCT semantics;
- proxy child-process lifecycle vocabulary;
- uncontrolled Android/default DNS or process network binding;
- second VPN/TUN owner;
- second Kotlin runtime/readiness lifecycle owner;
- arbitrary root shell API;
- duplicated canonical proxy coordinates.

They positively require deterministic native task ownership, direct Cellular connector semantics and versioned diagnostics.

## Build and acceptance sequence

```text
L8 code
 -> deterministic Tokio ownership
 -> native semantic cleanup + diagnostics v2
 -> safe Kotlin decomposition / policy movement
 -> delete obsolete Android proxy packaging/dependencies/compatibility
 -> update docs + architecture guards
 -> exact-head full hosted gate
 -> deliberate DEVICE-1 exact-candidate acceptance
```

Hosted gate includes:

- Kotlin compile + lint;
- Rust fmt + clippy `-D warnings` + workspace tests with `--locked`;
- Android Rust/pinned NDK build;
- unit + assemble + androidTest package;
- native/UniFFI/package verification;
- architecture guards;
- canonical HTTP CONNECT/SOCKS5/mixed/auth/relay evidence;
- 64 concurrent accepted sessions and deterministic overload rejection;
- shutdown/restart/resource cleanup evidence.

Physical U2 gate after hosted acceptance proves the **current** product only:

- exact hosted APK, normal `adb install -r`, no clean uninstall;
- stable signer/UID and no repeated Magisk prompt with the existing permanent grant;
- native Proxy Serving starts without any pre-L8 prerequisite;
- PRODUCT spawns no external/root proxy child process;
- canonical HTTP CONNECT/SOCKS5/mixed functionality, auth isolation and relay;
- exact cellular DNS/public egress and no fallback;
- >=64-session physical/resource evidence;
- stop/start/restart and cellular loss/recovery remain bounded and fail closed.

## Definition of Done

L8 architecture closure requires:

```text
CARGO_LOCK_CURRENT=YES
TOKIO_TASKS_OWNED_AND_DRAINED=YES
DETACHED_LONG_LIVED_TASKS=0
PRIVATE_BRIDGE_PRODUCT_CONCEPTS=0
SING_BOX_PRODUCT_RUNTIME_DEPENDENCIES=0
SING_BOX_PRODUCT_COMPATIBILITY_SEMANTICS=0
SING_BOX_APK_BYTES=0
PROXY_CHILD_PROCESS_LIFECYCLE_SEMANTICS=0
KOTLIN_SECOND_OWNER_STATE_MACHINES=0
DIAGNOSTICS_V2_NATIVE_SEMANTICS=YES
ARCHITECTURE_GUARDS=PASS
FULL_HOSTED_EXACT_HEAD=PASS
DEVICE_1_AUTHORIZED_ONLY_AFTER_HOSTED_PASS=YES
```

The closure must make the implementation smaller and more explicit. If a proposed abstraction does not remove duplicated ownership, isolate a real effect, improve deterministic shutdown/testing, or prevent a known regression, it is out of scope.
