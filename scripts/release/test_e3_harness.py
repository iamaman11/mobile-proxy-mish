#!/usr/bin/env python3

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import e3_harness


class E3HarnessContractTests(unittest.TestCase):
    TAG = "v0.1.0-rc.2"
    SOURCE = "a" * 40
    CERT = "b" * 64

    def fixture(self):
        temp = tempfile.TemporaryDirectory()
        root = Path(temp.name)
        product = root / "product.apk"
        test = root / "test.apk"
        product.write_bytes(b"product-bytes")
        test.write_bytes(b"test-bytes")
        return temp, product, test

    def test_manifest_round_trip(self):
        temp, product, test = self.fixture()
        with temp:
            manifest = e3_harness.build_manifest(
                tag=self.TAG,
                source_commit=self.SOURCE,
                product_apk=product,
                test_apk=test,
                product_cert_sha256=self.CERT,
                test_cert_sha256=self.CERT,
            )
            e3_harness.verify_manifest(
                manifest,
                expected_tag=self.TAG,
                expected_source_commit=self.SOURCE,
                expected_signing_cert_sha256=self.CERT,
                product_apk=product,
                test_apk=test,
            )

    def test_certificate_mismatch_fails_closed(self):
        temp, product, test = self.fixture()
        with temp:
            with self.assertRaisesRegex(ValueError, "certificates must match"):
                e3_harness.build_manifest(
                    tag=self.TAG,
                    source_commit=self.SOURCE,
                    product_apk=product,
                    test_apk=test,
                    product_cert_sha256=self.CERT,
                    test_cert_sha256="c" * 64,
                )

    def test_test_apk_mutation_fails_closed(self):
        temp, product, test = self.fixture()
        with temp:
            manifest = e3_harness.build_manifest(
                tag=self.TAG,
                source_commit=self.SOURCE,
                product_apk=product,
                test_apk=test,
                product_cert_sha256=self.CERT,
                test_cert_sha256=self.CERT,
            )
            test.write_bytes(b"mutated")
            with self.assertRaisesRegex(ValueError, "test digest mismatch"):
                e3_harness.verify_manifest(
                    manifest,
                    expected_tag=self.TAG,
                    expected_source_commit=self.SOURCE,
                    expected_signing_cert_sha256=self.CERT,
                    product_apk=product,
                    test_apk=test,
                )

    def test_identity_mutation_fails_closed(self):
        temp, product, test = self.fixture()
        with temp:
            manifest = e3_harness.build_manifest(
                tag=self.TAG,
                source_commit=self.SOURCE,
                product_apk=product,
                test_apk=test,
                product_cert_sha256=self.CERT,
                test_cert_sha256=self.CERT,
            )
            manifest = json.loads(json.dumps(manifest))
            manifest["source_commit"] = "d" * 40
            with self.assertRaisesRegex(ValueError, "source mismatch"):
                e3_harness.verify_manifest(
                    manifest,
                    expected_tag=self.TAG,
                    expected_source_commit=self.SOURCE,
                    expected_signing_cert_sha256=self.CERT,
                    product_apk=product,
                    test_apk=test,
                )


if __name__ == "__main__":
    unittest.main()
