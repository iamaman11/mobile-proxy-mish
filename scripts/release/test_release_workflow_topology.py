#!/usr/bin/env python3
from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "android-release.yml"


def section(text: str, start: str, end: str | None = None) -> str:
    start_index = text.index(start)
    if end is None:
        return text[start_index:]
    end_index = text.index(end, start_index + len(start))
    return text[start_index:end_index]


class ReleaseWorkflowTopologyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.workflow = WORKFLOW.read_text(encoding="utf-8")

    def test_main_push_does_not_repeat_release_build_contract(self):
        self.assertNotIn("\n  push:\n", self.workflow)
        self.assertIn("\n  workflow_dispatch:\n", self.workflow)

    def test_heavy_release_variant_contract_is_pr_only(self):
        block = section(self.workflow, "  release-variant-contract:\n", "  prepare-rc:\n")
        self.assertIn("if: ${{ github.event_name == 'pull_request' }}", block)
        self.assertIn(":app:assembleRelease", block)
        self.assertIn(":app:assembleReleaseAndroidTest", block)

    def test_main_activation_path_is_build_free(self):
        prepare = section(self.workflow, "  prepare-rc:\n", "  activate-rc:\n")
        activate = section(self.workflow, "  activate-rc:\n", "  publish-rc:\n")
        for block in (prepare, activate):
            self.assertNotIn("setup-java", block)
            self.assertNotIn("setup-gradle", block)
            self.assertNotIn("cargo install", block)
            self.assertNotIn("assembleRelease", block)
            self.assertNotIn("MISH_ANDROID_RELEASE_KEYSTORE_B64", block)
        self.assertIn("needs: contract", prepare)
        self.assertNotIn("release-variant-contract", prepare)

    def test_tag_run_owns_single_production_build(self):
        publish = section(self.workflow, "  publish-rc:\n")
        self.assertIn("environment: android-release", publish)
        self.assertIn("needs: contract", publish)
        self.assertNotIn("needs: [contract, release-variant-contract]", publish)
        self.assertEqual(publish.count(":app:assembleRelease \\\n"), 1)
        self.assertEqual(publish.count(":app:assembleReleaseAndroidTest"), 1)
        self.assertIn("Build, test, and sign the release candidate exactly once", publish)

    def test_published_rc_is_verified_immutable(self):
        publish = section(self.workflow, "  publish-rc:\n")
        self.assertIn('release.get("immutable") is not True', publish)
        self.assertIn("gh release verify \"$RC_TAG\"", publish)
        self.assertIn("gh release verify-asset \"$RC_TAG\"", publish)

    def test_previous_published_rc_must_be_immutable(self):
        prepare = section(self.workflow, "  prepare-rc:\n", "  activate-rc:\n")
        self.assertIn('release.get("immutable") is not True', prepare)
        self.assertIn("previous RC is not a published immutable prerelease", prepare)


if __name__ == "__main__":
    unittest.main()
