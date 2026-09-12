#!/usr/bin/env python3
"""Fail-closed architecture guards for the accepted M1 owner topology.

These checks deliberately target architectural regressions that ordinary unit tests cannot see:
forbidden dependency direction, duplicate product facts, stateful FFI ownership, and contract drift.
They do not claim physical Android/Cloudflare behavior.
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


def require_regex(path: str, pattern: str, reason: str) -> None:
    if re.search(pattern, read(path), flags=re.MULTILINE) is None:
        raise SystemExit(f"architecture guard: {reason}: {path} does not match {pattern!r}")


def forbid_regex(path: str, pattern: str, reason: str) -> None:
    if re.search(pattern, read(path), flags=re.MULTILINE) is not None:
        raise SystemExit(f"architecture guard: {reason}: {path} matches {pattern!r}")


def main() -> None:
    # Runtime Lifecycle must remain vendor/platform neutral.
    forbid(
        "crates/runtime/Cargo.toml",
        "mish-android-network",
        "Runtime Lifecycle must not depend on the Android network adapter",
    )
    require(
        "crates/android-ffi/Cargo.toml",
        "mish-android-network",
        "Android DNS mechanics belong at the platform/FFI adapter boundary",
    )
    forbid(
        "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt",
        "enum class LifecycleState",
        "Kotlin must not reintroduce a parallel foreground lifecycle state machine",
    )
    forbid(
        "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        "class ProxyRuntimeLifecycle",
        "Kotlin must not reintroduce a parallel child-process lifecycle owner",
    )
    forbid(
        "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt",
        "RuntimeCleanupDisposition(",
        "cleanup disposition policy belongs to crates/runtime",
    )

    # Proxy-target DNS stays one Cellular Egress consumer path with no default/process fallback.
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
        "Android proxy-target DNS must remain scoped to the owner-issued network handle",
    )
    for product_path in (
        runtime_dns,
        "crates/android-ffi/src/lib.rs",
        "crates/sing-box-adapter/src/lib.rs",
    ):
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
            "Network.bindSocket(",
        ):
            if fallback in kotlin:
                relative = kotlin_path.relative_to(ROOT)
                raise SystemExit(
                    "architecture guard: proxy-target DNS/public egress must not gain "
                    f"process/default/per-socket network fallback: {relative} contains {fallback!r}"
                )

    # Stateful private-bridge/root-policy coordination must not drift back into FFI.
    ffi = "crates/android-ffi/src/lib.rs"
    for symbol in (
        "struct RootPolicyEffectGate",
        "struct RootPolicyGatedConnector",
        "struct SessionRegistry",
        "bridge_accept_loop",
    ):
        forbid(ffi, symbol, "android-ffi must remain a typed adapter rather than a runtime owner")

    # Mesh Transport runtime/lifecycle state belongs to crates/transport, never the FFI seam.
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
        forbid(
            mesh_ffi,
            symbol,
            "Mesh admission/ingress lifecycle state must not drift back into android-ffi",
        )

    # Proxy Serving is the sole product listener-fact owner.
    proxy = "crates/proxy/src/lib.rs"
    require(proxy, "pub const fn canonical_listeners", "Proxy Serving must expose its canonical listener contract")
    transport = "crates/transport/src/lib.rs"
    forbid(transport, "PRODUCT_PROXY_PORTS", "Transport must not own product proxy ports")
    forbid_regex(
        transport,
        r"\[\s*1080\s*,\s*1081\s*,\s*3128\s*\]",
        "Transport must not duplicate the product proxy-port tuple",
    )
    kotlin_proxy = "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt"
    forbid(kotlin_proxy, "PUBLIC_PORTS", "Android must not duplicate product proxy ports")
    require(kotlin_proxy, "proxyListenerPorts", "Android health must project Proxy Serving listener facts")

    # Desired Configuration is the sole deployment Mesh CIDR source.
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
        "Desired Configuration must consume the canonical deployment file",
    )
    mesh_android = "android/app/src/main/java/com/mobileproxymish/app/MeshIngressRuntimeBridge.kt"
    for duplicate in ("100.96.0.0", "DEPLOYMENT_ACCEPTED_MESH_NETWORK", "DEPLOYMENT_ACCEPTED_MESH_PREFIX"):
        forbid(mesh_android, duplicate, "Android must not own a Mesh accepted-range literal")
    forbid(
        "infra/cloudflare/variables.tf",
        'variable "mesh_device_cidr"',
        "Terraform must not define a second Mesh CIDR value/default",
    )
    require(
        "infra/cloudflare/main.tf",
        "config/deployment/mesh-device-cidr.txt",
        "Terraform must consume the canonical Mesh CIDR file",
    )

    # Versioned protobuf is the product credential serialization contract.
    proto = "contracts/proto/mish/credentials/v1/credentials.proto"
    require(proto, "package mish.credentials.v1;", "credential protobuf package must remain versioned")
    require(proto, "message ExternalProxyProvisioningEnvelope", "provisioning contract must remain protobuf")
    for product_path in (
        "android/app/src/main/java/com/mobileproxymish/app/CredentialProvisioningReceiver.kt",
        "lab/windows/CredentialProvisioning.psm1",
    ):
        for json_token in ("ConvertFrom-Json", "JSONObject", 'append("{\\\"v\\\":")'):
            forbid(product_path, json_token, "credential provisioning must not return to ad-hoc JSON")
    require(
        "android/app/src/main/java/com/mobileproxymish/app/ExternalProxyCredentialStore.kt",
        "state_pb_b64_v1",
        "Android durable credential metadata must remain one protobuf state blob",
    )

    # No second Android VPN/TUN ownership may appear in the product manifest.
    manifest = read("android/app/src/main/AndroidManifest.xml")
    if "VpnService" in manifest or "android.net.VpnService" in manifest:
        raise SystemExit("architecture guard: PRODUCT manifest must not declare a second Android VPN service")

    print("ARCHITECTURE_GUARDS=PASS")


if __name__ == "__main__":
    main()
