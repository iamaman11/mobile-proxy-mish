#!/usr/bin/env python3
"""Build/verify the bounded E3 instrumentation-harness identity manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

SCHEMA = "mish.lab.e3-harness/v1"
TAG_RE = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-rc\.([1-9]\d*)$")
HEX40_RE = re.compile(r"^[0-9a-f]{40}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
TEST_CLASS = "com.mobileproxymish.app.cellular.CellularE3InstrumentedTest"
TEST_COMPONENT = "com.mobileproxymish.app.test/androidx.test.runner.AndroidJUnitRunner"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_identity(tag: str, source_commit: str, cert_sha256: str) -> None:
    if not TAG_RE.fullmatch(tag):
        raise ValueError("RC tag must match vMAJOR.MINOR.PATCH-rc.N")
    if not HEX40_RE.fullmatch(source_commit):
        raise ValueError("source commit must be lowercase 40-hex")
    if not HEX64_RE.fullmatch(cert_sha256):
        raise ValueError("signing certificate must be lowercase 64-hex")


def build_manifest(
    *,
    tag: str,
    source_commit: str,
    product_apk: Path,
    test_apk: Path,
    product_cert_sha256: str,
    test_cert_sha256: str,
) -> dict:
    require_identity(tag, source_commit, product_cert_sha256)
    if test_cert_sha256 != product_cert_sha256:
        raise ValueError("product and E3 instrumentation APK certificates must match")
    if not product_apk.is_file() or not test_apk.is_file():
        raise ValueError("product and E3 instrumentation APKs must exist")
    return {
        "schema": SCHEMA,
        "repository": "iamaman11/mobile-proxy-mish",
        "rc_tag": tag,
        "source_commit": source_commit,
        "signing_certificate_sha256": product_cert_sha256,
        "product_apk": {
            "name": f"mobile-proxy-mish-{tag}.apk",
            "sha256": sha256(product_apk),
        },
        "test_apk": {
            "name": f"mobile-proxy-mish-{tag}-e3-androidTest.apk",
            "sha256": sha256(test_apk),
        },
        "instrumentation": {
            "class": TEST_CLASS,
            "component": TEST_COMPONENT,
        },
    }


def verify_manifest(
    manifest: dict,
    *,
    expected_tag: str,
    expected_source_commit: str,
    expected_signing_cert_sha256: str,
    product_apk: Path,
    test_apk: Path,
) -> None:
    require_identity(expected_tag, expected_source_commit, expected_signing_cert_sha256)
    if manifest.get("schema") != SCHEMA:
        raise ValueError("E3 harness schema mismatch")
    if manifest.get("repository") != "iamaman11/mobile-proxy-mish":
        raise ValueError("E3 harness repository mismatch")
    if manifest.get("rc_tag") != expected_tag:
        raise ValueError("E3 harness tag mismatch")
    if manifest.get("source_commit") != expected_source_commit:
        raise ValueError("E3 harness source mismatch")
    if manifest.get("signing_certificate_sha256") != expected_signing_cert_sha256:
        raise ValueError("E3 harness signing certificate mismatch")
    product = manifest.get("product_apk") or {}
    test = manifest.get("test_apk") or {}
    if product.get("name") != f"mobile-proxy-mish-{expected_tag}.apk":
        raise ValueError("E3 harness product name mismatch")
    if test.get("name") != f"mobile-proxy-mish-{expected_tag}-e3-androidTest.apk":
        raise ValueError("E3 harness test name mismatch")
    if product.get("sha256") != sha256(product_apk):
        raise ValueError("E3 harness product digest mismatch")
    if test.get("sha256") != sha256(test_apk):
        raise ValueError("E3 harness test digest mismatch")
    instrumentation = manifest.get("instrumentation") or {}
    if instrumentation.get("class") != TEST_CLASS or instrumentation.get("component") != TEST_COMPONENT:
        raise ValueError("E3 instrumentation identity mismatch")


def main() -> None:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    manifest = sub.add_parser("manifest")
    manifest.add_argument("--tag", required=True)
    manifest.add_argument("--source-commit", required=True)
    manifest.add_argument("--product-apk", type=Path, required=True)
    manifest.add_argument("--test-apk", type=Path, required=True)
    manifest.add_argument("--product-cert-sha256", required=True)
    manifest.add_argument("--test-cert-sha256", required=True)
    manifest.add_argument("--output", type=Path, required=True)

    verify = sub.add_parser("verify")
    verify.add_argument("--manifest", type=Path, required=True)
    verify.add_argument("--tag", required=True)
    verify.add_argument("--source-commit", required=True)
    verify.add_argument("--signing-cert-sha256", required=True)
    verify.add_argument("--product-apk", type=Path, required=True)
    verify.add_argument("--test-apk", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "manifest":
        payload = build_manifest(
            tag=args.tag,
            source_commit=args.source_commit,
            product_apk=args.product_apk,
            test_apk=args.test_apk,
            product_cert_sha256=args.product_cert_sha256.lower(),
            test_cert_sha256=args.test_cert_sha256.lower(),
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    else:
        payload = json.loads(args.manifest.read_text(encoding="utf-8"))
        verify_manifest(
            payload,
            expected_tag=args.tag,
            expected_source_commit=args.source_commit,
            expected_signing_cert_sha256=args.signing_cert_sha256.lower(),
            product_apk=args.product_apk,
            test_apk=args.test_apk,
        )


if __name__ == "__main__":
    main()
