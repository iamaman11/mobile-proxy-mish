#!/usr/bin/env python3
"""Fail-closed checks for the native L8 build/CI/DEVICE-1 delivery contract."""

from __future__ import annotations

import json
import re
import subprocess
import sys
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


def require_device_cycle_contract() -> None:
    """Keep the workflow fail-closed even if pwsh masks an earlier native exit code."""
    result = subprocess.run(
        [sys.executable, str(ROOT / "tools/check_device_cycle_contract.py")],
        cwd=ROOT,
        check=False,
    )
    if result.returncode != 0:
        raise SystemExit(
            f"delivery contract: device cycle contract failed with exit code {result.returncode}"
        )


def main() -> None:
    # One native PRODUCT packaging path. No external proxy materializer may return.
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
    require(build, "dependsOn(generateUniFfiBindings)", "Kotlin/static work must depend on generated UniFFI Kotlin")
    require(build, "dependsOn(buildAndroidUniFfi)", "the Rust JNI producer must attach at the Android native merge boundary")
    forbid(build, "materializeSingBoxAndroid", "deleted sing-box materialization must not return")
    forbid(build, 'tasks.named("preBuild")', "global preBuild must not re-couple static work to native packaging")

    gradle_properties = read("android/gradle.properties")
    abi_matches = re.findall(r"^mishTargetAbi=(.+)$", gradle_properties, flags=re.MULTILINE)
    if abi_matches != ["armeabi-v7a"]:
        raise SystemExit("delivery contract: android/gradle.properties must contain exactly one mishTargetAbi=armeabi-v7a")

    toolchain_path = "lab/windows/toolchain.json"
    try:
        toolchain = json.loads(read(toolchain_path))
    except json.JSONDecodeError as exc:
        raise SystemExit(f"delivery contract: invalid {toolchain_path}: {exc}") from exc
    if toolchain.get("android", {}).get("min_sdk") != 30:
        raise SystemExit("delivery contract: LAB Android min_sdk must mirror PRODUCT API 30")
    if toolchain.get("rust", {}).get("target") != "armv7-linux-androideabi":
        raise SystemExit("delivery contract: LAB Rust target must mirror armeabi-v7a")
    if toolchain.get("android", {}).get("ndk") != "29.0.14206865":
        raise SystemExit("delivery contract: LAB Android NDK pin drifted from PRODUCT")
    if "build-tools;36.0.0" not in (toolchain.get("android", {}).get("packages") or []):
        raise SystemExit("delivery contract: canonical LAB bootstrap must provision build-tools;36.0.0")

    # Protected-main PR CI always runs cheap authority guards; heavy PRODUCT jobs run only for PRODUCT/build input changes.
    ci = ".github/workflows/ci.yml"
    for required in (
        "branches: [main]",
        "workflow_dispatch:",
        "Architecture + Delivery Guards",
        "python3 tools/check_architecture.py",
        "python3 tools/check_delivery_contract.py",
        "PRODUCT Change Classification",
        "product_changed=true",
        "android/*|crates/*|config/*|contracts/*|Cargo.toml|Cargo.lock|rust-toolchain.toml)",
        "needs: [architecture, changes]",
        "needs.changes.outputs.product_changed == 'true'",
        "Rust Workspace",
        "cargo fmt --all --check",
        "cargo clippy --workspace --all-targets --locked -- -D warnings",
        "cargo test --workspace --locked",
        "Android Compose Shell",
        "Verify packaged native runtime and narrow UniFFI surface",
        "libmish_android_ffi.so",
        "obsolete sing-box binary leaked into native PRODUCT APK",
    ):
        require(ci, required, "protected-main native CI contract drifted")
    forbid_regex(ci, r"^\s{2}push:\s*$", "accepted protected main must not automatically rebuild an already accepted PRODUCT")
    for obsolete in (
        "materialize_sing_box_android.py",
        "vendor/sing-box/release.toml",
        "Load pinned sing-box release manifest",
        "Exercise hosted sing-box proxy and auth matrix",
    ):
        forbid(ci, obsolete, "pre-L8 PRODUCT CI must not return")

    # One exact-head candidate producer for PRODUCT-changing PRs to main.
    producer = ".github/workflows/integration-android-preflight.yml"
    for required in (
        "branches: [main]",
        "cancel-in-progress: true",
        "Checkout exact PR head",
        "ref: ${{ github.event.pull_request.head.sha }}",
        "Classify docs-only preflight",
        "docs_only=true",
        "docs/architecture/*) ;;",
        "Architecture constitution",
        "steps.scope.outputs.docs_only != 'true'",
        "Fast Kotlin compile and lint",
        "Rust workspace quality gate",
        "cargo fmt --all --check",
        "cargo clippy --workspace --all-targets --locked -- -D warnings",
        "cargo test --workspace --locked",
        "Verify exact PRODUCT candidate contract",
        "python3 tools/verify_android_candidate.py",
        "mish-device-candidate-v1",
        "device-candidate-pr-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}",
        "retention-days: 7",
        "Local build required: **NO**",
        "      - name: Set up JDK 17\n        if: ${{ steps.scope.outputs.docs_only != 'true' }}",
        "      - name: Unit test and assemble host gate\n        if: ${{ steps.scope.outputs.docs_only != 'true' && github.event.pull_request.draft == false }}",
        "      - name: Stage exact-head device candidate\n        if: ${{ steps.scope.outputs.docs_only != 'true' && github.event.pull_request.draft == false }}",
        "      - name: Upload exact-head device candidate\n        if: ${{ steps.scope.outputs.docs_only != 'true' && github.event.pull_request.draft == false }}",
        "Docs-only preflight summary",
        "Device candidate staged: **NO**",
    ):
        require(producer, required, "hosted exact-head candidate producer contract drifted")
    forbid(producer, "fix/root-policy-reconciliation", "candidate producer must target protected main after convergence")
    forbid(producer, "sing-box", "native candidate producer must not know the deleted external proxy runtime")

    product_verifier = "tools/verify_android_candidate.py"
    for required in ("libmish_android_ffi.so", "libsingbox.so"):
        require(product_verifier, required, "candidate verifier must enforce the native-only APK contract")

    installer = "lab/windows/install-device-candidate.ps1"
    for required in (
        "C:\\mish-lab\\runner\\.state\\device-candidate",
        "Invoke-NativeCapture",
        "SIGNING_IDENTITY_CONFLICT",
        "Invoke-AdbInstallBounded",
        "$arguments = @('install', '-r')",
        "if ($TestOnly) { $arguments += '-t' }",
        "$arguments += $ApkPath",
        "[ValidateRange(10, 300)][int]$TimeoutSeconds = 90",
        "$process.Kill($true)",
        "INSTALL_TIMEOUT",
        "$installResult = Invoke-AdbInstallBounded -Adb $adb -ApkPath $signedProduct -TimeoutSeconds 90",
        "$testInstallResult = Invoke-AdbInstallBounded -Adb $adb -ApkPath $signedTest -TestOnly -TimeoutSeconds 90",
        "TEST_HARNESS_SIGNATURE_MIGRATION_REQUIRED",
        "test_harness_installed = $true",
        "signed_product_apk_sha256",
        "signed_android_test_apk_sha256",
        "lab_signing_certificate_sha256",
    ):
        require(installer, required, "DEVICE-1 installer contract drifted")
    forbid(installer, "sdkmanager.bat", "physical consumer must not provision build tools during install")

    verifier = "lab/windows/verify-installed-candidate.ps1"
    for required in (
        "mish.device-install-verification/v1",
        "'shell', 'pm', 'path'",
        "@('pull', $basePaths[0], $pulledApk)",
        "Get-FileHash -Algorithm SHA256",
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
        "candidate artifact did not originate from Integration Android Preflight",
        "candidate build is not a completed successful PR preflight",
        'ref: ${{ needs.resolve.outputs.control_sha }}',
        "Install exact signed candidate without rebuilding",
        "Verify installed APK bytes and signing identity",
        "Automatic start after build/main: **NO**",
    ):
        require(consumer, required, "explicit DEVICE-1 consumer contract drifted")
    for forbidden in (
        "workflow_run:",
        "workflow_dispatch:",
        "device-candidate-physical.yml/dispatches",
        "gradle --no-daemon",
        "cargo build",
        "cargo ndk",
        "uniffi-bindgen",
        "assembleDebug",
        "pm uninstall",
        "adb uninstall",
    ):
        forbid(consumer, forbidden, "DEVICE-1 consumer must remain explicit, non-building and non-destructive")

    if (ROOT / ".github/workflows/device-candidate-physical.yml").exists():
        raise SystemExit("delivery contract: obsolete separate device-candidate-physical workflow must not exist")

    pipeline = "docs/architecture/DEVELOPMENT_PIPELINE.md"
    for required in (
        "Android 11 / API 30",
        "Android 23 and Android 26 are not supported PRODUCT compatibility floors",
        "The Windows LAB is a consumer, not a builder",
        "never silently substitute bytes from another commit",
        "PRODUCT_SHA",
        "CONTROL_SHA",
        "No successful build, merge to main, label, or completed workflow starts DEVICE-1",
        "one GitHub Actions Device Cycle run",
        "They are not PRODUCT release identity and cannot be promoted",
    ):
        require(pipeline, required, "stable development delivery documentation drifted")

    require_device_cycle_contract()
    print("DELIVERY_CONTRACT=PASS")


if __name__ == "__main__":
    main()
