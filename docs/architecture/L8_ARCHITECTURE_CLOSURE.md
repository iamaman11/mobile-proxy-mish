# L8 Architecture Closure

Status: ACTIVE execution contract for the native proxy cutover.

This document closes the architectural gap between the accepted L7 native Rust proxy cutover and a production-grade L8 implementation. It is intentionally stricter than a migration checklist: L8 is complete only when the obsolete dataplane, obsolete terminology, accidental Kotlin orchestration ownership and non-deterministic runtime task ownership are gone.

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

Core law remains:

```text
one fact -> one natural owner -> one write path -> one observation path
```

Kotlin is the mechanism boundary. Rust owns product semantics, state and decisions. No new generic framework, event bus, root daemon, second VPN, second lifecycle machine, second scheduler or plugin abstraction is introduced.

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
10. DEVICE-1 mutation remains blocked until exact-head hosted acceptance and STOP_FOR_ANALYSIS.

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

- no `drop(tokio::spawn(...))` detached long-lived session task;
- one shared bounded session admission budget;
- blocking proxy handshake / exact-network DNS / connect remains behind one bounded `spawn_blocking` seam;
- shutdown closes admission, signals cancellation, aborts/drains session tasks, joins acceptors and then destroys the Tokio runtime;
- `active_sessions` is observation/verification only, not ownership;
- bounded shutdown failure is typed and fail closed.

### B. Remove obsolete external proxy dataplane

After native serving parity is accepted, the following are not PRODUCT dependencies:

- `crates/sing-box-adapter`;
- `vendor/sing-box`;
- `tools/materialize_sing_box_android.py`;
- Gradle sing-box materialization/packaging/verifier tasks;
- CI sing-box cache/path/package assertions;
- private Cellular SOCKS bridge implementation/credentials/connector;
- child PID/launcher/process reconciliation machinery.

`LegacySingBoxUpgradeMigration` may remain temporarily only as a one-shot upgrade compatibility adapter that identifies and terminates the exact old PRODUCT-owned process. It must not require packaging a new sing-box binary and must not become a permanent process reconciler.

### C. Semantic cleanup

Private bridge and external-child vocabulary must not describe the native runtime.

Remove/replace PRODUCT concepts such as:

- `privateBridgeHealthy` aliases for native runtime health;
- `bridge.private_healthy` from the current diagnostics contract;
- `RuntimeProcessLifecycle`/`Child*` failure names for in-process Proxy Serving.

Use native semantics: Proxy Serving lifecycle, serving health, listener bind/unavailable, shutdown failure and legacy-upgrade migration failure.

Diagnostics move to `mish.diagnostics/v2` rather than keeping a permanently false v1 bridge projection. Producer, LAB consumer and executable schema guards change together.

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

Update canonical architecture docs to the native path:

```text
Cloudflare Mesh
 -> Rust Mesh ingress
 -> Rust Proxy Serving
 -> direct root-policy-gated Cellular Egress connector
 -> exact cellular DNS
 -> PRODUCT-UID public socket
 -> direct LTE/5G
```

`tools/check_architecture.py` must fail on regression to:

- PRODUCT sing-box dependency/package;
- `privateBridge*` PRODUCT semantics;
- proxy child-process lifecycle vocabulary;
- uncontrolled Android/default DNS or process network binding;
- second VPN/TUN owner;
- second Kotlin runtime/readiness lifecycle owner;
- arbitrary root shell API;
- duplicated canonical proxy coordinates.

It must positively require deterministic native task ownership, the direct Cellular connector and versioned diagnostics.

## Build and acceptance sequence

One implementation line only:

```text
L8 branch
 -> Cargo.lock exactly regenerated from current manifests
 -> deterministic Tokio ownership
 -> semantic cleanup + diagnostics v2
 -> safe Kotlin decomposition / policy movement
 -> delete obsolete sing-box packaging/dependencies
 -> update docs + architecture guards + CI producer contract
 -> exact-head full hosted gate
 -> STOP_FOR_ANALYSIS
 -> deliberate DEVICE-1 exact-candidate acceptance
```

Hosted gate must include:

- Kotlin compile + lint;
- Rust fmt + clippy `-D warnings` + workspace tests with `--locked`;
- Android Rust/pinned NDK build;
- unit + assemble + androidTest package;
- native/UniFFI/package verification;
- architecture guards;
- canonical HTTP CONNECT/SOCKS5/mixed/auth/relay evidence;
- 64 concurrent accepted sessions and deterministic overload rejection;
- shutdown/restart/resource cleanup evidence.

Physical gate after hosted acceptance must prove:

- exact hosted APK only, normal `adb install -r`, no clean uninstall;
- stable signer/UID and no repeated Magisk prompt with the existing permanent grant;
- one-shot legacy process migration if an old detached sing-box survives upgrade;
- zero root proxy/sing-box child processes in native steady state;
- canonical HTTP CONNECT/SOCKS5/mixed functionality;
- exact cellular DNS/public egress and no fallback;
- >=64-session physical/resource evidence;
- stop/start/restart and cellular loss/recovery remain bounded and fail closed.

## Definition of Done

L8 Architecture Closure is complete only when all are true:

```text
CARGO_LOCK_CURRENT=YES
TOKIO_TASKS_OWNED_AND_DRAINED=YES
DETACHED_LONG_LIVED_TASKS=0
PRIVATE_BRIDGE_PRODUCT_CONCEPTS=0
SING_BOX_PRODUCT_RUNTIME_DEPENDENCIES=0
SING_BOX_APK_BYTES=0
PROXY_CHILD_PROCESS_LIFECYCLE_SEMANTICS=0
KOTLIN_SECOND_OWNER_STATE_MACHINES=0
DIAGNOSTICS_V2_NATIVE_SEMANTICS=YES
ARCHITECTURE_GUARDS=PASS
FULL_HOSTED_EXACT_HEAD=PASS
DEVICE_1_AUTHORIZED_ONLY_AFTER_HOSTED_PASS=YES
```

The closure must make the implementation smaller and more explicit. If a proposed abstraction does not remove duplicated ownership, isolate a real effect, improve deterministic shutdown/testing, or prevent a known regression, it is out of scope.