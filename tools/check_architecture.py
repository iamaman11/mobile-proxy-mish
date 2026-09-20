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


def require_product_count(path: str, needle: str, expected: int, reason: str) -> None:
    observed = product_source(path).count(needle)
    if observed != expected:
        raise SystemExit(
            f"architecture guard: {reason}: PRODUCT {path} contains {needle!r} "
            f"{observed} times, expected exactly {expected}"
        )


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
    application_root = "android/app/src/main/java/com/mobileproxymish/app/MishApplication.kt"
    diagnostics_provider = "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt"
    for required in (
        "@Volatile",
        "private var runtimeControllerRef: MishRuntimeController? = null",
        "override fun attachBaseContext(base: Context)",
        "super.attachBaseContext(base)",
        "runtimeControllerRef = MishRuntimeController(this)",
        "get() = checkNotNull(runtimeControllerRef)",
    ):
        require(
            application_root,
            required,
            "Android process bootstrap must create exactly one controller before ContentProviders without read-triggered initialization",
        )
    for forbidden in (
        "lateinit var runtimeController",
        "by lazy(",
        "LazyThreadSafetyMode",
    ):
        forbid(
            application_root,
            forbidden,
            "runtime controller bootstrap must be explicit in Application.attachBaseContext, never deferred to a reader",
        )
    forbid(
        diagnostics_provider,
        "MishRuntimeController(",
        "read-only diagnostics must never construct PRODUCT runtime state",
    )
    controller_construction_sites = []
    for kotlin_file in sorted((ROOT / "android/app/src/main/java").rglob("*.kt")):
        kotlin_text = kotlin_file.read_text(encoding="utf-8")
        if "MishRuntimeController(this)" in kotlin_text:
            controller_construction_sites.append(kotlin_file.relative_to(ROOT).as_posix())
    if controller_construction_sites != [application_root]:
        raise SystemExit(
            "architecture guard: process-local MishRuntimeController must have exactly one production "
            f"construction site in Application.attachBaseContext; observed={controller_construction_sites}"
        )
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

    # U5 production-Kotlin boundary is global, not filename-based. New Kotlin files may not
    # silently reintroduce PRODUCT scheduling/control under a new class name. The one intentional
    # executor is AndroidVpnObserver's Android callback serializer.
    kotlin_main_root = ROOT / "android/app/src/main"
    vpn_observer_relative = "android/app/src/main/java/com/mobileproxymish/app/AndroidVpnObserver.kt"
    for kotlin_file in sorted(kotlin_main_root.rglob("*.kt")):
        kotlin_relative = kotlin_file.relative_to(ROOT).as_posix()
        kotlin_text = kotlin_file.read_text(encoding="utf-8")
        for forbidden in (
            "cmd connectivity airplane-mode",
            "airplane-mode enable",
            "airplane-mode disable",
            "ProcessBuilder",
            "su -c",
            "iptables",
            "ip6tables",
            "svc data",
            "cmd phone data",
            "warp-cli",
            "sing-box",
            "Thread.sleep",
            "SystemClock.sleep",
            "kotlinx.coroutines.delay",
            "CoroutineScope(",
            "GlobalScope",
            "scheduleAtFixedRate",
            "scheduleWithFixedDelay",
            "postDelayed(",
        ):
            if forbidden in kotlin_text:
                raise SystemExit(
                    f"architecture guard: production Kotlin must stay Android-effect/presentation-only; "
                    f"{kotlin_relative} contains {forbidden!r}"
                )
        if kotlin_relative != vpn_observer_relative:
            for forbidden in (
                "Executors.",
                "ScheduledExecutorService",
                "newSingleThreadExecutor",
                "newScheduledThreadPool",
            ):
                if forbidden in kotlin_text:
                    raise SystemExit(
                        f"architecture guard: only AndroidVpnObserver may retain the callback serializer; "
                        f"{kotlin_relative} contains {forbidden!r}"
                    )

    # Native Mesh serving may be stopped by readiness/proxy callbacks already running on the
    # shared PRODUCT Tokio runtime. A direct Handle::block_on from that worker panics and poisons
    # the Mesh owner mutex. The bounded drain must use Tokio's multi-thread block-in-place bridge.
    mesh_serving = "crates/runtime/src/mesh_serving.rs"
    for required in (
        "fn block_on_mesh_drain",
        "Handle::try_current().is_ok()",
        "tokio::task::block_in_place(|| handle.block_on(future))",
    ):
        require_product(
            mesh_serving,
            required,
            "Mesh drain must remain safe when native composition stops ingress from a PRODUCT Tokio worker",
        )
    require(
        mesh_serving,
        "mesh_stop_from_product_tokio_worker_does_not_panic_or_poison_execution_state",
        "Mesh serving must retain the Tokio-worker stop regression test",
    )
    require(
        mesh_serving,
        "mesh_start_from_product_tokio_worker_does_not_starve_listener_startup",
        "Mesh serving must retain the Tokio-worker startup regression test",
    )
    require_product(
        mesh_serving,
        "fn wait_for_mesh_startup",
        "Mesh startup must use the bounded Tokio-aware startup barrier",
    )
    forbid_product(
        mesh_serving,
        "let drained = handle.block_on(async",
        "Mesh serving must not restore a direct nested Handle::block_on drain on a PRODUCT Tokio worker",
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
        "productRuntime.invalidateMeshPlatformFact()",
    ):
        require(
            mesh_android,
            required,
            "Android Mesh adapter must remain raw VPN platform observation only",
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
        "pub(crate) async fn observe_public_egress_ip_async(",
        "execute_public_ip_probe(probe, &tls).await",
        "pub fn observe_public_egress_ip(",
        ".block_on(self.observe_public_egress_ip_async(operation_timeout))",
    ):
        require_product(
            public_ip_runtime,
            required,
            "Cellular runtime must execute U4 through the one shared RuntimeExecutor",
        )
    require_product(
        product_ffi,
        "pub fn observe_public_egress_ip(",
        "NativeProductRuntime must expose the terminal native U4 operation to Android",
    )
    forbid_product(
        product_ffi,
        "pub fn prepare_public_ip_probe(",
        "H closes the instrumentation-only U4 ticket surface; Android must receive terminal observations only",
    )
    forbid_product(
        "crates/android-ffi/src/runtime_boundary.rs",
        "PublicIpProbeTicket",
        "H removes the obsolete Android-effect public-IP ticket FFI vocabulary",
    )
    require(
        public_ip,
        "fn stale_completion_is_rejected_even_with_valid_ip_bytes()",
        "native U4 tests must retain deterministic stale-generation rejection after removing the Android ticket seam",
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
        "phase=u4 positive_https=true owner_bound_dns=true ordinary_uid_socket=true",
        "generation_current=true no_default_fallback=true",
        "fresh_generation=true repeated_observations_bounded=true raw_ip_persisted=false",
    ):
        require(
            public_ip_physical,
            required,
            "U4 physical proof must ride the existing exact-candidate recovery lifecycle",
        )

    for forbidden in (
        "preparePublicIpProbeForInstrumentation",
        "u4StaleTicket",
        "PublicIpProbeTicket",
    ):
        forbid(
            public_ip_physical if forbidden == "u4StaleTicket" else cellular_bridge,
            forbidden,
            "H must not retain the transitional Android U4 ticket seam",
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
        "runtimeController.diagnosticSnapshot()",
        "readiness instrumentation must project the one atomic Rust-owned diagnostic snapshot",
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
        "self.diagnostic_snapshot_with(capture_generation)",
        "let first = capture(&generation)?",
        "let second = capture(&generation)?",
        "root_publication: Option<CellularPolicyPublication>",
        "root_session_generation: Option<u64>",
        "pub rotation: RotationSnapshot",
        "pub rotation_active_tasks: u32",
        "let rotation = generation.rotation();",
        "let rotation_snapshot = rotation.snapshot();",
        "let rotation_active_tasks = rotation.active_task_count();",
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

    require(
        diagnostics_owner,
        "generation_replacement_during_capture_never_returns_a_mixed_snapshot",
        "Rust tests must force generation replacement during diagnostic capture",
    )

    for required in (
        "pub struct ProductDiagnosticSnapshotView",
        "pub fn diagnostic_snapshot(",
        ".diagnostic_snapshot()",
        "map_product_diagnostic_snapshot",
        "root_policy_authorized_generation",
        "root_last_failure_class",
        "root_session_generation",
        "proxy_recovery_operation_id",
        "mesh_serving_generation",
        "readiness_binding_cellular_owner_generation",
        "readiness_expected_freshness",
        "readiness_observed_freshness",
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
    for required in (
        '"policy_authorized_generation"',
        '"last_failure_class"',
        '"session_generation"',
        '"operation_id"',
        '"serving_generation"',
        '"expected_freshness"',
        '"observed_freshness"',
    ):
        require(
            diagnostics,
            required,
            "snapshot_v2 must retain the final U5 owner-backed diagnostic fields",
        )
    diagnostics_test = "android/app/src/test/java/com/mobileproxymish/app/MishDiagnosticsSerializationTest.kt"
    for required in (
        "ProductDiagnosticSnapshotView(",
        "renderMishDiagnosticSnapshotV2(",
        'getLong("policy_authorized_generation")',
        'getLong("operation_id")',
        'getLong("serving_generation")',
        'getLong("expected_freshness")',
        'getLong("observed_freshness")',
    ):
        require(
            diagnostics_test,
            required,
            "Android JVM tests must pin serialization of one native atomic snapshot",
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

    # G first-class rotation is one-way: mish-rotation owns semantics, mish-runtime executes
    # the operation on the existing RuntimeExecutor and persistent root session. Kotlin gets only
    # a typed start command/projection; it owns no phase, timer, airplane command or retry policy.
    rotation_semantics = "crates/rotation/src/lib.rs"
    rotation_runtime = "crates/runtime/src/rotation_runtime.rs"
    airplane_effect = "crates/runtime/src/airplane_effect.rs"
    product_generation = "crates/runtime/src/product_generation.rs"
    proxy_owner = "crates/runtime/src/proxy_coordinator.rs"

    for required in (
        "pub struct RotationStateMachine",
        "pub enum RotationMutationOutcome",
        "pub fn observe_root_policy(",
        "pub fn deadline_exceeded(",
        "RotationTerminalResult::Changed",
        "RotationTerminalResult::Unchanged",
        "RotationTerminalResult::Failed",
        "CredentialChanged,",
    ):
        require_product(
            rotation_semantics,
            required,
            "mish-rotation must remain the sole IP-rotation semantic owner",
        )
    for required in (
        "uncertain_enable_requires_observation_and_is_never_replayed_by_owner",
        "uncertain_disable_requires_observation_and_preserves_restore_requirement",
        "root_authorization_is_an_independent_exact_generation_fact",
        "absolute_deadline_is_terminal_and_keeps_restore_requirement",
        "cellular_loss_during_enable_is_retained_until_airplane_on_is_observed",
    ):
        require(
            rotation_semantics,
            required,
            "rotation pure tests must pin uncertainty/currentness/deadline semantics",
        )

    for required in (
        "pub struct RotationRuntimeCoordinator",
        "ROTATION_SAFETY_DEADLINE",
        "timeout_at(deadline, cancel.notified())",
        "observe_public_egress_ip_async",
        "policy.add_internal_observer",
        "RotationAction::RestoreOff",
        "AirplaneModeState::Enabled",
        "AirplaneModeState::Disabled",
        "credential_guard_current",
        "RESTORE_EFFECT_TIMEOUT",
    ):
        require_product(
            rotation_runtime,
            required,
            "mish-runtime must execute one event-driven rotation on the shared Tokio runtime",
        )
    for forbidden in (
        "Runtime::new",
        "Builder::new",
        "std::thread",
        "thread::sleep",
        "tokio::time::sleep(",
        "retry_until_changed",
    ):
        forbid_product(
            rotation_runtime,
            forbidden,
            "rotation runtime must not create a second executor or arbitrary normal-path dwell/retry loop",
        )

    for required in (
        "RootSessionManager",
        'RootCommand::observation("cmd connectivity airplane-mode")',
        'RootCommand::mutation("cmd connectivity airplane-mode enable")',
        'RootCommand::mutation("cmd connectivity airplane-mode disable")',
        "MutationUncertain",
    ):
        require_product(
            airplane_effect,
            required,
            "airplane observe/ON/OFF must be sealed typed effects over the one persistent root session",
        )

    require_product(
        "crates/runtime/Cargo.toml",
        'mish-rotation = { path = "../rotation" }',
        "mish-runtime must depend on the rotation semantic owner",
    )
    for required in ("mod airplane_effect;", "mod rotation_runtime;"):
        require_product(
            "crates/runtime/src/entry.rs",
            required,
            "rotation execution modules must compile inside mish-runtime",
        )
    for required in (
        "rotation: Arc<RotationRuntimeCoordinator>",
        "let rotation = RotationRuntimeCoordinator::new(",
        "let rotation_clean = self.rotation.shutdown().await;",
    ):
        require_product(
            product_generation,
            required,
            "ProductGeneration must own and drain exactly one rotation runtime",
        )
    for required in (
        "pub fn start_public_ip_rotation(",
        "generation.rotation().observe_cellular(admission)",
        "pub fn rotation_snapshot(",
    ):
        require_product(
            "crates/runtime/src/product_runtime.rs",
            required,
            "stable PRODUCT runtime must expose and feed the Rust-owned rotation operation",
        )
    for required in (
        "struct ProxyCredentialGuard",
        "pub(crate) fn credential_guard(&self)",
        "pub(crate) fn credential_guard_matches",
    ):
        require_product(
            proxy_owner,
            required,
            "network rotation must prove external proxy credential version/material stability",
        )
    for required in (
        "pub struct RotationSnapshotView",
        "pub fn start_public_ip_rotation(",
        "pub fn rotation_snapshot(",
        "rotation_operation_id",
        "rotation_before_generation",
        "rotation_after_generation",
        "rotation_restore_required",
        "rotation_terminal_result",
        "rotation_restore_result",
    ):
        require_product(
            product_ffi,
            required,
            "Android must receive only typed first-class rotation command/projection",
        )

    controller = "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt"
    debug_rotation = "android/app/src/debug/java/com/mobileproxymish/app/DebugRotationActivity.kt"
    debug_stop = "android/app/src/debug/java/com/mobileproxymish/app/DebugRuntimeStopActivity.kt"
    debug_start = "android/app/src/debug/java/com/mobileproxymish/app/DebugRuntimeStartActivity.kt"
    debug_manifest = "android/app/src/debug/AndroidManifest.xml"
    require(
        controller,
        "internal fun startPublicIpRotation(): ULong =",
        "Android may expose only a thin command facade into the Rust-owned rotation operation",
    )
    require(
        controller,
        "productRuntime.startPublicIpRotation(",
        "rotation command facade must delegate directly to native PRODUCT ownership",
    )
    require(
        controller,
        "object : NativeCellularRequestRearmEffect",
        "Android rotation facade may supply only the typed framework re-arm effect requested by Rust",
    )
    require(
        cellular_bridge,
        "internal fun rearmNetworkRequest(): Boolean",
        "Android Cellular bridge must expose only the bounded framework request re-arm effect",
    )
    require(
        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularNetworkObserver.kt",
        "fun rearm()",
        "Android Cellular observer must support one explicit request re-registration effect",
    )
    require_product(
        rotation_runtime,
        "snapshot.phase != RotationPhase::WaitingCellularRecovery",
        "Rust rotation owner must gate Cellular request re-arm to the exact recovery phase",
    )
    require_product(
        rotation_runtime,
        "effect.rearm_cellular_request()",
        "Rust rotation owner must invoke the typed Cellular request re-arm effect",
    )
    require_product(
        rotation_runtime,
        "RotationFailure::FreshCellularUnavailable",
        "a failed Cellular request re-arm must fail the Rust-owned rotation closed",
    )
    require_product_count(
        rotation_runtime,
        "effect.rearm_cellular_request()",
        1,
        "Cellular request re-arm must have one PRODUCT invocation site and no retry loop",
    )
    require_product_count(
        rotation_runtime,
        "!self.rearm_cellular_request_if_waiting(operation_id)",
        1,
        "confirmed airplane OFF must trigger exactly one Rust-owned re-arm decision",
    )
    for required in (
        "class DebugRotationActivity : Activity()",
        "runCatching(runtime::startPublicIpRotation)",
        'const val TAG = "MishRotationAcceptance"',
    ):
        require(
            debug_rotation,
            required,
            "H acceptance trigger must remain a zero-input debug-only PRODUCT command",
        )
    for required in (
        "class DebugRuntimeStopActivity : Activity()",
        "val stopped = runtime.stop()",
        'const val TAG = "MishRuntimeStopAcceptance"',
    ):
        require(
            debug_stop,
            required,
            "H restore acceptance must use only the normal PRODUCT stop path",
        )
    for required in (
        "class DebugRuntimeStartActivity : Activity()",
        "ProxyRuntimeService.requestStart(this)",
        'const val TAG = "MishRuntimeStartAcceptance"',
    ):
        require(
            debug_start,
            required,
            "H restore acceptance start trigger must remain a zero-input debug-only service-lifetime request",
        )
    for debug_path in (debug_rotation, debug_stop, debug_start):
        for forbidden in (
            "cmd connectivity airplane-mode",
            "Thread.sleep",
            "SystemClock.sleep",
            "kotlinx.coroutines.delay",
            "AIRPLANE_ENABLING",
            "WAITING_RADIO_DOWN",
            "AIRPLANE_DISABLING",
            "WAITING_CELLULAR_RECOVERY",
            "WAITING_ROOT_POLICY",
            "PROBING_PUBLIC_IP",
        ):
            forbid(
                debug_path,
                forbidden,
                "debug H trigger must never become a second rotation/platform-effect owner",
            )
    for required in (
        'android:name=".DebugRotationActivity"',
        'android:name=".DebugRuntimeStopActivity"',
        'android:name=".DebugRuntimeStartActivity"',
    ):
        require(
            debug_manifest,
            required,
            "H acceptance triggers must be packaged only by the debug source set",
        )
    for forbidden in ("DebugRotationActivity", "DebugRuntimeStopActivity", "DebugRuntimeStartActivity"):
        forbid(
            "android/app/src/main/AndroidManifest.xml",
            forbidden,
            "H acceptance trigger must not leak into release PRODUCT manifest",
        )

    for kotlin_path in (
        "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MainViewModel.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MainActivity.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularNetworkObserver.kt",
    ):
        for forbidden in (
            "cmd connectivity airplane-mode",
            "AIRPLANE_ENABLING",
            "WAITING_RADIO_DOWN",
            "AIRPLANE_DISABLING",
            "WAITING_CELLULAR_RECOVERY",
            "WAITING_ROOT_POLICY",
            "PROBING_PUBLIC_IP",
            "kotlinx.coroutines.delay",
            "Thread.sleep",
        ):
            forbid(
                kotlin_path,
                forbidden,
                "Kotlin must not regain rotation semantics, airplane commands or normal-path timing",
            )

    for forbidden in ("before_ip", "after_ip", "beforeIp", "afterIp"):
        forbid(
            diagnostics,
            forbidden,
            "raw public IP must never cross the durable/diagnostic Android boundary",
        )
    require(
        diagnostics,
        'put("raw_ip_persisted", false)',
        "rotation diagnostics must explicitly prove raw IP is not persisted",
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

    # Android physical acceptance has one artifact authority. The obsolete RC/prerelease
    # pipeline and its release-lineage helpers must never return beside PR Validation + PRODUCT Candidate
    # + manual Device Cycle.
    for obsolete_path in (
        ".github/workflows/android-release.yml",
        ".github/workflows/e3-physical-cellular.yml",
        "scripts/release/android_release.py",
        "scripts/release/e3_harness.py",
        "scripts/release/failed_rc_reservation.py",
        "scripts/release/test_android_release.py",
        "scripts/release/test_e3_harness.py",
        "scripts/release/test_failed_rc_reservation.py",
        "scripts/release/test_release_workflow_topology.py",
    ):
        forbid_exists(
            obsolete_path,
            "obsolete RC/release-lineage pipeline must stay deleted; exact hosted device candidate + Device Cycle is the sole Android physical-acceptance path",
        )

    require(
        ".github/workflows/integration-android-preflight.yml",
        "name: device-candidate-pr-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}",
        "PR Validation + PRODUCT Candidate must remain the exact-head Android candidate producer",
    )
    require(
        ".github/workflows/device-cycle.yml",
        "candidate artifact did not originate from PR Validation + PRODUCT Candidate",
        "Device Cycle must consume only the exact hosted candidate producer",
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
    main_activity = "android/app/src/main/java/com/mobileproxymish/app/MainActivity.kt"
    main_screen = "android/app/src/main/java/com/mobileproxymish/app/MainScreen.kt"
    require(
        main_screen,
        '"Proxy credentials"',
        "explicit user credential access must remain visible and opt-in",
    )
    require(
        main_screen,
        "SecureFlagPolicy.SecureOn",
        "explicit credential reveal must be protected from platform screenshots",
    )
    require(
        main_activity,
        """override fun onStart() {
        super.onStart()
        ProxyRuntimeService.requestStart(this)
    }""",
        "foreground activity resume must request the Android service lifetime without owning PRODUCT recovery",
    )
    forbid(
        main_activity,
        """super.onCreate(savedInstanceState)
        ProxyRuntimeService.requestStart(this)""",
        "creation-only service delivery can miss an already-live Activity task after a normal runtime stop",
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

    # U6 Backend-driven Product UI: Kotlin projects typed owner facts and forwards one explicit
    # user command. It must not regain PRODUCT state/effect ownership.
    u6_ui_paths = (
        "android/app/src/main/java/com/mobileproxymish/app/MainActivity.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MainViewModel.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MainScreen.kt",
        "android/app/src/main/java/com/mobileproxymish/app/ProductUiState.kt",
    )
    for kotlin_path in u6_ui_paths:
        for forbidden in (
            "ConnectivityManager",
            "cmd connectivity airplane-mode",
            "setAirplaneMode",
            "rearmNetworkRequest",
            "RuntimeExecutor",
            "NativeProductRuntime(",
            "Thread.sleep",
            "SystemClock.sleep",
            "kotlinx.coroutines.delay",
            "WorkManager",
        ):
            forbid(
                kotlin_path,
                forbidden,
                "U6 UI/ViewModel must remain presentation-only over Rust/Tokio PRODUCT owners",
            )

    for kotlin_path in (
        "android/app/src/main/java/com/mobileproxymish/app/MainViewModel.kt",
        "android/app/src/main/java/com/mobileproxymish/app/ProductUiState.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MainScreen.kt",
    ):
        for forbidden in (
            "SharedPreferences",
            "DataStore",
            "SQLite",
            "RoomDatabase",
            "java.io.File",
        ):
            forbid(
                kotlin_path,
                forbidden,
                "U6 live PRODUCT/public-IP state must not gain Android persistence",
            )

    product_ui = "android/app/src/main/java/com/mobileproxymish/app/ProductUiState.kt"
    for forbidden in ("val username", "val password", "CredentialRevealUiState"):
        forbid(
            product_ui,
            forbidden,
            "normal ProductUiState must never carry proxy credential material",
        )

    main_view_model = "android/app/src/main/java/com/mobileproxymish/app/MainViewModel.kt"
    require(
        main_view_model,
        "runCatching(runtimeController::startPublicIpRotation)",
        "Change IP must forward through the single accepted MishRuntimeController command seam",
    )
    for forbidden in (
        "MutableStateFlow<Boolean>",
        "rotationLock",
        "rotationTimer",
        "retry(",
        "retryWhen",
    ):
        forbid(
            main_view_model,
            forbidden,
            "MainViewModel must not become a second rotation/retry/concurrency owner",
        )

    for required in (
        'Text("Public IP"',
        '"Advanced diagnostics"',
        '"Proxy credentials"',
        'Text(if (state.inProgress) "Changing…" else "Change IP")',
        "LinearProgressIndicator(",
    ):
        require(
            main_screen,
            required,
            "U6 production dashboard must retain its explicit accessible presentation seams",
        )
    for forbidden in ("delay(", "Thread.sleep", "SystemClock.sleep"):
        forbid(
            main_screen,
            forbidden,
            "U6 dashboard must not synthesize progress/timing",
        )

    for required in (
        "pub enum RotationPhaseView",
        "pub enum RotationTerminalResultView",
        "pub enum RotationFailureView",
        "pub trait NativeRotationObserver",
        "pub fn observe_rotation(",
        "pub trait NativeMeshRuntimeObserver",
        "pub fn observe_mesh_runtime(",
        "before_ip: snapshot.before_ip.map",
        "after_ip: snapshot.after_ip.map",
        "pub fn proxy_listener_contract(",
    ):
        require_product(
            product_ffi,
            required,
            "U6 UI facts must be typed read-only projections of existing Rust owners",
        )

    for required in (
        "endpoint: admission",
        ".admitted_endpoint()",
        ".map(|address| address.to_string())",
    ):
        require_product(
            "crates/android-ffi/src/transport_ffi.rs",
            required,
            "U6 proxy endpoint presentation must project the existing Mesh endpoint owner fact",
        )
    require(
        controller,
        "productRuntime.observeRotation(",
        "Android must observe rotation from the existing native owner instead of polling",
    )
    require(
        controller,
        "productRuntime.observeMeshRuntime(",
        "Android must observe Mesh composition from the existing native owner instead of stale platform callbacks",
    )
    require(
        controller,
        "productRuntime.proxyListenerContract()",
        "proxy protocol/port information must come from the canonical Rust proxy contract",
    )
    mesh_bridge = "android/app/src/main/java/com/mobileproxymish/app/MeshIngressRuntimeBridge.kt"
    for forbidden in ("MutableStateFlow", "val snapshot: StateFlow"):
        forbid(
            mesh_bridge,
            forbidden,
            "Android Mesh bridge must remain platform observation-only; current Mesh UI state comes from Rust owner publications",
        )
    for required in (
        "private fun currentCellularGeneration(",
        "input.rotation.afterGeneration == currentCellularGeneration",
    ):
        require(
            product_ui,
            required,
            "Current IP must be shown only for the currently admitted Cellular owner generation",
        )

    print("ARCHITECTURE_GUARDS=PASS")


if __name__ == "__main__":
    main()
