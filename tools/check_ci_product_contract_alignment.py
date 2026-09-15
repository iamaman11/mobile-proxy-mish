#!/usr/bin/env python3
"""Fail closed if protected-main CI and integration preflight drift on shared PRODUCT facts."""

from __future__ import annotations

import json
import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI_PATH = ".github/workflows/ci.yml"
PREFLIGHT_PATH = ".github/workflows/integration-android-preflight.yml"
RUST_TOOLCHAIN_PATH = "rust-toolchain.toml"
LAB_TOOLCHAIN_PATH = "lab/windows/toolchain.json"


def read(path: str) -> str:
    target = ROOT / path
    if not target.is_file():
        raise SystemExit(f"ci product alignment: required file missing: {path}")
    return target.read_text(encoding="utf-8")


def require(path: str, text: str, needle: str, reason: str) -> None:
    if needle not in text:
        raise SystemExit(f"ci product alignment: {reason}: {path} lacks {needle!r}")


def extract_single(path: str, text: str, pattern: str, label: str) -> str:
    matches = re.findall(pattern, text, flags=re.MULTILINE)
    if len(matches) != 1:
        raise SystemExit(
            f"ci product alignment: {path} must expose exactly one {label}; observed {len(matches)}"
        )
    return matches[0]


def main() -> None:
    ci = read(CI_PATH)
    preflight = read(PREFLIGHT_PATH)

    rust_contract = tomllib.loads(read(RUST_TOOLCHAIN_PATH)).get("toolchain", {})
    rust_version = str(rust_contract.get("channel") or "")
    rust_components = set(rust_contract.get("components") or [])
    if not re.fullmatch(r"\d+\.\d+\.\d+", rust_version):
        raise SystemExit("ci product alignment: rust-toolchain.toml must own one stable Rust version")
    if not {"clippy", "rustfmt"}.issubset(rust_components):
        raise SystemExit("ci product alignment: rust-toolchain.toml must retain clippy and rustfmt")

    toolchain = json.loads(read(LAB_TOOLCHAIN_PATH))
    mirrored_rust = str(toolchain.get("rust", {}).get("toolchain") or "")
    java_version = str(toolchain.get("java", {}).get("major") or "")
    gradle_version = str(toolchain.get("gradle", {}).get("version") or "")
    cargo_ndk_version = str(toolchain.get("rust", {}).get("cargo_ndk") or "")
    ndk_version = str(toolchain.get("android", {}).get("ndk") or "")

    if mirrored_rust != rust_version:
        raise SystemExit(
            "ci product alignment: LAB Rust mirror drifted from rust-toolchain.toml "
            f"({mirrored_rust!r} != {rust_version!r})"
        )
    for label, value in (
        ("Java", java_version),
        ("Gradle", gradle_version),
        ("cargo-ndk", cargo_ndk_version),
        ("Android NDK", ndk_version),
    ):
        if not value:
            raise SystemExit(f"ci product alignment: LAB toolchain lacks {label} authority")

    preflight_values = {
        "Rust": extract_single(
            PREFLIGHT_PATH,
            preflight,
            r"^\s*RUST_TOOLCHAIN:\s*'([^']+)'\s*$",
            "RUST_TOOLCHAIN",
        ),
        "Gradle": extract_single(
            PREFLIGHT_PATH,
            preflight,
            r"^\s*GRADLE_VERSION:\s*'([^']+)'\s*$",
            "GRADLE_VERSION",
        ),
        "cargo-ndk": extract_single(
            PREFLIGHT_PATH,
            preflight,
            r"^\s*CARGO_NDK_VERSION:\s*'([^']+)'\s*$",
            "CARGO_NDK_VERSION",
        ),
        "Android NDK": extract_single(
            PREFLIGHT_PATH,
            preflight,
            r"^\s*ANDROID_NDK_VERSION:\s*'([^']+)'\s*$",
            "ANDROID_NDK_VERSION",
        ),
    }
    expected = {
        "Rust": rust_version,
        "Gradle": gradle_version,
        "cargo-ndk": cargo_ndk_version,
        "Android NDK": ndk_version,
    }
    for label, value in expected.items():
        if preflight_values[label] != value:
            raise SystemExit(
                f"ci product alignment: integration preflight {label} drifted from authority "
                f"({preflight_values[label]!r} != {value!r})"
            )

    for needle, reason in (
        (f"java-version: '{java_version}'", "Java pin drifted from LAB toolchain"),
        (f"gradle-version: '{gradle_version}'", "Gradle pin drifted from LAB toolchain"),
        (
            f"rustup toolchain install {rust_version} --profile minimal --component clippy,rustfmt",
            "Rust quality toolchain drifted from rust-toolchain.toml",
        ),
        (f"rustup override set {rust_version}", "Rust override drifted from rust-toolchain.toml"),
        (
            f"cargo install cargo-ndk --version {cargo_ndk_version} --locked",
            "cargo-ndk pin drifted from LAB toolchain",
        ),
        (f'NDK_PATH="$SDK_ROOT/ndk/{ndk_version}"', "Android NDK pin drifted from LAB toolchain"),
        (f'"$SDKMANAGER" "ndk;{ndk_version}"', "Android NDK package drifted from LAB toolchain"),
    ):
        require(CI_PATH, ci, needle, reason)

    for needle, reason in (
        (f"java-version: '{java_version}'", "Java pin drifted from LAB toolchain"),
        ("gradle-version: ${{ env.GRADLE_VERSION }}", "preflight must consume GRADLE_VERSION"),
        (
            'rustup toolchain install "$RUST_TOOLCHAIN" --profile minimal --component clippy,rustfmt',
            "preflight must consume RUST_TOOLCHAIN for quality tooling",
        ),
        ('rustup override set "$RUST_TOOLCHAIN"', "preflight must consume RUST_TOOLCHAIN override"),
        (
            'cargo install cargo-ndk --version "$CARGO_NDK_VERSION" --locked',
            "preflight must consume CARGO_NDK_VERSION",
        ),
        ('NDK_PATH="$SDK_ROOT/ndk/$ANDROID_NDK_VERSION"', "preflight must consume ANDROID_NDK_VERSION"),
        ('"$SDKMANAGER" "ndk;$ANDROID_NDK_VERSION"', "preflight must consume Android NDK package pin"),
    ):
        require(PREFLIGHT_PATH, preflight, needle, reason)

    shared_commands = (
        "cargo fmt --all --check",
        "cargo clippy --workspace --all-targets --locked -- -D warnings",
        "cargo test --workspace --locked",
        ":app:lintDebug",
        ":app:testDebugUnitTest",
        ":app:assembleDebug",
        ":app:assembleDebugAndroidTest",
    )
    for command in shared_commands:
        require(CI_PATH, ci, command, "protected-main shared PRODUCT gate drifted")
        require(PREFLIGHT_PATH, preflight, command, "integration shared PRODUCT gate drifted")

    abi_probe = 'TARGET_ABI="$(sed -n \'s/^mishTargetAbi=//p\' android/gradle.properties)"'
    require(CI_PATH, ci, abi_probe, "protected-main Android ABI must come from mishTargetAbi")
    require(PREFLIGHT_PATH, preflight, abi_probe, "integration Android ABI must come from mishTargetAbi")

    print("CI_PRODUCT_CONTRACT_ALIGNMENT=PASS")


if __name__ == "__main__":
    main()
