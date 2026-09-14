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
    forbid_regex(
        build,
        r'"-P"\s*,\s*"(?:23|26)"',
        "API 23/26 native compatibility must not return",
    )
    require(build, "dependsOn(generateUniFfiBindings)", "Kotlin/static work must depend only on generated UniFFI Kotlin")
    require(
        build,
        "dependsOn(buildAndroidUniFfi, materializeSingBoxAndroid)",
        "native producers must attach at the Android native merge boundary",
    )
    forbid(
        build,
        'tasks.named("preBuild")',
        "global preBuild must not re-couple Kotlin/static work to Android native packaging",
    )

    gradle_properties = read("android/gradle.properties")
    abi_matches = re.findall(r"^mishTargetAbi=(.+)$", gradle_properties, flags=re.MULTILINE)
    if abi_matches != ["armeabi-v7a"]:
        raise SystemExit(
            "delivery contract: android/gradle.properties must contain exactly one "
            "mishTargetAbi=armeabi-v7a"
        )

    toolchain_path = "lab/windows/toolchain.json"
    try:
        toolchain = json.loads(read(toolchain_path))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"delivery contract: invalid {toolchain_path}: {exc}") from exc
    if toolchain.get("android", {}).get("min_sdk") != 30:
        raise SystemExit("delivery contract: LAB Android min_sdk must mirror PRODUCT API 30")
    if toolchain.get("rust", {}).get("target") != "armv7-linux-androideabi":
        raise SystemExit(
            "delivery contract: LAB Rust target must mirror armeabi-v7a as armv7-linux-androideabi"
        )
    if toolchain.get("android", {}).get("ndk") != "29.0.14206865":
        raise SystemExit("delivery contract: LAB Android NDK pin drifted from the accepted build contract")

    ci = ".github/workflows/ci.yml"
    for required in (
        "Classify required product gate",
        "full_product_gate",
        "No Rust product inputs changed",
        "No Android product inputs changed",
        "github.event_name != 'push'",
        "workflow_dispatch",
        "lab/*|docs/*|README.md|README.*",
    ):
        require(ci, required, "protected-main path-aware required-gate contract drifted")

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

    consumer = ".github/workflows/device-candidate-physical.yml"
    for required in (
        "github.ref == 'refs/heads/main'",
        "github.ref_protected == true",
        "device candidate PR must target fix/root-policy-reconciliation",
        "device candidate must originate from the canonical repository",
        "no non-expired exact-head device candidate artifact exists",
        "candidate artifact did not originate from Integration Android Preflight",
        "shell: powershell",
        "DEVICE-1 API must be 30",
        "DEVICE-1 ABI must be armeabi-v7a",
        "Verify, stable-sign, and install without rebuilding",
        "merge-multiple: false",
        "needs.resolve.outputs.artifact_name",
        "DOWNLOAD_LAYOUT_MISMATCH",
        "-CandidateDirectory $candidateDirectory",
        "Hosted build reused: **YES**",
        "Local Gradle/Rust/NDK build: **NO**",
        "Portable PowerShell prerequisite: **NO**",
    ):
        require(consumer, required, "protected physical candidate consumer contract drifted")
    for forbidden in (
        "pwsh.exe",
        '-CandidateDirectory "$env:RUNNER_TEMP\\mish-device-candidate"',
        "gradle --no-daemon",
        "cargo build",
        "cargo ndk",
        "uniffi-bindgen",
        "assembleDebug",
    ):
        forbid(consumer, forbidden, "normal DEVICE-1 consumer must not become a local Android builder")

    pipeline = "docs/architecture/DEVELOPMENT_PIPELINE.md"
    for required in (
        "Android 11 / API 30",
        "Android 23 and Android 26 are not supported PRODUCT compatibility floors",
        "The self-hosted Windows job is a consumer, not a builder",
        "A local build remains an explicit engineering fallback",
        "It is not PRODUCT release identity and cannot be promoted",
    ):
        require(pipeline, required, "stable development delivery documentation drifted")

    print("DELIVERY_CONTRACT=PASS")


if __name__ == "__main__":
    main()
