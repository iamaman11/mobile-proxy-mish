#!/usr/bin/env python3
import importlib.util
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


if __name__ == "__main__":
    unittest.main()
