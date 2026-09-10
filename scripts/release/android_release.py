#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tomllib
from pathlib import Path
from typing import Any

RC_TAG_RE = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-rc\.([1-9]\d*)$")
STABLE_TAG_RE = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$")
HEX40_RE = re.compile(r"^[0-9a-f]{40}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_ANDROID_VERSION_CODE = 2_100_000_000
RELEASE_SCHEMA = "mish.android-release/v1"


def derive(tag: str) -> dict[str, int | str]:
    match = RC_TAG_RE.fullmatch(tag)
    if not match:
        raise ValueError("release candidate tag must match vMAJOR.MINOR.PATCH-rc.N")
    major, minor, patch, rc = map(int, match.groups())
    if major > 20 or minor > 99 or patch > 99 or rc > 9_999:
        raise ValueError("tag components exceed Android versionCode encoding bounds")
    version_code = major * 100_000_000 + minor * 1_000_000 + patch * 10_000 + rc
    if not 1 <= version_code <= MAX_ANDROID_VERSION_CODE:
        raise ValueError("derived Android versionCode is outside the supported range")
    return {
        "tag": tag,
        "version_name": f"{major}.{minor}.{patch}",
        "version_code": version_code,
        "rc_number": rc,
    }


def derive_stable(tag: str) -> dict[str, str]:
    match = STABLE_TAG_RE.fullmatch(tag)
    if not match:
        raise ValueError("stable tag must match vMAJOR.MINOR.PATCH")
    major, minor, patch = map(int, match.groups())
    if major > 20 or minor > 99 or patch > 99:
        raise ValueError("stable tag components exceed supported bounds")
    return {"tag": tag, "version_name": f"{major}.{minor}.{patch}"}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_mapping(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"{name} must be a JSON object")
    return value


def require_text(mapping: dict[str, Any], key: str, name: str) -> str:
    value = mapping.get(key)
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name}.{key} must be a non-empty string")
    return value


def load_json_object(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"manifest is missing: {path}")
    return require_mapping(json.loads(path.read_text(encoding="utf-8")), "manifest")


def build_manifest(args: argparse.Namespace) -> dict[str, Any]:
    identity = derive(args.tag)
    apk_path = Path(args.apk)
    if not apk_path.is_file():
        raise ValueError(f"APK is missing: {apk_path}")
    if not HEX40_RE.fullmatch(args.source_commit):
        raise ValueError("source commit must be a lowercase 40-hex Git SHA")
    cert_digest = args.signing_cert_sha256.lower().replace(":", "")
    if not HEX64_RE.fullmatch(cert_digest):
        raise ValueError("signing certificate SHA-256 must be 64 hex characters")

    with Path(args.sing_box_manifest).open("rb") as handle:
        sing_box = tomllib.load(handle)
    android_vendor = sing_box["android_arm64"]

    return {
        "schema": RELEASE_SCHEMA,
        "channel": "rc",
        "product": {
            "version": identity["version_name"],
            "release_tag": identity["tag"],
            "rc_number": identity["rc_number"],
            "source_commit": args.source_commit,
            "android_version_code": identity["version_code"],
            "abi": "arm64-v8a",
            "build_mode": "release",
        },
        "artifact": {
            "name": apk_path.name,
            "sha256": sha256(apk_path),
            "signing_certificate_sha256": cert_digest,
        },
        "toolchain": {
            "jdk_major": args.jdk_major,
            "gradle": args.gradle,
            "android_build_tools": args.android_build_tools,
            "android_ndk": args.android_ndk,
            "rust": args.rust,
            "cargo_ndk": args.cargo_ndk,
        },
        "sing_box": {
            "version": sing_box["version"],
            "release_tag": sing_box["release_tag"],
            "android_arm64_asset": android_vendor["asset"],
            "android_arm64_sha256": android_vendor["sha256"],
        },
    }


