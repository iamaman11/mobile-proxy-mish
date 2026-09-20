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

    # One protected-main PR validation pipeline owns both required checks and the exact-head candidate.
    # The obsolete split CI workflow is forbidden because it duplicated Rust/Android work and obscured
    # which hosted run produced the immutable candidate consumed by Device Cycle.
    obsolete_ci = ROOT / ".github/workflows/ci.yml"
    if obsolete_ci.exists():
        raise SystemExit("delivery contract: obsolete duplicate ci.yml workflow must not exist")

    producer = ".github/workflows/integration-android-preflight.yml"
    for required in (
        "name: PR Validation + PRODUCT Candidate",
        "branches: [main]",
        "cancel-in-progress: true",
        "Control Guards",
        "Checkout exact PR head and history",
        "ref: ${{ github.event.pull_request.head.sha }}",
        "Classify PRODUCT/build scope",
        "product_changed=false",
        "android/*|crates/*|config/*|contracts/*|Cargo.toml|Cargo.lock|rust-toolchain.toml|tools/verify_android_candidate.py)",
        "Verify accepted architecture invariants",
        "python3 tools/check_architecture.py",
        "Verify delivery and CI invariants",
        "python3 tools/check_delivery_contract.py",
        "Verify capacity probe held-session contract",
        "Verify diagnostic protocol probe helpers",
        "Verify physical protocol parity contract",
        "name: Device Cycle Contracts",
        "runs-on: windows-latest",
        "Verify Device Cycle orchestration contracts",
        "name: Rust Workspace",
        "needs: [control, device-contracts]",
        "Require control guards",
        "cargo fmt --all --check",
        "cargo clippy --workspace --all-targets --locked -- -D warnings",
        "cargo test --workspace --locked",
        "name: Android Build/Test",
        "needs: [control, device-contracts]",
        "Require control gates",
        "Fast Kotlin compile and lint",
        "Unit test and assemble exact-head candidate",
        "Verify exact PRODUCT candidate contract",
        "python3 tools/verify_android_candidate.py",
        "mish-device-candidate-v1",
        "device-candidate-staging-pr-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}-${{ github.run_id }}",
        "retention-days: 1",
        "name: Android Compose Shell",
        "needs: [control, device-contracts, rust, android-build]",
        "Require complete PRODUCT gates",
        "actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c",
        "Re-verify staged candidate identity",
        "Publish canonical exact-head device candidate",
        "device-candidate-pr-${{ github.event.pull_request.number }}-${{ github.event.pull_request.head.sha }}",
        "retention-days: 7",
        "Local build required: **NO**",
        "Physical Device Cycle auto-start: **NO**",
        "Device candidate staged: **NO**",
    ):
        require(producer, required, "single PR validation / exact-head candidate pipeline drifted")
    forbid(producer, "    paths:", "required PR checks must exist for every protected-main pull request")
    forbid_regex(producer, r"^\s{2}push:\s*$", "accepted protected main must not automatically rebuild an already accepted PRODUCT")
    forbid(producer, "fix/root-policy-reconciliation", "candidate producer must target protected main after convergence")
    forbid(producer, "sing-box", "native candidate producer must not know the deleted external proxy runtime")
    forbid(producer, "Generate and verify native UniFFI contract", "UniFFI surface verification must have one authority in verify_android_candidate.py")
    forbid(producer, "cargo build -p mish-android-ffi --locked", "Rust required-check must not duplicate the Android candidate native build")
    require_regex(
        producer,
        r"(?s)android-build:\n.*?name: Android Build/Test\n\s+needs: \[control, device-contracts\]",
        "Android Build/Test must run in parallel with Rust after shared lightweight gates",
    )
    require_regex(
        producer,
        r"(?s)android:\n.*?name: Android Compose Shell\n\s+needs: \[control, device-contracts, rust, android-build\]",
        "required Android Compose Shell context must be the final Rust+Android aggregate candidate gate",
    )
    forbid_regex(
        producer,
        r"(?s)android-build:\n.*?needs: \[[^\]]*rust",
        "heavy Android build/test must not wait for Rust Workspace",
    )

    product_verifier = "tools/verify_android_candidate.py"
    for required in ("libmish_android_ffi.so", "libsingbox.so"):
        require(product_verifier, required, "candidate verifier must enforce the native-only APK contract")

    materializer = "lab/windows/materialize-device-candidate.ps1"
    for required in (
        "C:\\mish-lab\\runner\\.state\\device-candidate\\versions",
        "mish.device-candidate-local/v1",
        "artifact_id",
        "artifact_digest",
        "hosted_product_apk_sha256",
        "version_root",
        "hosted_directory",
        "signed_directory",
        "receipts_directory",
    ):
        require(materializer, required, "canonical Windows candidate-store contract drifted")

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
        "mish.device-candidate-install/v2",
        "hosted_product_apk_sha256",
        "hosted_android_test_apk_sha256",
        "lab_signed_product_apk_sha256",
        "lab_signed_android_test_apk_sha256",
        "lab_signing_certificate_sha256",
    ):
        require(installer, required, "DEVICE-1 installer contract drifted")
    forbid(installer, "sdkmanager.bat", "physical consumer must not provision build tools during install")

    verifier = "lab/windows/verify-installed-candidate.ps1"
    for required in (
        "mish.device-install-verification/v2",
        "'shell', 'pm', 'path'",
        "@('pull', $basePaths[0], $pulledApk)",
        "Get-FileHash -Algorithm SHA256",
        "INSTALLED_APK_DIGEST_MISMATCH",
        "INSTALLED_APK_CERT_MISMATCH",
        "hosted_to_lab_signed_lineage_verified = $true",
        "installed_matches_lab_signed_candidate = $true",
        "exact_installed_bytes_verified = $true",
    ):
        require(verifier, required, "post-install exact-byte verification contract drifted")

    consumer = ".github/workflows/device-cycle.yml"
    for required in (
        "workflow_dispatch:",
        "pr_number:",
        "product_sha:",
        "PR_NUMBER: ${{ inputs.pr_number }}",
        "EXPECTED_SHA: ${{ inputs.product_sha }}",
        "MODE: ${{ inputs.mode }}",
        "PROBE: ${{ inputs.probe }}",
        "device cycle control must be dispatched from current protected main",
        "device-cycle requires an explicit exact 40-hex PRODUCT SHA",
        "installing a device candidate requires a ready PR",
        "candidate artifact did not originate from PR Validation + PRODUCT Candidate",
        "candidate build is not a completed successful PR preflight",
        'ref: ${{ needs.resolve.outputs.control_sha }}',
        "Materialize exact hosted candidate in canonical Windows store",
        "DEVICE_CANDIDATE_STORE_ROOT: C:\\\\mish-lab\\\\runner\\\\.state\\\\device-candidate\\\\versions",
        "Install exact signed candidate without rebuilding",
        "Verify installed APK bytes and signing identity",
        "manual workflow_dispatch from protected main",
        "Automatic start after build/main: **NO**",
    ):
        require(consumer, required, "explicit manual DEVICE-1 consumer contract drifted")
    for forbidden in (
        "pull_request:",
        "issue_comment:",
        "workflow_run:",
        "device-candidate-physical.yml/dispatches",
        "gradle --no-daemon",
        "cargo build",
        "cargo ndk",
        "uniffi-bindgen",
        "assembleDebug",
        "pm uninstall",
        "adb uninstall",
    ):
        forbid(consumer, forbidden, "DEVICE-1 consumer must remain manual-only, non-building and non-destructive")

    if (ROOT / ".github/workflows/device-candidate-physical.yml").exists():
        raise SystemExit("delivery contract: obsolete separate device-candidate-physical workflow must not exist")

    for obsolete in (
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
        if (ROOT / obsolete).exists():
            raise SystemExit(
                "delivery contract: obsolete RC/release-lineage path must stay deleted: " + obsolete
            )

    pipeline = "docs/architecture/DEVELOPMENT_PIPELINE.md"
    for required in (
        "Android 11 / API 30",
        "Android 23 and Android 26 are not supported PRODUCT compatibility floors",
        "The Windows LAB is a consumer, not a builder",
        "C:\\mish-lab\\runner\\.state\\device-candidate\\versions",
        "hosted source candidate",
        "LAB-signed install candidate",
        "installed base.apk",
        "never silently substitute bytes from another commit",
        "PRODUCT_SHA",
        "CONTROL_SHA",
        "No successful build, merge to main, label, or completed workflow starts DEVICE-1",
        "one GitHub Actions Device Cycle run",
        "Development device candidates are the canonical Android physical-acceptance bytes for their exact source head",
        "They are never promoted through an RC lineage",
    ):
        require(pipeline, required, "stable development delivery documentation drifted")

    require_device_cycle_contract()
    print("DELIVERY_CONTRACT=PASS")


if __name__ == "__main__":
    main()
