#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("android_release.py")
SPEC = importlib.util.spec_from_file_location("android_release", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class VersionContractTests(unittest.TestCase):
    def test_rc_tag_maps_to_base_version_and_monotonic_code(self):
        value = MODULE.derive("v0.2.3-rc.7")
        self.assertEqual(value["version_name"], "0.2.3")
        self.assertEqual(value["version_code"], 2_030_007)
        self.assertEqual(value["rc_number"], 7)

    def test_later_rc_is_greater_without_changing_version_name(self):
        first = MODULE.derive("v1.4.0-rc.1")
        second = MODULE.derive("v1.4.0-rc.2")
        self.assertEqual(first["version_name"], second["version_name"])
        self.assertLess(first["version_code"], second["version_code"])

    def test_next_patch_is_greater_than_previous_rc(self):
        old = MODULE.derive("v1.4.0-rc.9999")
        new = MODULE.derive("v1.4.1-rc.1")
        self.assertLess(old["version_code"], new["version_code"])

    def test_stable_tag_is_not_a_build_input(self):
        with self.assertRaises(ValueError):
            MODULE.derive("v1.4.0")

    def test_invalid_or_overflowing_tags_fail_closed(self):
        for tag in (
            "1.2.3-rc.1",
            "v1.2-rc.1",
            "v1.2.3-rc.0",
            "v1.100.0-rc.1",
            "v21.0.0-rc.1",
            "v1.2.3-rc.10000",
        ):
            with self.subTest(tag=tag):
                with self.assertRaises(ValueError):
                    MODULE.derive(tag)


class ReleaseVerificationTests(unittest.TestCase):
    def setUp(self):
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.apk = self.root / "mobile-proxy-mish-v0.1.0-rc.1.apk"
        self.apk.write_bytes(b"exact signed apk bytes")
        self.source_commit = "a" * 40
        self.cert_digest = "b" * 64
        self.manifest = {
            "schema": MODULE.RELEASE_SCHEMA,
            "channel": "rc",
            "product": {
                "version": "0.1.0",
                "release_tag": "v0.1.0-rc.1",
                "rc_number": 1,
                "source_commit": self.source_commit,
                "android_version_code": 1_000_001,
                "abi": "arm64-v8a",
                "build_mode": "release",
            },
            "artifact": {
                "name": self.apk.name,
                "sha256": MODULE.sha256(self.apk),
                "signing_certificate_sha256": self.cert_digest,
            },
            "toolchain": {
                "jdk_major": 17,
                "gradle": "9.6.0",
                "android_build_tools": "36.0.0",
                "android_ndk": "29.0.14206865",
                "rust": "1.98.1",
                "cargo_ndk": "4.1.2",
            },
            "sing_box": {
                "version": "1.14.0",
                "release_tag": "v1.14.0",
                "android_arm64_asset": "sing-box-1.14.0-android-arm64.tar.gz",
                "android_arm64_sha256": "c" * 64,
            },
        }

    def tearDown(self):
        self.tempdir.cleanup()

    def test_exact_downloaded_bytes_verify(self):
        result = MODULE.verify_manifest(
            self.manifest,
            tag="v0.1.0-rc.1",
            apk_path=self.apk,
            expected_source_commit=self.source_commit,
        )
        self.assertEqual(result["artifact_sha256"], MODULE.sha256(self.apk))
        self.assertEqual(result["source_commit"], self.source_commit)

    def test_digest_mismatch_fails_closed(self):
        self.manifest["artifact"]["sha256"] = "d" * 64
        with self.assertRaisesRegex(ValueError, "does not match manifest"):
            MODULE.verify_manifest(self.manifest, tag="v0.1.0-rc.1", apk_path=self.apk)

    def test_tag_mismatch_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "release identity"):
            MODULE.verify_manifest(self.manifest, tag="v0.1.0-rc.2", apk_path=self.apk)

    def test_source_mismatch_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "expected source commit"):
            MODULE.verify_manifest(
                self.manifest,
                tag="v0.1.0-rc.1",
                apk_path=self.apk,
                expected_source_commit="e" * 40,
            )

    def test_artifact_filename_mismatch_fails_closed(self):
        renamed = self.root / "other.apk"
        renamed.write_bytes(self.apk.read_bytes())
        with self.assertRaisesRegex(ValueError, "artifact name"):
            MODULE.verify_manifest(self.manifest, tag="v0.1.0-rc.1", apk_path=renamed)

    def test_malformed_signing_identity_fails_closed(self):
        self.manifest["artifact"]["signing_certificate_sha256"] = "not-a-digest"
        with self.assertRaisesRegex(ValueError, "signing certificate"):
            MODULE.verify_manifest(self.manifest, tag="v0.1.0-rc.1", apk_path=self.apk)

    def test_manifest_loader_rejects_non_object_json(self):
        manifest_path = self.root / "release.json"
        manifest_path.write_text(json.dumps(["not", "an", "object"]), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "JSON object"):
            MODULE.load_json_object(manifest_path)


class PromotionContractTests(unittest.TestCase):
    def manifest(self, tag="v0.1.0-rc.1", version="0.1.0", digest=None):
        return {
            "schema": MODULE.RELEASE_SCHEMA,
            "channel": "rc",
            "product": {"release_tag": tag, "version": version},
            "artifact": {"sha256": digest or "f" * 64},
        }

    def test_stable_promotion_keeps_exact_rc_digest(self):
        result = MODULE.validate_promotion(
            "v0.1.0-rc.1",
            "v0.1.0",
            self.manifest(),
        )
        self.assertEqual(result["artifact_sha256"], "f" * 64)
        self.assertEqual(result["rule"], "PROMOTE_EXACT_BYTES_NO_REBUILD")

    def test_cross_version_promotion_is_forbidden(self):
        with self.assertRaisesRegex(ValueError, "same base version"):
            MODULE.validate_promotion(
                "v0.1.0-rc.1",
                "v0.2.0",
                self.manifest(),
            )

    def test_stable_tag_must_not_be_an_rc_tag(self):
        with self.assertRaises(ValueError):
            MODULE.validate_promotion(
                "v0.1.0-rc.1",
                "v0.1.0-rc.2",
                self.manifest(),
            )

    def test_promotion_rejects_manifest_for_different_rc(self):
        with self.assertRaisesRegex(ValueError, "promotion source tag"):
            MODULE.validate_promotion(
                "v0.1.0-rc.1",
                "v0.1.0",
                self.manifest(tag="v0.1.0-rc.2"),
            )


if __name__ == "__main__":
    unittest.main()
