#!/usr/bin/env python3
"""Verify the accepted Android candidate surface for this exact source tree."""

from __future__ import annotations

import os
import re
from pathlib import Path
import subprocess
import zipfile


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    target_abi = os.environ.get("MISH_TARGET_ABI", "")
    require(target_abi in {"armeabi-v7a", "arm64-v8a"}, f"unsupported MISH_TARGET_ABI: {target_abi!r}")

    apk = Path("android/app/build/outputs/apk/debug/app-debug.apk")
    test_apk = Path("android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk")
    native = Path(f"android/app/build/generated/rust-jni/{target_abi}/libmish_android_ffi.so")
    generated = Path("android/app/build/generated/uniffi/kotlin/com/mobileproxymish/ffi/mish_android_ffi.kt")

    for path in (apk, test_apk, native, generated):
        require(path.is_file(), f"required candidate output is missing: {path}")

    with zipfile.ZipFile(apk) as archive:
        names = set(archive.namelist())
    require(f"lib/{target_abi}/libmish_android_ffi.so" in names, "packaged PRODUCT APK is missing libmish_android_ffi.so")
    require(f"lib/{target_abi}/libjnidispatch.so" in names, "packaged PRODUCT APK is missing libjnidispatch.so")
    require(not any(name.endswith("/libsingbox.so") or name == "libsingbox.so" for name in names), "obsolete sing-box binary leaked into native PRODUCT APK")

    symbols = subprocess.run(["readelf", "-Ws", str(native)], check=True, capture_output=True, text=True).stdout
    require("android_getaddrinfofornetwork" in symbols, "required android_getaddrinfofornetwork symbol is missing from PRODUCT FFI library")
    require("android_setsocknetwork" not in symbols, "superseded android_setsocknetwork leaked into PRODUCT FFI library")

    surface = generated.read_text(encoding="utf-8")
    required = (
        "NativeProductRuntime",
        "NativeProxyRuntimeObserver",
        "NativeReadinessObserver",
        "NativeCellularPolicyObserver",
        "CellularNetworkObservationInput",
        "RuntimeLifecycleSnapshotView",
        "ProxyRuntimePublicationView",
        "ProductDiagnosticSnapshotView",
        "diagnosticSnapshot",
        "ReadinessDiagnosticView",
        "MeshAdmissionView",
        "ExternalCredentialCanonicalStateView",
        "ExternalCredentialPersistenceActionView",
        "ExternalCredentialPersistenceResolutionView",
        "externalCredentialResolvePersistence",
        "externalCredentialRotate",
        "externalCredentialRevoke",
        "externalCredentialDerivation",
        "externalCredentialMaterialize",
        "externalCredentialEncodeProvisioningEnvelope",
    )
    forbidden = (
        "CellularController",
        "MeshTransportController",
        "RuntimeLifecycleController",
        "RuntimeProcessLifecycleController",
        "RuntimeStartAction",
        "RuntimeStopAction",
        "ProxyServingSnapshotView",
        "NativeProxyRuntime",
        "ProxyServingLifecycleController",
        "CellularNetworkLease",
        "admittedNetworkLease",
        "bindSocket",
        "resolveHost",
        "proxyServingFailureRecoverable",
        "proxyListenerPorts",
        "PrivateBridge",
        "readinessDiagnosticSnapshot",
        "proxyActiveSessions",
        "dnsDiagnosticSnapshot",
        "cellularReconcileDiagnostic",
        "rootRecoveryDiagnostic",
        "rootPolicyReconcileDiagnostic",
        "externalCredentialInitialState",
        "externalCredentialRestore",
    )
    for symbol in required:
        require(symbol in surface, f"required UniFFI PRODUCT surface is missing: {symbol}")
    for symbol in forbidden:
        leaked = re.search(rf"\\b{re.escape(symbol)}\\b", surface) is not None
        require(not leaked, f"obsolete or uncontrolled API leaked into UniFFI surface: {symbol}")

    print("ANDROID_CANDIDATE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
