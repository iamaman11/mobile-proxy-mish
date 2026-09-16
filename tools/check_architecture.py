#!/usr/bin/env python3
"""Fail-closed architecture guards for the native MISH product topology.

These checks cover ownership/dependency regressions that ordinary unit tests cannot see. They are
not a substitute for physical Android/Cloudflare/cellular acceptance.
"""

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
    forbid(
        "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt",
        "enum class LifecycleState",
        "Kotlin must not reintroduce a parallel foreground lifecycle state machine",
    )
    forbid(
        "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        "class ProxyRuntimeLifecycle",
        "Kotlin must not reintroduce a parallel proxy lifecycle owner",
    )
    forbid(
        "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt",
        "RuntimeCleanupDisposition(",
        "cleanup disposition policy belongs to crates/runtime",
    )

    # Proxy-target DNS/public egress has exactly one Cellular Egress path and no default fallback.
    runtime_dns = "crates/runtime/src/lib.rs"
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
    for product_path in (runtime_dns, "crates/android-ffi/src/lib.rs"):
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

    # Readiness is one pure Rust terminal projection. Android only executes the concrete probe.
    readiness = "crates/readiness/src/lib.rs"
    require(readiness, "pub enum Readiness", "Readiness must expose one terminal projection type")
    require(readiness, "pub fn project(", "Readiness must remain a pure projection function")
    require(
        readiness,
        "pub struct EgressProbeObservation",
        "Readiness must consume one typed generation-bound probe observation",
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
    require(
        "crates/android-ffi/src/entry.rs",
        "mod readiness_ffi;",
        "readiness UniFFI boundary must remain generated",
    )
    readiness_android = "android/app/src/main/java/com/mobileproxymish/app/ProductReadinessRuntime.kt"
    for required in (
        "ProductReadinessController()",
        "controller.invalidateProbe()",
        "controller.beginProbe(binding)",
        "controller.completeProbe(ticket, outcome, elapsedMs)",
        "controller.project(facts, observation)",
        "InetSocketAddress(LOOPBACK, proxyHttpConnectPort().toInt())",
        "readinessProbeTarget()",
        "egressProbeBudgetMs()",
        "Proxy-Authorization: Basic",
        "it.startHandshake()",
        "HttpsURLConnection.getDefaultHostnameVerifier().verify(target.hostname, it.session)",
    ):
        require(
            readiness_android,
            required,
            "Android readiness must remain one bounded Rust-directed loopback proxy/TLS effect",
        )
    for forbidden in (
        "InetSocketAddress(target.hostname",
        "Socket(target.hostname",
        "HttpURLConnection",
        "java.net.URL",
    ):
        forbid(
            readiness_android,
            forbidden,
            "Android readiness must not resolve/connect the public hostname outside PRODUCT proxy",
        )

    # Stateful runtime coordination must not drift into the FFI seam.
    ffi = "crates/android-ffi/src/lib.rs"
    for symbol in (
        "struct RootPolicyEffectGate",
        "struct RootPolicyGatedConnector",
        "struct SessionRegistry",
        "bridge_accept_loop",
    ):
        forbid(ffi, symbol, "android-ffi must remain a typed adapter rather than a runtime owner")

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
    require(
        readiness_ffi,
        "HTTP_CONNECT_PORT",
        "readiness probe HTTP port must project Proxy Serving desired state",
    )

    # L8 native cutover is one-way: obsolete sing-box bytes/build adapters may not return.
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