def verify_manifest(
    manifest: dict[str, Any],
    *,
    tag: str,
    apk_path: Path,
    expected_source_commit: str | None = None,
) -> dict[str, str | int]:
    identity = derive(tag)
    if manifest.get("schema") != RELEASE_SCHEMA:
        raise ValueError(f"manifest schema must be {RELEASE_SCHEMA}")
    if manifest.get("channel") != "rc":
        raise ValueError("manifest channel must be rc")
    if not apk_path.is_file():
        raise ValueError(f"APK is missing: {apk_path}")

    product = require_mapping(manifest.get("product"), "manifest.product")
    artifact = require_mapping(manifest.get("artifact"), "manifest.artifact")
    toolchain = require_mapping(manifest.get("toolchain"), "manifest.toolchain")
    sing_box = require_mapping(manifest.get("sing_box"), "manifest.sing_box")

    expected_product: dict[str, Any] = {
        "version": identity["version_name"],
        "release_tag": tag,
        "rc_number": identity["rc_number"],
        "android_version_code": identity["version_code"],
        "abi": "arm64-v8a",
        "build_mode": "release",
    }
    for key, expected in expected_product.items():
        if product.get(key) != expected:
            raise ValueError(f"manifest.product.{key} does not match release identity")

    source_commit = require_text(product, "source_commit", "manifest.product")
    if not HEX40_RE.fullmatch(source_commit):
        raise ValueError("manifest.product.source_commit must be a lowercase 40-hex Git SHA")
    if expected_source_commit is not None:
        if not HEX40_RE.fullmatch(expected_source_commit):
            raise ValueError("expected source commit must be a lowercase 40-hex Git SHA")
        if source_commit != expected_source_commit:
            raise ValueError("manifest source commit does not match expected source commit")

    artifact_name = require_text(artifact, "name", "manifest.artifact")
    if artifact_name != apk_path.name:
        raise ValueError("manifest artifact name does not match downloaded APK name")
    artifact_digest = require_text(artifact, "sha256", "manifest.artifact")
    if not HEX64_RE.fullmatch(artifact_digest):
        raise ValueError("manifest artifact SHA-256 must be lowercase 64-hex")
    actual_digest = sha256(apk_path)
    if artifact_digest != actual_digest:
        raise ValueError("downloaded APK SHA-256 does not match manifest")
    signing_digest = require_text(artifact, "signing_certificate_sha256", "manifest.artifact")
    if not HEX64_RE.fullmatch(signing_digest):
        raise ValueError("manifest signing certificate SHA-256 must be lowercase 64-hex")

    jdk_major = toolchain.get("jdk_major")
    if not isinstance(jdk_major, int) or isinstance(jdk_major, bool) or jdk_major <= 0:
        raise ValueError("manifest.toolchain.jdk_major must be a positive integer")
    for key in ("gradle", "android_build_tools", "android_ndk", "rust", "cargo_ndk"):
        require_text(toolchain, key, "manifest.toolchain")

    for key in ("version", "release_tag", "android_arm64_asset"):
        require_text(sing_box, key, "manifest.sing_box")
    sing_box_digest = require_text(sing_box, "android_arm64_sha256", "manifest.sing_box")
    if not HEX64_RE.fullmatch(sing_box_digest):
        raise ValueError("manifest sing-box SHA-256 must be lowercase 64-hex")

    return {
        "schema": RELEASE_SCHEMA,
        "tag": tag,
        "version_name": str(identity["version_name"]),
        "version_code": int(identity["version_code"]),
        "source_commit": source_commit,
        "artifact_name": artifact_name,
        "artifact_sha256": artifact_digest,
        "signing_certificate_sha256": signing_digest,
    }


def validate_promotion(rc_tag: str, stable_tag: str, manifest: dict[str, Any]) -> dict[str, str]:
    rc_identity = derive(rc_tag)
    stable_identity = derive_stable(stable_tag)
    if rc_identity["version_name"] != stable_identity["version_name"]:
        raise ValueError("stable tag must promote the same base version as the RC")
    product = require_mapping(manifest.get("product"), "manifest.product")
    artifact = require_mapping(manifest.get("artifact"), "manifest.artifact")
    if manifest.get("schema") != RELEASE_SCHEMA or manifest.get("channel") != "rc":
        raise ValueError("only a valid RC release manifest can be promoted")
    if product.get("release_tag") != rc_tag or product.get("version") != rc_identity["version_name"]:
        raise ValueError("RC manifest identity does not match promotion source tag")
    digest = require_text(artifact, "sha256", "manifest.artifact")
    if not HEX64_RE.fullmatch(digest):
        raise ValueError("RC artifact SHA-256 must be lowercase 64-hex")
    return {
        "rc_tag": rc_tag,
        "stable_tag": stable_tag,
        "artifact_sha256": digest,
        "rule": "PROMOTE_EXACT_BYTES_NO_REBUILD",
    }


def write_github_output(path: Path, values: dict[str, int | str]) -> None:
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        for key in ("tag", "version_name", "version_code", "rc_number"):
            handle.write(f"{key}={values[key]}\n")


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    derive_parser = sub.add_parser("derive")
    derive_parser.add_argument("--tag", required=True)
    derive_parser.add_argument("--github-output")

    manifest_parser = sub.add_parser("manifest")
    manifest_parser.add_argument("--tag", required=True)
    manifest_parser.add_argument("--source-commit", required=True)
    manifest_parser.add_argument("--apk", required=True)
    manifest_parser.add_argument("--signing-cert-sha256", required=True)
    manifest_parser.add_argument("--sing-box-manifest", default="vendor/sing-box/release.toml")
    manifest_parser.add_argument("--jdk-major", type=int, required=True)
    manifest_parser.add_argument("--gradle", required=True)
    manifest_parser.add_argument("--android-build-tools", required=True)
    manifest_parser.add_argument("--android-ndk", required=True)
    manifest_parser.add_argument("--rust", required=True)
    manifest_parser.add_argument("--cargo-ndk", required=True)
    manifest_parser.add_argument("--output", required=True)

    verify_parser = sub.add_parser("verify")
    verify_parser.add_argument("--tag", required=True)
    verify_parser.add_argument("--manifest", required=True)
    verify_parser.add_argument("--apk", required=True)
    verify_parser.add_argument("--expected-source-commit")

    promotion_parser = sub.add_parser("promotion-check")
    promotion_parser.add_argument("--rc-tag", required=True)
    promotion_parser.add_argument("--stable-tag", required=True)
    promotion_parser.add_argument("--manifest", required=True)

    args = parser.parse_args()
    try:
        if args.command == "derive":
            values = derive(args.tag)
            if args.github_output:
                write_github_output(Path(args.github_output), values)
            else:
                print(json.dumps(values, sort_keys=True))
        elif args.command == "manifest":
            manifest = build_manifest(args)
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        elif args.command == "verify":
            result = verify_manifest(
                load_json_object(Path(args.manifest)),
                tag=args.tag,
                apk_path=Path(args.apk),
                expected_source_commit=args.expected_source_commit,
            )
            print(json.dumps(result, sort_keys=True))
        else:
            result = validate_promotion(
                args.rc_tag,
                args.stable_tag,
                load_json_object(Path(args.manifest)),
            )
            print(json.dumps(result, sort_keys=True))
    except (json.JSONDecodeError, KeyError, OSError, TypeError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f"android-release: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
