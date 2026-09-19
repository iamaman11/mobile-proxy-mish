#!/usr/bin/env python3
"""Fail-closed architecture guards for the native MISH product topology."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    target = ROOT / path
    if not target.is_file():
        raise SystemExit(f"architecture guard: required file missing: {path}")
    return target.read_text(encoding="utf-8")


def product_source(path: str) -> str:
    """Return production Rust source only, excluding in-file #[cfg(test)] modules."""
    return read(path).split("#[cfg(test)]", maxsplit=1)[0]


def require(path: str, needle: str, reason: str) -> None:
    if needle not in read(path):
        raise SystemExit(f"architecture guard: {reason}: {path} lacks {needle!r}")


def require_product(path: str, needle: str, reason: str) -> None:
    if needle not in product_source(path):
        raise SystemExit(f"architecture guard: {reason}: PRODUCT {path} lacks {needle!r}")


def forbid(path: str, needle: str, reason: str) -> None:
    if needle in read(path):
        raise SystemExit(f"architecture guard: {reason}: {path} contains {needle!r}")


def forbid_product(path: str, needle: str, reason: str) -> None:
    if needle in product_source(path):
        raise SystemExit(f"architecture guard: {reason}: PRODUCT {path} contains {needle!r}")


def forbid_regex(path: str, pattern: str, reason: str) -> None:
    if re.search(pattern, read(path), flags=re.MULTILINE) is not None:
        raise SystemExit(f"architecture guard: {reason}: {path} matches {pattern!r}")


def forbid_exists(path: str, reason: str) -> None:
    if (ROOT / path).exists():
        raise SystemExit(f"architecture guard: {reason}: obsolete path still exists: {path}")


