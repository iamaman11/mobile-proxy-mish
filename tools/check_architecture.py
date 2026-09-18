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
    require(
        runtime_controller,
        "proxyServingFailureRecoverable(reason)",
        "proxy recovery classification must remain delegated to the Rust runtime owner",
    )
    require(
        runtime_controller,
        "proxyRecoveryDelayMs(attempt)",
        "proxy recovery backoff must remain delegated to the Rust runtime owner",
    )
    require(
        runtime_controller,
        "onFailureObserved = ::scheduleProxyRecoveryIfAllowed",
        "every typed Proxy Serving failure must flow through the one Rust-owned recovery policy",
    )

    # Cross-owner runtime composition decisions belong to Rust, not Android adapters.
    mesh_serving = "crates/runtime/src/mesh_serving.rs"
    require(
        mesh_serving,
        "pub const fn mesh_ingress_serving_allowed",
        "Rust runtime must own Mesh ingress serving eligibility",
    )
    mesh_android = "android/app/src/main/java/com/mobileproxymish/app/MeshIngressRuntimeBridge.kt"
    require(
        mesh_android,
        "meshIngressServingAllowed(",
        "Android Mesh adapter must delegate serving eligibility to Rust",
    )
    forbid(
        mesh_android,
        "internal fun meshIngressServingAllowed",
        "Android Mesh adapter must not duplicate cross-owner serving policy",
    )
    require(
        "crates/android-ffi/src/runtime_composition_ffi.rs",
        "owner_mesh_ingress_serving_allowed",
        "Mesh serving composition FFI must remain a thin Rust delegation",
    )

    # U5 execution law: exactly one process-generation Tokio owner exists. Proxy/Mesh borrow its
    # Handle; neither serving component may construct or destroy another runtime.
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
    for required in (
        "val owner = activeController.admissionSnapshot()",
        "activeSessions = owner.activeSessions",
        "capacityRejects = owner.capacityRejects",
    ):
        require(
            mesh_android,
            required,
            "Android diagnostics must project one natural Transport-owned Mesh capacity observation",
        )
    for duplicate_counter in ("AtomicInteger", "AtomicLong", "LongAdder"):
        forbid(
            mesh_android,
            duplicate_counter,
            "Android must not acquire a duplicate Mesh active-session counter",
        )

    # Proxy-target DNS/public egress has exactly one Cellular Egress path and no default fallback.
    runtime_dns = "crates/runtime/src/cellular_connector.rs"
    require(
        runtime_dns,
        "pub trait CellularDnsResolver",
        "Runtime must keep one injected Cellular Egress DNS consumer port",
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

    public_ip_android = "android/app/src/main/java/com/mobileproxymish/app/cellular/PublicIpProbeEffect.kt"
    for required in (
        "InetAddress.getByAddress(",
        "SSLSocketFactory.getDefault() as SSLSocketFactory",
        "tlsFactory.createSocket(",
        "getDefaultHostnameVerifier().verify(",
        "ticket.remainingTimeoutMs()",
        "ticket.complete(body)",
    ):
        require(
            public_ip_android,
            required,
            "Android U4 adapter must remain a narrow bounded TLS/HTTPS effect",
        )

    public_ip_physical = (
        "android/app/src/androidTest/java/com/mobileproxymish/app/cellular/"
        "CellularE3InstrumentedTest.kt"
    )
    for required in (
        "runtime.observePublicEgressIp(",
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

    # Readiness is one pure Rust terminal projection. Android only assembles facts and executes probe effects.
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
        "ProductReadinessController",
        "Android readiness must delegate freshness/projection decisions to Rust",
    )
    forbid(readiness_ffi, "private_bridge", "readiness FFI must expose native facts only")
    readiness_eligibility_ffi = "crates/android-ffi/src/readiness_eligibility_ffi.rs"
    require(
        readiness_eligibility_ffi,
        "probe_eligibility(input)",
        "readiness eligibility FFI must delegate to the Rust predicate",
    )
    require(
        "crates/android-ffi/src/entry.rs",
        "mod readiness_eligibility_ffi;",
        "readiness eligibility UniFFI boundary must remain generated",
    )
    readiness_android = "android/app/src/main/java/com/mobileproxymish/app/ProductReadinessRuntime.kt"
    for required in (
        "ProductReadinessController()",
        "controller.invalidateProbe()",
        "controller.beginProbe(binding)",
        "controller.completeProbe(ticket, outcome, elapsedMs)",
        "controller.project(facts, observation)",
        "readinessProbeBindingIfEligible(facts)",
        "readinessProbeTarget()",
        "egressProbeBudgetMs()",
        "AuthenticatedEgressProbe",
    ):
        require(
            readiness_android,
            required,
            "Android readiness adapter must remain Rust-directed and effect-only",
        )
    forbid(
        readiness_android,
        "candidateBinding(",
        "Android readiness adapter must not duplicate structural eligibility policy",
    )
    probe_effect = "android/app/src/main/java/com/mobileproxymish/app/AuthenticatedEgressProbe.kt"
    for required in (
        "InetSocketAddress(LOOPBACK, proxyHttpConnectPort().toInt())",
        "Proxy-Authorization: Basic",
        "it.startHandshake()",
        "HttpsURLConnection.getDefaultHostnameVerifier().verify(target.hostname, it.session)",
    ):
        require(probe_effect, required, "bounded Android readiness effect contract must stay explicit")
    for forbidden in (
        "InetSocketAddress(target.hostname",
        "Socket(target.hostname",
        "HttpURLConnection",
        "java.net.URL",
    ):
        forbid(
            probe_effect,
            forbidden,
            "Android readiness must not resolve/connect the public hostname outside PRODUCT proxy",
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
    lifecycle_ffi = "crates/android-ffi/src/runtime_lifecycle_ffi.rs"
    require(
        lifecycle_ffi,
        "pub struct ProxyServingSnapshotView",
        "UniFFI must expose the immutable native Proxy Serving snapshot type",
    )
    forbid(
        lifecycle_ffi,
        "ProxyServingLifecycleController",
        "UniFFI must not expose a second mutable Proxy Serving lifecycle controller",
    )
    forbid(lifecycle_ffi, "RuntimeProcessLifecycle", "child-process lifecycle must not return to FFI")
    proxy_serving_ffi = "crates/android-ffi/src/proxy_serving_ffi.rs"
    require(
        proxy_serving_ffi,
        "NativeProxyStartAttempt",
        "expected native proxy startup failures must cross FFI as typed data",
    )
    require(
        proxy_serving_ffi,
        "pub fn snapshot(&self) -> ProxyServingSnapshotView",
        "UniFFI must project the runtime-owned Proxy Serving snapshot read-only",
    )
    require(
        proxy_serving_ffi,
        "error.lifecycle_failure()",
        "runtime owner must classify native startup mechanism failures before FFI",
    )
    require(
        proxy_serving_ffi,
        "pub(crate) fn runtime_handle(&self) -> Arc<ProxyServingRuntime>",
        "FFI must expose only a Rust-private opaque handle to the existing process runtime",
    )

    mesh_ffi = "crates/android-ffi/src/transport_ffi.rs"
    require(
        mesh_ffi,
        "MeshTransportCoordinator",
        "Mesh FFI must delegate runtime coordination to the Transport owner",
    )
    require(
        mesh_ffi,
        "process_runtime: Arc<NativeProxyRuntime>",
        "Mesh FFI composition must receive the existing opaque native runtime",
    )
    for symbol in (
        "struct MeshTransportState",
        "MeshEndpointOwner",
        "MeshIngressRuntime",
        "ingress_epoch",
        "cleanup_failed",
    ):
        forbid(mesh_ffi, symbol, "Mesh lifecycle state must not drift into android-ffi")

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
    require(
        readiness_ffi,
        "HTTP_CONNECT_PORT",
        "readiness probe HTTP port must project Proxy Serving desired state",
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
    require(
        proxy_android,
        "val startFailure = attempt.failure()",
        "Android proxy adapter must publish Rust-owned typed startup failures",
    )
    require(
        proxy_android,
        "newRuntime.snapshot()",
        "Android proxy adapter must project the immutable Rust-owned runtime snapshot",
    )
    require(
        proxy_android,
        "onFailureObserved(reason)",
        "startup and post-start failures must share one typed recovery-notification path",
    )

    # Diagnostics v2 observes current owner facts only. It must never become a repair/control path.
    diagnostics = "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt"
    require(diagnostics, 'MISH_DIAGNOSTICS_SCHEMA_V2 = "mish.diagnostics/v2"', "diagnostics must be versioned v2")
    require(diagnostics, 'MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2 = "snapshot_v2"', "diagnostics method must be v2")
    for obsolete in ("MISH_DIAGNOSTICS_SCHEMA_V1", "snapshot_v1", 'put("bridge"', "private_healthy", "privateBridge"):
        forbid(diagnostics, obsolete, "diagnostics must not retain deleted private-bridge semantics")
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
        "CellularPolicyCoordinator::new",
        "RuntimeExecutor::new",
        "observe_cellular_policy",
    ):
        require_product(product_ffi, required, "Android must receive one opaque native PRODUCT generation handle")

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
    ):
        forbid_exists(obsolete_path, "Kotlin must not regain a second root-policy/root-session control plane")

    cellular_bridge = "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt"
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
            "Android Cellular bridge must stay an observation/effect adapter only",
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

    # Credentials stay versioned in Rust with Android Keystore only as the physical secret root.
    proto = "contracts/proto/mish/credentials/v1/credentials.proto"
    require(proto, "package mish.credentials.v1;", "credential protobuf package must remain versioned")
    require(proto, "message ExternalProxyProvisioningEnvelope", "provisioning contract must remain protobuf")
    require(
        "android/app/src/main/java/com/mobileproxymish/app/ExternalProxyCredentialStore.kt",
        "state_pb_b64_v1",
        "Android durable credential metadata must remain one protobuf state blob",
    )

    # No second Android VPN/TUN ownership may appear in PRODUCT.
    manifest = read("android/app/src/main/AndroidManifest.xml")
    if "VpnService" in manifest or "android.net.VpnService" in manifest:
        raise SystemExit("architecture guard: PRODUCT manifest must not declare a second Android VPN service")

    print("ARCHITECTURE_GUARDS=PASS")


if __name__ == "__main__":
    main()
