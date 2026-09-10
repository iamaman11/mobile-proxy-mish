#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import tomllib
from pathlib import Path

RC_TAG_RE = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-rc\.([1-9]\d*)$")
MAX_ANDROID_VERSION_CODE = 2_100_000_000


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


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(args: argparse.Namespace) -> dict:
    identity = derive(args.tag)
    apk_path = Path(args.apk)
    if not apk_path.is_file():
        raise ValueError(f"APK is missing: {apk_path}")
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
        raise ValueError("source commit must be a lowercase 40-hex Git SHA")
    cert_digest = args.signing_cert_sha256.lower().replace(":", "")
    if not re.fullmatch(r"[0-9a-f]{64}", cert_digest):
        raise ValueError("signing certificate SHA-256 must be 64 hex characters")

    with Path(args.sing_box_manifest).open("rb") as handle:
        sing_box = tomllib.load(handle)
    android_vendor = sing_box["android_arm64"]

    return {
        "schema": "mish.android-release/v1",
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

    args = parser.parse_args()
    try:
        if args.command == "derive":
            values = derive(args.tag)
            if args.github_output:
                write_github_output(Path(args.github_output), values)
            else:
                print(json.dumps(values, sort_keys=True))
        else:
            manifest = build_manifest(args)
            output = Path(args.output)
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    except (KeyError, OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f"android-release: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