def main() -> None:
    # Runtime/domain ownership stays vendor/platform neutral.
    forbid(
        "crates/runtime/Cargo.toml",
        "mish-android-network",
        "Runtime Lifecycle must not depend on the Android network adapter",
    )
    require(
        "crates/android-ffi/Cargo.toml",
        "mish-android-network",
        "Android DNS mechanics belong at the platform/FFI boundary",
    )
    runtime_controller = "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt"
    forbid(
        runtime_controller,
        "enum class LifecycleState",
        "Kotlin must not reintroduce a parallel foreground lifecycle state machine",
    )
    forbid(
        runtime_controller,
        "RuntimeCleanupDisposition(",
        "cleanup disposition policy belongs to crates/runtime",
    )
    for forbidden in (
        "mish-runtime-recovery-effect",
        "automaticRecoveryPending",
        "automaticRecoveryAttempts",
        "scheduleProxyRecoveryIfAllowed",
        "proxyServingFailureRecoverable(",
        "proxyRecoveryDelayMs(",
        "mish-runtime-lifecycle",
        "lifecycleExecutor",
        "RuntimeLifecycleController",
        "generation = MutableStateFlow",
        "generation.value =",
        "flatMapLatest",
        "newGeneration(",
        "RuntimeGeneration(",
        "closeRuntimeGenerationExact",
        "Executors.",
        "ScheduledExecutorService",
        "completeStart(",
        "completeStop(",
        "takeGenerationReplacementForStart(",
        "advanceStoppedGenerationAfterPlatformMutation(",
    ):
        forbid(
            runtime_controller,
            forbidden,
            "Kotlin must not own or execute Proxy recovery policy, timers or retry state",
        )
    for required in (
        "private val productRuntime = NativeProductRuntime(",
        "productRuntime.startRuntime(",
        "productRuntime.stopRuntime()",
        "productRuntime.runtimeLifecycleSnapshot()",
        "productRuntime.beginStoppedPlatformMutation()",
        "productRuntime.completeStoppedPlatformMutation(",
    ):
        require(
            runtime_controller,
            required,
            "Kotlin runtime facade must delegate lifecycle/generation identity to the stable native process handle",
        )

    # D2 one-way cutover: PRODUCT lifecycle/retry/generation scheduling may not drift back
    # into Kotlin. The only Android executor intentionally retained is AndroidVpnObserver's
    # callback serializer; it observes platform state and owns no PRODUCT semantics.
    for runtime_adapter in (
        "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt",
        "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MeshIngressRuntimeBridge.kt",
        "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeService.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularNetworkObserver.kt",
    ):
        for forbidden in (
            "Executors.",
            "ScheduledExecutorService",
            "newSingleThreadExecutor",
            "newScheduledThreadPool",
            "kotlinx.coroutines.delay",
            "kotlinx.coroutines.launch",
            "RuntimeLifecycleController",
            "ProxyServingLifecycleController",
            "ProductReadinessController",
            "scheduleProxyRecoveryIfAllowed",
            "automaticRecoveryPending",
            "automaticRecoveryAttempts",
            "newGeneration(",
            "RuntimeGeneration(",
        ):
            forbid(
                runtime_adapter,
                forbidden,
                "D2 Kotlin adapters must remain platform effects/presentation only; PRODUCT scheduling and ownership stay in Rust/Tokio",
            )

    vpn_observer = "android/app/src/main/java/com/mobileproxymish/app/AndroidVpnObserver.kt"
    for required in (
        'Thread(task, "mish-mesh-vpn-observer")',
        "executor.execute",
        "ConnectivityManager.NetworkCallback",
        "currentVpnObservation()",
    ):
        require(
            vpn_observer,
            required,
            "AndroidVpnObserver may retain only one Android callback-serialization executor",
        )
    for forbidden in (
        "NativeProductRuntime",
        "RuntimeLifecycleController",
        "ProxyServingLifecycleController",
        "ProductReadinessController",
        "RootPolicy",
        "scheduleProxyRecoveryIfAllowed",
        "retry",
        "backoff",
        "startRuntime(",
        "stopRuntime(",
    ):
        forbid(
            vpn_observer,
            forbidden,
            "Android VPN observer must remain raw platform observation, never a PRODUCT scheduler/owner",
        )

    # Cross-owner Mesh composition decisions belong to Rust/runtime, not Android adapters.
    mesh_serving = "crates/runtime/src/mesh_serving.rs"
    require(
        mesh_serving,
        "pub const fn mesh_ingress_serving_allowed",
        "Rust runtime must own the pure Mesh ingress eligibility predicate",
    )
    mesh_composition = "crates/runtime/src/mesh_composition.rs"
    for required in (
        "pub struct MeshCompositionCoordinator",
        "mesh_ingress_serving_allowed(",
        ".start_ingress(epoch, &mappings, executor)",
        "self.transport.stop_ingress()",
        "set_readiness_ready",
        "install_proxy",
        "clear_proxy",
    ):
        require_product(
            mesh_composition,
            required,
            "Rust runtime must own cross-owner Mesh ingress realization",
        )

    mesh_android = "android/app/src/main/java/com/mobileproxymish/app/MeshIngressRuntimeBridge.kt"
    for forbidden in (
        "meshIngressServingAllowed(",
        "MeshTransportController",
        "currentNativeRuntimeHandle",
        "startIngress(",
        "stopIngress(",
        "proxyRuntime.snapshot",
        "ingressLock",
        "setMeshReadinessReady(",
        "requireEgressReadiness(",
        "applyReadiness(",
    ):
        forbid(
            mesh_android,
            forbidden,
            "Android Mesh adapter must not decide or execute ingress lifecycle",
        )
    for required in (
        "AndroidVpnObserver(",
        "productRuntime.observeMeshVpn",
        "productRuntime.meshAdmissionSnapshot()",
        "productRuntime.invalidateMeshPlatformFact()",
    ):
        require(
            mesh_android,
            required,
            "Android Mesh adapter must remain raw VPN/readiness projection only",
        )

    # U5 execution law: exactly one process-level Tokio owner exists. Native PRODUCT generations
    # borrow it; no generation or serving component may construct or destroy another runtime.
    execution_owner = "crates/runtime/src/execution.rs"
    for required in (
        "pub struct RuntimeExecutor",
        "Builder::new_multi_thread()",
        'thread_name("mish-runtime-io")',
        "IO_WORKER_THREADS",
    ):
        require_product(
            execution_owner,
            required,
            "RuntimeExecutor must remain the one PRODUCT Tokio construction owner",
        )

    for required in (
        "MeshExecutionOwner",
        "handle: &Handle",
        "mpsc::sync_channel(expected_listeners)",
        "startup_rx.recv_timeout(remaining)",
        "sessions.try_admit()",
        "JoinSet",
        "listeners.spawn_on(",
        "copy_bidirectional",
    ):
        require_product(mesh_serving, required, "Mesh must execute deterministically on shared Tokio")
    for forbidden in (
        "std::thread::sleep",
        "std::thread::spawn",
        "tokio::runtime::Builder",
        "MeshSessionOwner::product_generation()",
    ):
        forbid_product(
            mesh_serving,
            forbidden,
            "Mesh runtime mechanism must not poll, create OS workers/second Tokio, or mint capacity",
        )

    proxy_runtime = "crates/runtime/src/proxy_runtime.rs"
    for forbidden in ("Builder::new_multi_thread", "Mutex<Option<Runtime>>"):
        forbid_product(
            proxy_runtime,
            forbidden,
            "Proxy Serving must borrow the process RuntimeExecutor rather than own Tokio",
        )
    require_product(
        proxy_runtime,
        "executor: Arc<RuntimeExecutor>",
        "Proxy Serving must retain the shared process RuntimeExecutor",
    )

    transport = "crates/transport/src/lib.rs"
    for required in ("MeshSessionOwner", "MeshSessionLease", "MeshIngressExecutor"):
        require_product(transport, required, "Transport must own Mesh admission/capacity contracts")
    for forbidden in (
        "MeshIngressRuntime",
        "std::thread",
        "thread::",
        "std::io::copy",
        "io::copy(",
        "tokio::runtime::Builder",
    ):
        forbid_product(
            transport,
            forbidden,
            "Transport must not regain listener/session execution or thread-per-session relay",
        )

    transport_runtime_owner = "crates/transport/src/runtime_owner.rs"
    require(
        transport_runtime_owner,
        "let sessions = MeshSessionOwner::product_generation();",
        "Transport coordinator must mint the one external Mesh session owner",
    )
    require(
        transport_runtime_owner,
        ".start_ingress(endpoint, mappings, Arc::clone(&sessions))",
        "Runtime must consume the exact Transport-owned session generation",
    )
    require(
        "crates/runtime/Cargo.toml",
        "mish-transport",
        "Runtime must consume Transport-owned Mesh contracts through the typed seam",
    )
    require_product(
        "crates/runtime/src/product_diagnostics.rs",
        "let mesh_snapshot = match mesh.snapshot()",
        "atomic native diagnostics must capture the Transport-owned Mesh snapshot",
    )
    for required in (
        "snapshot.active_sessions",
        "snapshot.capacity_rejects",
    ):
        require_product(
            "crates/android-ffi/src/product_runtime_ffi.rs",
            required,
            "atomic native diagnostics must project Mesh capacity from the captured Transport snapshot",
        )
    for duplicate_counter in ("AtomicInteger", "AtomicLong", "LongAdder"):
        forbid(
            mesh_android,
            duplicate_counter,
            "Android must not acquire a duplicate Mesh active-session counter",
        )

    # Proxy-target DNS/public egress has exactly one Cellular Egress path and no default fallback.
    cellular_bridge = "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt"
    runtime_dns = "crates/runtime/src/cellular_connector.rs"
    require(
        runtime_dns,
        "pub trait CellularDnsResolver",
        "Runtime must keep one injected Cellular Egress DNS consumer port",
    )
    for required in (
        "static DNS_DIAGNOSTICS",
        "completed_after_owner_change",
        "discarded_stale",
        "resolver_failed",
        "authority_validation_failed",
        "unusable_result",
        "peak_active",
    ):
        require_product(
            runtime_dns,
            required,
            "native DNS lifetime diagnostics must remain process-wide Rust-owned observation facts",
        )
    require_product(
        "crates/runtime/src/product_diagnostics.rs",
        "let dns = cellular.dns_diagnostic_snapshot();",
        "atomic native diagnostics must read the process-wide Rust-owned DNS facts",
    )
    forbid(
        cellular_bridge,
        "dnsDiagnostic",
        "Android Cellular adapter must not expose a separate DNS diagnostic read path",
    )
    for forbidden in ("newSingleThreadExecutor", "newFixedThreadPool", "AtomicInteger", "AtomicLong"):
        forbid(
            cellular_bridge,
            forbidden,
            "Android DNS projection must not acquire scheduling or duplicate lifetime counters",
        )
    android_dns = "crates/android-network/src/lib.rs"
    require(
        android_dns,
        "android_getaddrinfofornetwork(",
        "Android target DNS must remain scoped to the owner-issued network handle",
    )
    for product_path in (runtime_dns, "crates/android-ffi/src/runtime_boundary.rs"):
        for fallback in ("ToSocketAddrs", "lookup_host("):
            forbid(
                product_path,
                fallback,
                "proxy-target DNS must not gain an uncontrolled default resolver fallback",
            )
    for kotlin_path in ROOT.glob("android/app/src/main/java/**/*.kt"):
        kotlin = kotlin_path.read_text(encoding="utf-8")
        for fallback in (
            "bindProcessToNetwork(",
            "setProcessDefaultNetwork(",
            "InetAddress.getAllByName(",
            "InetAddress.getByName(",
            "Network.bindSocket(",
        ):
            if fallback in kotlin:
                relative = kotlin_path.relative_to(ROOT)
                raise SystemExit(
                    "architecture guard: public egress must not gain a default/process/per-socket "
                    f"network fallback: {relative} contains {fallback!r}"
                )


    # U4 public-egress IP remains one Cellular-owner observation, not a second network stack.
    public_ip = "crates/runtime/src/public_ip.rs"
    for required in (
        'PUBLIC_IP_ENDPOINT_HOST: &str = "checkip.amazonaws.com"',
        "PreparedPublicIpProbe",
        "resolve_current_domain(",
        "validate_authority(&self.owner, self.authority)",
        "PUBLIC_IP_RESPONSE_BODY_MAX_BYTES",
        "StaleGeneration",
    ):
        require(
            public_ip,
            required,
            "U4 public IP must stay generation-bound to the existing Cellular owner path",
        )

    public_ip_runtime = "crates/runtime/src/cellular_runtime.rs"
    for required in (
        "RuntimePublicIpProbe",
        "ensure_current_policy",
        "self.effect_gate.is_ready()",
        "PublicIpProbeFailure::RootPolicyUnavailable",
    ):
        require(
            public_ip_runtime,
            required,
            "U4 completion must revalidate the existing root-policy gate without a second owner",
        )

    public_ip_network = "crates/runtime/src/public_ip_network.rs"
    tls_client = "crates/runtime/src/tls_client.rs"
    product_ffi = "crates/android-ffi/src/product_runtime_ffi.rs"
    require(
        cellular_bridge,
        "CellularNetworkObservationInput(",
        "Android Cellular adapter must send one typed raw platform observation to the stable native handle",
    )
    for required in (
        "execute_public_ip_probe(",
        "TcpStream::connect(",
        "let mut stream = tls",
        "HTTP_RESPONSE_MAX_BYTES",
        "parse_http_200_body(",
    ):
        require_product(
            public_ip_network,
            required,
            "U4 ordinary TCP/TLS/HTTPS execution must remain on the shared Rust/Tokio path",
        )
    for required in (
        "ProductTlsClient",
        "RootCertStore",
        "webpki_roots::TLS_SERVER_ROOTS",
        "self.connector.connect(server_name, stream)",
    ):
        require_product(
            tls_client,
            required,
            "PRODUCT TLS certificate and hostname verification must remain Rust-owned",
        )
    require_product(
        "crates/runtime/src/entry.rs",
        "mod public_ip_network;",
        "U4 network execution module must be part of the runtime crate",
    )
    for required in (
        "pub fn observe_public_egress_ip(",
        ".block_on(execute_public_ip_probe(probe, &tls))",
    ):
        require_product(
            public_ip_runtime,
            required,
            "Cellular runtime must execute U4 through the one shared RuntimeExecutor",
        )
    require_product(
        product_ffi,
        "pub fn observe_public_egress_ip(",
        "NativeProductRuntime must expose only the terminal native U4 operation to Android",
    )
    require(
        cellular_bridge,
        "productRuntime.observePublicEgressIp(timeoutMs.toULong())",
        "Android Cellular adapter must delegate U4 execution to the native runtime",
    )
    forbid(
        cellular_bridge,
        "PublicIpProbeEffect",
        "Android Cellular adapter must not regain U4 socket/TLS execution",
    )
    forbid_exists(
        "android/app/src/main/java/com/mobileproxymish/app/cellular/PublicIpProbeEffect.kt",
        "U4 ordinary socket/TLS/HTTPS execution is Rust/Tokio-owned",
    )
    forbid_exists(
        "android/app/src/test/java/com/mobileproxymish/app/cellular/PublicIpProbeEffectTest.kt",
        "deleted Android U4 parser/effect tests must not outlive the Rust/Tokio owner",
    )

    public_ip_physical = (
        "android/app/src/androidTest/java/com/mobileproxymish/app/cellular/"
        "CellularE3InstrumentedTest.kt"
    )
    for required in (
        "runtime.observePublicEgressIp(",
        "application.runtimeController.currentProductRuntime",
        ".preparePublicIpProbe(",
        "u4StaleTicket.isCurrent()",
        'u4StaleTicket.complete("198.51.100.77")',
        "phase=u4 positive_https=true owner_bound_dns=true ordinary_uid_socket=true",
        "stale_generation_rejected=true no_default_fallback=true",
        "fresh_generation=true repeated_observations_bounded=true raw_ip_persisted=false",
    ):
        require(
            public_ip_physical,
            required,
            "U4 physical proof must ride the existing exact-candidate recovery lifecycle",
        )

    for required in (
        "val nativeShutdownElapsedMs =",
        '"native_shutdown_elapsed_ms=$nativeShutdownElapsedMs "',
    ):
        require(
            public_ip_physical,
            required,
            "D2 lifecycle evidence must observe one stable native generation shutdown boundary",
        )
    for forbidden in (
        "runtime.nativeController()",
        "proxyCloseElapsedMs",
        "cellularCloseElapsedMs",
        "proxy_close_elapsed_ms",
        "cellular_close_elapsed_ms",
    ):
        forbid(
            public_ip_physical,
            forbidden,
            "D2 must not restore per-component Android runtime close ownership",
        )

    readiness_physical = "android/app/src/androidTest/java/com/mobileproxymish/app/RuntimeReadinessInstrumentedTest.kt"
    require(
        readiness_physical,
        "currentProductRuntime.readinessDiagnosticSnapshot()",
        "readiness instrumentation must project the stable Rust-owned runtime diagnostic snapshot",
    )
    forbid(
        readiness_physical,
        "currentReadinessRuntime",
        "Android instrumentation must not recreate a per-generation readiness runtime handle",
    )
    forbid_exists(
        "android/app/src/test/java/com/mobileproxymish/app/ProxyRuntimeLifecycleTest.kt",
        "Kotlin lifecycle/generation cleanup tests must stay deleted after D2 ownership cutover",
    )

    recovery_lifecycle_probe = "lab/windows/diagnose-recovery-lifecycle.ps1"
    require(
        recovery_lifecycle_probe,
        "native_shutdown_elapsed_ms=(?<nativeShutdown>",
        "recovery diagnostics must parse the stable native shutdown timing boundary",
    )
    for forbidden in ("proxy_close_elapsed_ms", "cellular_close_elapsed_ms"):
        forbid(
            recovery_lifecycle_probe,
            forbidden,
            "recovery diagnostics must not depend on deleted per-component close seams",
        )

    endpoint_literal = "checkip.amazonaws.com"
    endpoint_owners = []
    for product_path in list(ROOT.glob("crates/**/*.rs")) + list(
        ROOT.glob("android/app/src/main/java/**/*.kt")
    ):
        if endpoint_literal in product_path.read_text(encoding="utf-8"):
            endpoint_owners.append(str(product_path.relative_to(ROOT)))
    if endpoint_owners != [public_ip]:
        raise SystemExit(
            "architecture guard: U4 public-IP endpoint literal must have one PRODUCT owner; "
            f"observed={endpoint_owners}"
        )

    for rust_path in ROOT.glob("crates/**/*.rs"):
        if "android_setsocknetwork(" in rust_path.read_text(encoding="utf-8"):
            raise SystemExit(
                "architecture guard: U4 must not reintroduce per-socket Android network binding: "
                f"{rust_path.relative_to(ROOT)}"
            )

    # Native Proxy Serving owns one explicit Tokio task tree and one lifecycle snapshot.
    proxy_runtime = "crates/runtime/src/proxy_runtime.rs"
    for required in (
        "JoinSet",
        "accept_tasks: Mutex<Vec<JoinHandle<()>>>",
        "sessions.abort_all()",
        "while sessions.join_next().await.is_some()",
        "Semaphore::new(MAX_NATIVE_PROXY_SESSIONS)",
        "spawn_blocking",
        "copy_bidirectional",
    ):
        require(proxy_runtime, required, "native Proxy Serving must keep deterministic task ownership")
    for required in (
        "ProxyServingLifecycle",
        "pub fn snapshot(&self) -> ProxyServingSnapshot",
        "owner_state.mark_running()",
        "owner_state.mark_stopped()",
        "publish_failure(ProxyServingFailure::ServingUnhealthy)",
    ):
        require(proxy_runtime, required, "ProxyServingRuntime must own semantic lifecycle state")
    forbid(
        proxy_runtime,
        "drop(tokio::spawn(",
        "long-lived native proxy sessions must not be detached Tokio tasks",
    )

    lifecycle = "crates/runtime/src/lifecycle.rs"
    for required in (
        "pub enum ProxyServingState",
        "pub enum ProxyServingFailure",
        "pub struct ProxyServingLifecycle",
    ):
        require(lifecycle, required, "runtime must expose native Proxy Serving lifecycle semantics")
    for obsolete in (
        "RuntimeProcessLifecycle",
        "RuntimeProcessFailure",
        "ChildLaunchFailed",
        "ChildExited",
        "PrivateBridgeUnavailable",
        "PrivateBridgeUnhealthy",
    ):
        forbid(lifecycle, obsolete, "external-child/private-bridge lifecycle semantics are obsolete")

    # Readiness is one pure Rust terminal projection. Native runtime owns composition, freshness,
    # refresh scheduling and ordinary CONNECT/TLS execution; Android consumes presentation only.
    readiness = "crates/readiness/src/lib.rs"
    require(readiness, "pub enum Readiness", "Readiness must expose one terminal projection type")
    require(readiness, "pub fn project(", "Readiness must remain a pure projection function")
    require(
        readiness,
        "pub struct EgressProbeObservation",
        "Readiness must consume one typed generation-bound probe observation",
    )
    require(
        readiness,
        "pub enum ProbeEligibility",
        "Readiness must own structural probe eligibility semantics",
    )
    require(
        readiness,
        "pub fn probe_eligibility(",
        "Readiness must expose one structural eligibility predicate",
    )
    forbid(
        readiness,
        "private_bridge",
        "Readiness must not retain a deleted private-bridge fact",
    )
    forbid(
        "crates/readiness/Cargo.toml",
        "[dependencies]",
        "Readiness projection must not acquire effect-owner dependencies",
    )
    for effect_token in (
        "std::net",
        "TcpStream",
        "UdpSocket",
        "std::thread",
        "Mutex",
        "RwLock",
        "Atomic",
        "Instant",
        "SystemTime",
    ):
        forbid(readiness, effect_token, "Readiness must not own I/O, timers, threads or mutable state")

    application = "crates/application/src/lib.rs"
    for required in (
        "run_authenticated_egress_probe",
        "EgressProbeCoordinator",
        "ProbeBinding",
        "DEFAULT_EGRESS_PROBE_BUDGET",
    ):
        require(application, required, "cross-owner readiness probe coordination belongs to Rust")

    readiness_ffi = "crates/android-ffi/src/readiness_ffi.rs"
    require(
        readiness_ffi,
        "pub enum ProductReadinessState",
        "Android readiness FFI must expose only the terminal presentation vocabulary",
    )
    for obsolete in (
        "ProductReadinessController",
        "ProductReadinessFactsView",
        "ProbeBindingView",
        "ProbeTicketView",
        "EgressProbeObservationView",
        "ReadinessProbeTargetView",
        "readiness_probe_refresh_delay_ms",
        "readiness_probe_target",
        "proxy_http_connect_port",
        "egress_probe_budget_ms",
    ):
        forbid(
            readiness_ffi,
            obsolete,
            "readiness control/freshness/target semantics must not return to Android FFI",
        )
    forbid_exists(
        "crates/android-ffi/src/readiness_eligibility_ffi.rs",
        "readiness eligibility is internal to the native runtime",
    )
    forbid(
        "crates/android-ffi/src/entry.rs",
        "readiness_eligibility_ffi",
        "obsolete readiness eligibility FFI module must stay deleted",
    )
    readiness_runtime = "crates/runtime/src/readiness_runtime.rs"
    for required in (
        "pub struct ReadinessRuntimeCoordinator",
        "EgressProbeCoordinator",
        "execute_readiness_probe_async",
        "observe_cellular",
        "observe_mesh",
        "observe_proxy_started",
        "observe_proxy_stopped",
        "DEFAULT_EGRESS_PROBE_REFRESH_DELAY",
        "self.mesh.set_readiness_ready",
        "ProbeEligibility::Eligible",
    ):
        require_product(
            readiness_runtime,
            required,
            "Readiness scheduling/currentness/composition must remain on the shared Rust/Tokio runtime",
        )
    for forbidden in (
        "std::thread",
        "ScheduledExecutorService",
        "Executors.",
    ):
        forbid_product(
            readiness_runtime,
            forbidden,
            "native readiness must not create a second scheduler/thread owner",
        )

    readiness_network = "crates/runtime/src/readiness_network.rs"
    for required in (
        "pub(crate) async fn execute_readiness_probe_async(",
        "TcpStream::connect(socket)",
        "Proxy-Authorization: {authorization}",
        "credentials.basic_authorization_value()",
        "tls.connect(stream, target.hostname(), remaining)",
        "DEFAULT_EGRESS_PROBE_BUDGET",
        "MAX_CONNECT_HEADER_BYTES",
        "HTTP_CONNECT_PORT",
    ):
        require_product(
            readiness_network,
            required,
            "readiness CONNECT/TLS execution must remain bounded on the shared Rust/Tokio runtime",
        )

    for required in (
        "ReadinessRuntimeCoordinator::new",
        "policy.add_internal_observer",
    ):
        require_product(
            "crates/runtime/src/product_generation.rs",
            required,
            "ProductGeneration must own readiness construction and native owner wiring",
        )
    for required in (
        "pub fn observe_readiness(",
        "pub fn readiness_snapshot(",
        "generation.readiness()",
    ):
        require_product(
            product_ffi,
            required,
            "NativeProductRuntime must expose readiness projection from the Rust-owned generation",
        )
    for forbidden in (
        "pub fn execute_readiness_probe(",
        "pub fn set_mesh_readiness_ready(",
    ):
        forbid_product(
            product_ffi,
            forbidden,
            "Android FFI must not expose transitional readiness execution/control surfaces",
        )

    forbid_exists(
        "android/app/src/main/java/com/mobileproxymish/app/ProductReadinessRuntime.kt",
        "Kotlin readiness scheduler/runtime must be deleted after native cutover",
    )
    forbid_exists(
        "android/app/src/main/java/com/mobileproxymish/app/AuthenticatedEgressProbe.kt",
        "readiness ordinary CONNECT/TLS execution is Rust/Tokio-owned",
    )
    for kotlin_path in ROOT.glob("android/app/src/main/java/**/*.kt"):
        kotlin = kotlin_path.read_text(encoding="utf-8")
        for forbidden in (
            "mish-readiness-probe",
            "probeExecutor",
            "refreshFuture",
            "scheduleRefresh(",
            "executeScheduledRefresh(",
            "ProductReadinessController()",
            "readinessProbeBindingIfEligible(",
            "readinessProbeRefreshDelayMs()",
        ):
            if forbidden in kotlin:
                raise SystemExit(
                    "architecture guard: Kotlin must not regain readiness scheduling/composition: "
                    f"{kotlin_path.relative_to(ROOT)} contains {forbidden!r}"
                )

    # Stateful runtime coordination must not drift into the FFI seam.
    ffi = "crates/android-ffi/src/runtime_boundary.rs"
    for symbol in (
        "struct RootPolicyEffectGate",
        "struct RootPolicyGatedConnector",
        "struct SessionRegistry",
        "bridge_accept_loop",
    ):
        forbid(ffi, symbol, "android-ffi must remain a typed adapter rather than a runtime owner")
    for forbidden in (
        "#[derive(uniffi::Object)]\npub struct CellularController",
        "pub fn new() -> Arc<Self>",
        "pub fn authorize_root_policy(",
        "pub fn close_root_policy_gate(",
        "pub fn await_root_policy_quiesced(",
    ):
        forbid(
            ffi,
            forbidden,
            "legacy Cellular FFI control plane must stay non-constructible and projection-only",
        )
    for required in (
        "pub(crate) struct CellularController",
        "pub(crate) fn from_runtime(",
    ):
        require(
            ffi,
            required,
            "CellularController may remain only as an internal projection helper",
        )

    lifecycle_ffi = "crates/android-ffi/src/runtime_lifecycle_ffi.rs"
    for forbidden in (
        "ProxyServingLifecycleController",
        "RuntimeLifecycleController",
        "RuntimeProcessLifecycle",
        "pub enum RuntimeStartAction",
        "pub enum RuntimeStopAction",
        "pub struct ProxyServingSnapshotView",
        "map_start_action",
        "map_stop_action",
    ):
        forbid(
            lifecycle_ffi,
            forbidden,
            "UniFFI lifecycle vocabulary must be projection-only; no separately constructible lifecycle owner",
        )
    proxy_coordinator = "crates/runtime/src/proxy_coordinator.rs"
    for required in (
        "pub struct ProxyRuntimeCoordinator",
        "proxy_serving_failure_recoverable",
        "proxy_recovery_delay_ms",
        "tokio::time::sleep",
        "set_terminal_observer",
        "next_serving_generation",
        "recovery_epoch",
        "ReadinessRuntimeCoordinator",
        "MeshCompositionCoordinator",
    ):
        require_product(
            proxy_coordinator,
            required,
            "Rust/Tokio must own Proxy serving generation, terminal failure and bounded recovery",
        )
    for forbidden in (
        "std::thread::sleep",
        "ScheduledExecutorService",
        "Executors.",
    ):
        forbid_product(
            proxy_coordinator,
            forbidden,
            "Proxy recovery must run on the shared Tokio executor only",
        )

    product_generation = "crates/runtime/src/product_generation.rs"
    for required in (
        "pub struct ProductGeneration",
        "CellularRuntimeCoordinator::new",
        "CellularPolicyCoordinator::new",
        "MeshCompositionCoordinator::new",
        "ReadinessRuntimeCoordinator::new",
        "ProxyRuntimeCoordinator::new",
        "shutdown_result: OnceCell<bool>",
        "run_shutdown_once(&self.shutdown_result",
        "pub fn shutdown_blocking(",
    ):
        require_product(
            product_generation,
            required,
            "mish-runtime ProductGeneration must own the per-generation PRODUCT composition graph",
        )
    for forbidden in (
        "CellularRuntimeCoordinator::new",
        "CellularPolicyCoordinator::new",
        "MeshCompositionCoordinator::new",
        "ReadinessRuntimeCoordinator::new",
        "ProxyRuntimeCoordinator::new",
    ):
        forbid_product(
            product_ffi,
            forbidden,
            "android-ffi must not assemble the PRODUCT generation object graph",
        )
    product_runtime = "crates/runtime/src/product_runtime.rs"
    for required in (
        "pub struct ProductRuntimeCoordinator",
        "RuntimeExecutor::new",
        "RuntimeLifecycle::new",
        "ProductGeneration::new",
        "pub fn request_start(",
        "pub fn request_stop(",
        "run_start",
        "run_stop",
        "ProductPlatformFacts",
        "record_cellular_observation",
        "last_cellular_loss",
        "pub fn observe_mesh_vpn(",
        "invalidate_cellular_platform_facts",
        "invalidate_mesh_platform_fact",
        "replay_platform_facts",
        "pub fn begin_stopped_platform_mutation(",
        "pub fn complete_stopped_platform_mutation(",
        "active_platform_mutation",
        "complete_failed_start_after_cleanup",
        "complete_stop_after_cleanup",
        "Arc::ptr_eq(&state.generation, &generation)",
        "bind_observers",
    ):
        require_product(
            product_runtime,
            required,
            "mish-runtime must own one stable process handle and all runtime generation transitions",
        )
    for required in (
        "ProductRuntimeCoordinator::new",
        "pub fn runtime_lifecycle_snapshot(",
        "pub fn start_runtime(",
        "pub fn stop_runtime(",
        "pub fn begin_stopped_platform_mutation(",
        "pub fn complete_stopped_platform_mutation(",
        "pub fn invalidate_cellular_platform_facts(",
        "pub fn invalidate_mesh_platform_fact(",
        "pub struct CellularNetworkObservationInput",
        "input: CellularNetworkObservationInput",
        "pub fn observe_proxy_runtime(",
        "pub fn proxy_runtime_snapshot(",
    ):
        require_product(
            product_ffi,
            required,
            "NativeProductRuntime must be a stable forwarding/projection handle over ProductRuntimeCoordinator",
        )
    for forbidden in (
        "ProductGeneration::new",
        "RuntimeExecutor::new",
        "InvalidRuntimeGeneration",
        "RuntimeStartAction",
        "RuntimeStopAction",
        "pub fn start_proxy_runtime(",
        "pub fn stop_proxy_runtime(",
    ):
        forbid_product(
            product_ffi,
            forbidden,
            "android-ffi must not construct generations/executors or expose a second Proxy lifecycle control path",
        )
    forbid_exists(
        "crates/android-ffi/src/proxy_serving_ffi.rs",
        "separate NativeProxyRuntime lifecycle handle must stay deleted",
    )
    forbid_exists(
        "crates/android-ffi/src/proxy_recovery_ffi.rs",
        "Proxy recovery policy must not be exported back to Kotlin",
    )
    for forbidden in (
        "proxy_serving_ffi",
        "proxy_recovery_ffi",
    ):
        forbid(
            "crates/android-ffi/src/entry.rs",
            forbidden,
            "obsolete Proxy FFI modules must stay deleted",
        )

    mesh_ffi = "crates/android-ffi/src/transport_ffi.rs"
    for forbidden in (
        "pub struct MeshTransportController",
        "MeshTransportCoordinator::new",
        "start_ingress(",
        "stop_ingress(",
        "process_runtime: Arc<NativeProxyRuntime>",
    ):
        forbid(
            mesh_ffi,
            forbidden,
            "UniFFI must not expose a second constructible Mesh owner/control plane",
        )
    for required in (
        "pub enum MeshAdmissionState",
        "pub struct MeshAdmissionView",
        "pub(crate) fn map_view",
        "pub(crate) fn map_transport_error",
    ):
        require(
            mesh_ffi,
            required,
            "Mesh FFI must be projection/error mapping only",
        )
    for required in (
        "observe_mesh_vpn_absent",
        "observe_mesh_unique_vpn",
        "observe_mesh_vpn_ambiguous",
        ".observe_mesh_vpn(",
        ".current_generation()",
    ):
        require_product(
            product_ffi,
            required,
            "NativeProductRuntime must project Mesh through the sole current Rust-owned generation",
        )

    # Proxy Serving is the sole owner of canonical product listener facts.
    proxy = "crates/proxy/src/lib.rs"
    require(
        proxy,
        "pub const fn canonical_listeners",
        "Proxy Serving must expose its canonical listener contract",
    )
    forbid(transport, "PRODUCT_PROXY_PORTS", "Transport must not own product proxy ports")
    forbid_regex(
        transport,
        r"\[\s*1080\s*,\s*1081\s*,\s*3128\s*\]",
        "Transport must not duplicate the product proxy-port tuple",
    )
    forbid(
        mesh_ffi,
        "pub fn proxy_listener_ports",
        "Transport FFI must not duplicate the Proxy Serving listener projection",
    )
    proxy_android = "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt"
    for obsolete in ("privateBridge", "childAlive", "RuntimeProcess"):
        forbid(proxy_android, obsolete, "Android proxy supervisor must describe native serving only")
    for second_owner in (
        "ProxyServingLifecycleController",
        ".requestStart()",
        ".markRunning()",
        ".markFailed(",
        ".markStopped()",
    ):
        forbid(proxy_android, second_owner, "Android proxy adapter must not drive Proxy Serving lifecycle state")
    for required in (
        "productRuntime.observeProxyRuntime(",
        "productRuntime.proxyRuntimeSnapshot()",
    ):
        require(
            proxy_android,
            required,
            "Android Proxy adapter must only project the single native Proxy coordinator",
        )
    for forbidden in (
        "productRuntime.startProxyRuntime(",
        "productRuntime.stopProxyRuntime(",
        "ProxyCredentialProvider",
        "publicCredentials",
    ):
        forbid(
            proxy_android,
            forbidden,
            "Android Proxy projection must not retain a direct lifecycle or credential control path",
        )
    for duplicate_counter in ("AtomicInteger", "AtomicLong", "LongAdder", "Semaphore("):
        forbid(
            proxy_android,
            duplicate_counter,
            "Android Proxy diagnostics must not own capacity or active-session accounting",
        )
    require_product(
        "crates/runtime/src/product_diagnostics.rs",
        "let proxy_active_sessions = proxy.active_sessions();",
        "atomic native diagnostics must read Proxy active sessions from the Rust owner",
    )
    for forbidden in (
        "NativeProxyRuntime?",
        "startNativeProxyRuntime(",
        "onFailureObserved",
        "activeRuntimeToken",
        "nextRuntimeToken",
        "synchronized(lock)",
    ):
        forbid(
            proxy_android,
            forbidden,
            "Android Proxy adapter must not regain serving-generation or recovery ownership",
        )

    # F diagnostics cutover is one-way: one immutable generation-pinned Rust snapshot, then
    # Android-only process metadata + serialization. Kotlin may not reconstruct owner semantics.
    diagnostics_owner = "crates/runtime/src/product_diagnostics.rs"
    for required in (
        "pub struct ProductDiagnosticSnapshot",
        "pub struct ProductGenerationDiagnosticSnapshot",
        "pub fn diagnostic_snapshot(&self)",
        "DIAGNOSTIC_STABILITY_ATTEMPTS",
        "Arc::ptr_eq(&generation, &current)",
        "runtime_before == runtime_after",
        "first == second",
        "capture_generation(&generation)",
        "RotationDiagnosticState::NotSupported",
    ):
        require_product(
            diagnostics_owner,
            required,
            "mish-runtime must own atomic generation-consistent PRODUCT diagnostics",
        )
    for forbidden in ("std::thread", "sleep(", "ProcessBuilder", "RootCommandTransport"):
        forbid_product(
            diagnostics_owner,
            forbidden,
            "diagnostic capture must remain read-only and scheduler-free",
        )

    for required in (
        "pub struct ProductDiagnosticSnapshotView",
        "pub fn diagnostic_snapshot(",
        ".diagnostic_snapshot()",
        "map_product_diagnostic_snapshot",
    ):
        require_product(
            product_ffi,
            required,
            "UniFFI must expose exactly one Rust-composed diagnostic snapshot",
        )
    for forbidden in (
        "pub fn readiness_diagnostic_snapshot(",
        "pub fn proxy_active_sessions(",
        "pub fn dns_diagnostic_snapshot(",
        "pub fn cellular_reconcile_diagnostic(",
        "pub fn root_recovery_diagnostic(",
        "pub fn root_policy_reconcile_diagnostic(",
    ):
        forbid_product(
            product_ffi,
            forbidden,
            "per-owner diagnostic reads must not remain exported after atomic snapshot cutover",
        )

    diagnostics = "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt"
    require(diagnostics, 'MISH_DIAGNOSTICS_SCHEMA_V2 = "mish.diagnostics/v2"', "diagnostics must be versioned v2")
    require(diagnostics, 'MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2 = "snapshot_v2"', "diagnostics method must be v2")
    require(
        diagnostics,
        "val snapshot = app.runtimeController.diagnosticSnapshot()",
        "Kotlin diagnostics must request exactly one native PRODUCT snapshot",
    )
    require(
        diagnostics,
        "snapshot: ProductDiagnosticSnapshotView",
        "Kotlin diagnostics serializer must consume the aggregate native record directly",
    )
    for obsolete in (
        "MISH_DIAGNOSTICS_SCHEMA_V1",
        "snapshot_v1",
        'put("bridge"',
        "private_healthy",
        "privateBridge",
        "currentCellularRuntime",
        "currentProxyRuntime",
        "currentProductRuntime",
        "currentMeshRuntime",
        "runtimeRecoveryBefore",
        "runtimeRecoveryAfter",
        "cellularBefore",
        "cellularAfter",
        "proxyBefore",
        "proxyAfter",
        "readinessBefore",
        "readinessAfter",
        "meshBefore",
        "meshAfter",
        "sameGeneration",
        " === ",
        "MishDiagnosticFactsV2",
        "CellularAdmissionState",
        "ProductReadinessState",
    ):
        forbid(
            diagnostics,
            obsolete,
            "Kotlin diagnostics must not regain multi-read semantic composition or generation fencing",
        )
    for mutation in (
        "startNativeProxyRuntime(",
        ".start()",
        ".stop()",
        "proxyServingFailureRecoverable(",
        "proxyRecoveryDelayMs(",
        "RootCommandTransport",
        "MagiskRootAuthority",
        "SuProcess",
        "ProcessBuilder",
        "rotateExternalCredential",
        "revokeExternalCredential",
        "authorizeRootPolicy(",
        "closeRootPolicyGate(",
        "observeNetwork(",
    ):
        forbid(diagnostics, mutation, "diagnostics must remain observation-only")

    for kotlin_path, obsolete in (
        ("android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt", "diagnosticObservation"),
        ("android/app/src/main/java/com/mobileproxymish/app/MeshIngressRuntimeBridge.kt", "diagnosticIngressFailure"),
        ("android/app/src/main/java/com/mobileproxymish/app/MeshIngressRuntimeBridge.kt", "diagnosticSessionObservation"),
        ("android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt", "dnsDiagnosticObservation"),
        ("android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt", "reconcileDiagnosticObservation"),
        ("android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt", "rootPolicyReconcileDiagnosticObservation"),
        ("android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt", "rootRecoveryDiagnosticObservation"),
    ):
        forbid(
            kotlin_path,
            obsolete,
            "presentation/platform adapters must not expose parallel diagnostic composition APIs",
        )

    # U5 root ownership is one-way: policy semantics live in mish-cellular, while the one
    # persistent root session + policy execution/recovery live under the process Tokio owner.
    root_session = "crates/runtime/src/root_session.rs"
    root_effect = "crates/runtime/src/root_policy_effect.rs"
    root_runtime = "crates/runtime/src/root_policy_runtime.rs"
    cellular_policy = "crates/runtime/src/cellular_policy_coordinator.rs"
    product_ffi = "crates/android-ffi/src/product_runtime_ffi.rs"

    for required in (
        "struct RootSessionManager",
        "RootCommandKind",
        "pub(crate) fn observation",
        "pub(crate) fn mutation",
        'arg("exec su 2>&1")',
        "COMMAND_TIMEOUT",
        "MAX_OUTPUT_BYTES",
    ):
        require_product(root_session, required, "Rust runtime must own one typed persistent root session")
    for forbidden in ("std::thread", "ProcessBuilder", 'listOf("su", "-c"'):
        forbid_product(root_session, forbidden, "native root transport must not regain Android or per-command shell machinery")

    require_product(
        root_effect,
        "if result.timed_out || !result.output_complete",
        "read-only root observations must retain one bounded fresh retry path",
    )
    require_product(
        root_effect,
        "RootPolicyEffectFailure::MutationUncertain",
        "uncertain root mutation must stay distinct from authoritative rejection",
    )
    forbid_product(
        root_effect,
        "sleep(",
        "root-policy effect executor must not own recovery timing",
    )

    for required in (
        "RootPolicyRuntime",
        "MutationUncertain",
        "cleanup_exact",
        "probe_authority",
        "remove_all_output_jumps",
    ):
        require_product(root_runtime, required, "Rust root-policy runtime must own transaction semantics")
    for required in (
        "CellularPolicyCoordinator",
        "await_root_policy_quiesced_async",
        "schedule_recovery",
        "RECOVERY_DELAYS_MS",
        "CellularPolicyPublication",
    ):
        require_product(cellular_policy, required, "Tokio coordinator must own root-policy reconciliation and recovery")

    for required in (
        "pub struct NativeProductRuntime",
        "ProductRuntimeCoordinator::new",
        "runtime_lifecycle_snapshot",
        "observe_cellular_policy",
    ):
        require_product(product_ffi, required, "Android must receive one stable opaque native PRODUCT process handle")

    for obsolete_path in (
        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRootPolicy.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/DirectCellularRouteInspector.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/MagiskRootAuthority.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/MangleOutputCollisionAudit.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/RootAuthorityRecoveryBackoff.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/RootCommandTransport.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/RootPolicyExecutor.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/RootPolicySnapshot.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/RootSessionBootstrap.kt",
        "crates/android-ffi/src/runtime_executor_ffi.rs",
    ):
        forbid_exists(obsolete_path, "Kotlin must not regain a second root-policy/root-session control plane")

    cellular_bridge = "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt"
    cellular_observer = "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularNetworkObserver.kt"
    require(
        cellular_observer,
        "lastObserved = null",
        "a restarted Android Cellular observation session must re-emit an identical current fact",
    )
    require(
        cellular_bridge,
        "productRuntime.invalidateCellularPlatformFacts()",
        "stopping Android Cellular observation must invalidate stable raw-fact replay state",
    )
    for forbidden in (
        "Executors.",
        "ScheduledExecutorService",
        "RootCommandTransport",
        "CellularRootPolicy(",
        "RootAuthorityRecoveryBackoff",
        "LatestCellularReconcileQueue",
        "authorizeRootPolicy(",
        "closeRootPolicyGate(",
    ):
        forbid(
            cellular_bridge,
            forbidden,
            "Android Cellular bridge must stay an observation/presentation adapter only",
        )

    # L8 native cutover is one-way: obsolete Android sing-box bytes/build adapters may not return.
    forbid("Cargo.toml", "sing-box-adapter", "workspace must not contain the obsolete proxy adapter")
    android_build = "android/app/build.gradle.kts"
    for obsolete in (
        "materializeSingBoxAndroid",
        "generatedSingBoxJniPath",
        "singBoxCachePath",
        "libsingbox.so",
    ):
        forbid(android_build, obsolete, "Android build must package only the native MISH runtime")
    for obsolete_path in (
        "crates/sing-box-adapter",
        "vendor/sing-box",
        "tools/materialize_sing_box_android.py",
        "android/app/src/main/java/com/mobileproxymish/app/LegacySingBoxUpgradeMigration.kt",
    ):
        forbid_exists(obsolete_path, "obsolete sing-box product dependency must stay deleted")

    # Desired Configuration remains the only deployment authority for Mesh CIDR/probe target.
    deployment = read("config/deployment/mesh-device-cidr.txt")
    if deployment.strip() != deployment.rstrip("\n") or "\n" in deployment.rstrip("\n"):
        raise SystemExit("architecture guard: Mesh deployment CIDR file must contain exactly one line")
    require(
        "crates/configuration/src/lib.rs",
        "struct MeshAcceptedCidr",
        "Desired Configuration must own Mesh CIDR validation",
    )
    require(
        "crates/configuration/src/lib.rs",
        "config/deployment/mesh-device-cidr.txt",
        "Desired Configuration must consume the canonical Mesh CIDR file",
    )
    probe_deployment = read("config/deployment/readiness-probe-host.txt")
    if probe_deployment.strip() != probe_deployment.rstrip("\n") or "\n" in probe_deployment.rstrip("\n"):
        raise SystemExit("architecture guard: readiness probe deployment file must contain exactly one line")
    require(
        "crates/configuration/src/lib.rs",
        "struct ReadinessProbeTarget",
        "Desired Configuration must own readiness probe target validation",
    )

    # E one-way cutover: mish-credentials is the only credential semantic owner. Android keeps
    # only Keystore/HMAC, opaque persistence bytes, transport crypto and explicit UI mechanics.
    proto = "contracts/proto/mish/credentials/v1/credentials.proto"
    require(proto, "package mish.credentials.v1;", "credential protobuf package must remain versioned")
    require(
        proto,
        "message ExternalProxyProvisioningEnvelope",
        "provisioning contract must remain protobuf",
    )

    credential_owner = "crates/credentials/src/lib.rs"
    credential_persistence = "crates/credentials/src/persistence.rs"
    credential_provisioning = "crates/credentials/src/provisioning.rs"
    for path, required in (
        (credential_owner, "ExternalCredentialState"),
        (credential_owner, "ExternalCredentialPurpose"),
        (credential_persistence, "pub fn encode_state("),
        (credential_persistence, "pub fn decode_state("),
        (credential_persistence, "pub fn resolve_persistence("),
        (credential_persistence, "ExternalCredentialPersistenceAction"),
        (credential_provisioning, "pub fn encode_provisioning_envelope("),
        (credential_provisioning, "pub fn decode_provisioning_envelope("),
        (credential_provisioning, "PROVISIONING_SCHEMA_VERSION"),
    ):
        require(path, required, "mish-credentials must own credential persistence/protobuf semantics")

    credential_ffi = "crates/android-ffi/src/credentials_ffi.rs"
    for required in (
        "pub fn external_credential_resolve_persistence(",
        "pub fn external_credential_encode_provisioning_envelope(",
        "ExternalCredentialPersistenceActionView",
        "ExternalCredentialCanonicalStateView",
    ):
        require(
            credential_ffi,
            required,
            "Android FFI must expose Rust-owned credential decisions rather than duplicate them",
        )
    for obsolete in (
        "external_credential_initial_state",
        "external_credential_restore",
    ):
        forbid(
            credential_ffi,
            obsolete,
            "legacy scalar credential construction must not bypass Rust persistence semantics",
        )

    credential_metadata = (
        "android/app/src/main/java/com/mobileproxymish/app/CredentialMetadataStore.kt"
    )
    for required in (
        'const val KEY_STATE_PROTOBUF = "state_pb_b64_v1"',
        "data class RawCredentialPersistence(",
        "fun readRaw()",
        "fun persistCanonical(encoded: ByteArray)",
    ):
        require(
            credential_metadata,
            required,
            "Android credential metadata must remain opaque platform storage only",
        )
    for forbidden in (
        "CredentialContractV1",
        "externalCredentialRestore",
        "externalCredentialInitialState",
        "toULongOrNull(",
        "credential version must",
        "mixed protobuf and legacy",
        "username",
        "password",
    ):
        forbid(
            credential_metadata,
            forbidden,
            "Kotlin credential metadata must not regain schema, migration or secret semantics",
        )
    forbid_exists(
        "android/app/src/main/java/com/mobileproxymish/app/CredentialContractV1.kt",
        "credential protobuf codec and validation are Rust-owned after E",
    )

    credential_store = (
        "android/app/src/main/java/com/mobileproxymish/app/ExternalProxyCredentialStore.kt"
    )
    for required in (
        "externalCredentialResolvePersistence(",
        "currentCredentialForRuntime()",
        "revealCurrentCredential()",
        "externalCredentialRotate(",
        "externalCredentialRevoke(",
    ):
        require(
            credential_store,
            required,
            "Android credential facade must apply only explicit Rust-owner transitions/effects",
        )
    credential_receiver = (
        "android/app/src/main/java/com/mobileproxymish/app/CredentialProvisioningReceiver.kt"
    )
    require(
        credential_receiver,
        "externalCredentialEncodeProvisioningEnvelope(",
        "Rust must encode and validate the provisioning plaintext contract",
    )
    forbid(
        credential_receiver,
        "CredentialContractV1",
        "Android provisioning transport must not regain protobuf semantics",
    )

    require(
        "android/app/src/main/java/com/mobileproxymish/app/MainViewModel.kt",
        "fun showCurrentCredentials()",
        "PRODUCT must keep one explicit sensitive current-credential access operation",
    )
    require(
        "android/app/src/main/java/com/mobileproxymish/app/MainActivity.kt",
        "Show current proxy credentials",
        "explicit user credential access must remain visible and opt-in",
    )
    diagnostics_provider = "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt"
    for forbidden in (
        "credential_username",
        "credential_password",
        "credentials.username",
        "credentials.password",
    ):
        forbid(
            diagnostics_provider,
            forbidden,
            "diagnostics must never project proxy username/password",
        )

    # No second Android VPN/TUN ownership may appear in PRODUCT.
    manifest = read("android/app/src/main/AndroidManifest.xml")
    if "VpnService" in manifest or "android.net.VpnService" in manifest:
        raise SystemExit("architecture guard: PRODUCT manifest must not declare a second Android VPN service")

    print("ARCHITECTURE_GUARDS=PASS")


if __name__ == "__main__":
    main()
