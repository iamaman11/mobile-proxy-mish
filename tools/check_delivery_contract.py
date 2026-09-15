#!/usr/bin/env python3
"""Fail-closed checks for the development build/CI/DEVICE-1 delivery contract."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    target = ROOT / path
    if not target.is_file():
        raise SystemExit(f"delivery contract: required file missing: {path}")
    return target.read_text(encoding="utf-8")


def require(path: str, needle: str, reason: str) -> None:
    if needle not in read(path):
        raise SystemExit(f"delivery contract: {reason}: {path} lacks {needle!r}")


def forbid(path: str, needle: str, reason: str) -> None:
    if needle in read(path):
        raise SystemExit(f"delivery contract: {reason}: {path} contains {needle!r}")


def require_regex(path: str, pattern: str, reason: str) -> None:
    if re.search(pattern, read(path), flags=re.MULTILINE | re.DOTALL) is None:
        raise SystemExit(f"delivery contract: {reason}: {path} does not match {pattern!r}")


def forbid_regex(path: str, pattern: str, reason: str) -> None:
    if re.search(pattern, read(path), flags=re.MULTILINE | re.DOTALL) is not None:
        raise SystemExit(f"delivery contract: {reason}: {path} matches {pattern!r}")


def main() -> None:
    build = "android/app/build.gradle.kts"
    require(build, "val androidMinSdk = 30", "Android PRODUCT floor must be one API-30 authority")
    require(build, "minSdk = androidMinSdk", "Android package floor must use androidMinSdk")
    require(build, 'inputs.property("androidMinSdk", androidMinSdk)', "native build inputs must include the PRODUCT floor")
    require_regex(
        build,
        r'"cargo"\s*,\s*"ndk"\s*,\s*"-P"\s*,\s*androidMinSdk\.toString\(\)',
        "cargo-ndk platform floor must use androidMinSdk",
    )
    forbid_regex(build, r"\bminSdk\s*=\s*(?:23|26)\b", "API 23/26 package compatibility must not return")
    forbid_regex(build, r'"-P"\s*,\s*"(?:23|26)"', "API 23/26 native compatibility must not return")
    require(build, "dependsOn(generateUniFfiBindings)", "Kotlin/static work must depend only on generated UniFFI Kotlin")
    require(
        build,
        "dependsOn(buildAndroidUniFfi, materializeSingBoxAndroid)",
        "native producers must attach at the Android native merge boundary",
    )
    forbid(build, 'tasks.named("preBuild")', "global preBuild must not re-couple Kotlin/static work to Android native packaging")

    gradle_properties = read("android/gradle.properties")
    abi_matches = re.findall(r"^mishTargetAbi=(.+)$", gradle_properties, flags=re.MULTILINE)
    if abi_matches != ["armeabi-v7a"]:
        raise SystemExit(
            "delivery contract: android/gradle.properties must contain exactly one mishTargetAbi=armeabi-v7a"
        )

    toolchain_path = "lab/windows/toolchain.json"
    try:
        toolchain = json.loads(read(toolchain_path))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"delivery contract: invalid {toolchain_path}: {exc}") from exc
    if toolchain.get("android", {}).get("min_sdk") != 30:
        raise SystemExit("delivery contract: LAB Android min_sdk must mirror PRODUCT API 30")
    if toolchain.get("rust", {}).get("target") != "armv7-linux-androideabi":
        raise SystemExit("delivery contract: LAB Rust target must mirror armeabi-v7a as armv7-linux-androideabi")
    if toolchain.get("android", {}).get("ndk") != "29.0.14206865":
        raise SystemExit("delivery contract: LAB Android NDK pin drifted from the accepted build contract")
    android_packages = toolchain.get("android", {}).get("packages") or []
    if "build-tools;36.0.0" not in android_packages:
        raise SystemExit(
            "delivery contract: canonical LAB bootstrap must provision build-tools;36.0.0 before the physical consumer runs"
        )

    ci = ".github/workflows/ci.yml"
    for required in (
        "Classify required product gate",
        "full_product_gate",
        "No Rust product inputs changed",
        "No Android product inputs changed",
        "github.event_name != 'push'",
        "workflow_dispatch",
        "tools/check_*.py",
        ".github/workflows/device-cycle.yml",
    ):
        require(ci, required, "protected-main path-aware required-gate contract drifted")
    forbid(ci, "tools/*|", "PRODUCT-affecting tools must not be broadly exempted from the full product gate")
    forbid(ci, "tools/*.py|", "all Python tools must not be treated as diagnostic-only")

    producer = ".github/workflows/integration-android-preflight.yml"
    for required in (
        "branches: [fix/root-policy-reconciliation]",
        "cancel-in-progress: true",
        "Checkout exact PR head",
        "ref: ${{ github.event.pull_request.head.sha }}",
        "Fast Kotlin compile and lint",
        "Unit test and assemble host gate",
        "Verify packaged native runtime and UniFFI surface",
        "mish-device-candidate-v1",
        "device-candidate-pr-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}",
        "retention-days: 7",
        "Local build required: **NO**",
    ):
        require(producer, required, "hosted exact-head candidate producer contract drifted")

    installer = "lab/windows/install-device-candidate.ps1"
    for required in (
        "C:\\mish-lab\\runner\\.state\\device-candidate",
        "C:\\mish-lab\\runner\\_work\\.mish-device-candidate",
        "Invoke-NativeCapture",
        "SIGNING_IDENTITY_CONFLICT",
        "SIGNING_MIGRATION_FAILED",
        "SIGNING_IDENTITY_MISSING",
        "@('install', '-r', $signedProduct)",
        "signing_state_root = $state",
        "signed_product_apk_sha256",
        "lab_signing_certificate_sha256",
    ):
        require(installer, required, "DEVICE-1 installer simplification contract drifted")
    forbid(installer, "sdkmanager.bat", "physical consumer must not provision Android build-tools during an install")

    verifier = "lab/windows/verify-installed-candidate.ps1"
    for required in (
        "mish.device-install-verification/v1",
        "'shell', 'pm', 'path'",
        "@('pull', $basePaths[0], $pulledApk)",
        "Get-FileHash -Algorithm SHA256",
        "'verify', '--print-certs'",
        "INSTALLED_APK_DIGEST_MISMATCH",
        "INSTALLED_APK_CERT_MISMATCH",
        "exact_bytes_verified = $true",
    ):
        require(verifier, required, "post-install exact-byte verification contract drifted")

    consumer = ".github/workflows/device-cycle.yml"
    for required in (
        "issue_comment:",
        "github.actor == 'iamaman11'",
        "startsWith(github.event.comment.body, '/mish-cycle ')",
        "device-cycle requires an explicit exact 40-hex PRODUCT SHA",
        "installing a device candidate requires a ready PR",
        "no completed exact-head device candidate artifact exists; build first, then explicitly request the cycle",
        "candidate artifact did not originate from Integration Android Preflight",
        "candidate build is not a completed successful PR preflight",
        'ref: ${{ needs.resolve.outputs.control_sha }}',
        "C:\\mish-lab\\tools\\powershell-7.6.6\\pwsh.exe",
        "DEVICE_CYCLE_PWSH_VERSION: '7.6.6'",
        "Verify pinned PowerShell 7 runtime",
        "-Command \". ''{0}''\"",
        "DEVICE-1 API must be 30",
        "DEVICE-1 ABI must be armeabi-v7a",
        "merge-multiple: false",
        "needs.resolve.outputs.artifact_name",
        "DOWNLOAD_LAYOUT_MISMATCH",
        "Install exact signed candidate without rebuilding",
        "-CandidateDirectory $candidateDirectory",
        "Verify installed APK bytes and signing identity",
        "verify-installed-candidate.ps1",
        "mish-device-install-verification-v1.json",
        "Record in-run install identity",
        "Automatic start after build/main: **NO**",
    ):
        require(consumer, required, "single-run explicit DEVICE-1 consumer contract drifted")
    for forbidden in (
        "workflow_run:",
        "workflow_dispatch:",
        "Dispatch canonical physical installer",
        "device-candidate-physical.yml/dispatches",
        "shell: powershell",
        '-File "{0}"',
        '-CandidateDirectory "$env:RUNNER_TEMP\\mish-device-candidate"',
        "gradle --no-daemon",
        "cargo build",
        "cargo ndk",
        "uniffi-bindgen",
        "assembleDebug",
        "pm uninstall",
        "adb uninstall",
    ):
        forbid(consumer, forbidden, "normal DEVICE-1 consumer must be explicit, single-run, deterministic and truthful")

    if (ROOT / ".github/workflows/device-candidate-physical.yml").exists():
        raise SystemExit(
            "delivery contract: obsolete separate device-candidate-physical workflow must not exist; "
            "install/verify belongs to device-cycle.yml"
        )

    pipeline = "docs/architecture/DEVELOPMENT_PIPELINE.md"
    for required in (
        "Android 11 / API 30",
        "Android 23 and Android 26 are not supported PRODUCT compatibility floors",
        "The Windows LAB is a consumer, not a builder",
        "never silently substitute bytes from another commit",
        "adb install -r = Success` is necessary but not sufficient",
        "PRODUCT_SHA",
        "CONTROL_SHA",
        "No successful build, merge to main, label, or completed workflow starts DEVICE-1",
        "one GitHub Actions Device Cycle run",
        "It is not PRODUCT release identity and cannot be promoted",
    ):
        require(pipeline, required, "stable development delivery documentation drifted")

    print("DELIVERY_CONTRACT=PASS")


if __name__ == "__main__":
    main()
