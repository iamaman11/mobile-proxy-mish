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


def require(path: str, needle: str, reason: str) -> None:
    if needle not in read(path):
        raise SystemExit(f"architecture guard: {reason}: {path} lacks {needle!r}")


def forbid(path: str, needle: str, reason: str) -> None:
    if needle in read(path):
        raise SystemExit(f"architecture guard: {reason}: {path} contains {needle!r}")


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

    # Native Proxy Serving owns one explicit Tokio task tree.
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
        "ProxyServingLifecycleController",
        "UniFFI must project native Proxy Serving lifecycle",
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
        "error.lifecycle_failure()",
        "runtime owner must classify native startup mechanism failures before FFI",
    )

    mesh_ffi = "crates/android-ffi/src/transport_ffi.rs"
    require(
        mesh_ffi,
        "MeshTransportCoordinator",
        "Mesh FFI must delegate runtime coordination to the Transport owner",
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
    transport = "crates/transport/src/lib.rs"
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
    require(
        proxy_android,
        "val startFailure = attempt.failure()",
        "Android proxy adapter must publish Rust-owned typed startup failures",
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

    # Root authority proof and root-shell transport are separate responsibilities.
    authority = "android/app/src/main/java/com/mobileproxymish/app/cellular/MagiskRootAuthority.kt"
    transport_path = "android/app/src/main/java/com/mobileproxymish/app/cellular/RootCommandTransport.kt"
    require(authority, "class MagiskRootAuthority", "Magisk authority proof must remain explicit")
    forbid(authority, "ProcessBuilder", "Magisk authority must not own root-shell process transport")
    require(transport_path, 'ProcessBuilder("su")', "one persistent su transport must remain explicit")
    require(transport_path, "sharedSession", "root transport must remain process-wide and generation-aware")

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
