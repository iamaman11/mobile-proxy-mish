#!/usr/bin/env python3
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("failed_rc_reservation.py")
SPEC = importlib.util.spec_from_file_location("failed_rc_reservation", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class FailedReservationContractTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.tag = "v0.1.0-rc.2"
        self.sha = "a" * 40
        self.run_id = 1234
        self.job_id = 5678
        self.runs = self.root / "runs.json"
        self.jobs = self.root / "jobs.json"
        self.write_valid()

    def tearDown(self):
        self.tmp.cleanup()

    def write_valid(self):
        self.runs.write_text(json.dumps({
            "total_count": 1,
            "workflow_runs": [{
                "id": self.run_id,
                "name": "Android Release Candidate",
                "path": ".github/workflows/android-release.yml",
                "head_branch": self.tag,
                "head_sha": self.sha,
                "event": "workflow_dispatch",
                "status": "completed",
                "conclusion": "failure",
                "actor": {"login": "github-actions[bot]"},
            }],
        }), encoding="utf-8")
        self.jobs.write_text(json.dumps({
            "total_count": 1,
            "jobs": [{
                "id": self.job_id,
                "run_id": self.run_id,
                "name": "Publish immutable Android RC",
                "status": "completed",
                "conclusion": "failure",
            }],
        }), encoding="utf-8")

    def verify(self):
        return MODULE.verify(tag=self.tag, tag_sha=self.sha, runs_path=self.runs, jobs_path=self.jobs)

    def test_exact_failed_machine_owned_reservation_passes(self):
        result = self.verify()
        self.assertEqual(result["run_id"], self.run_id)
        self.assertEqual(result["publish_job_id"], self.job_id)
        self.assertEqual(result["status"], "VERIFIED_FAILED_MACHINE_OWNED_UNPUBLISHED_RESERVATION")

    def test_human_actor_fails_closed(self):
        data = json.loads(self.runs.read_text())
        data["workflow_runs"][0]["actor"]["login"] = "human"
        self.runs.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify()

    def test_successful_run_is_not_failed_reservation(self):
        data = json.loads(self.runs.read_text())
        data["workflow_runs"][0]["conclusion"] = "success"
        self.runs.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify()

    def test_wrong_source_fails_closed(self):
        data = json.loads(self.runs.read_text())
        data["workflow_runs"][0]["head_sha"] = "b" * 40
        self.runs.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify()

    def test_wrong_workflow_path_fails_closed(self):
        data = json.loads(self.runs.read_text())
        data["workflow_runs"][0]["path"] = ".github/workflows/not-the-owner.yml"
        self.runs.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify()

    def test_missing_failed_publish_job_fails_closed(self):
        self.jobs.write_text(json.dumps({"total_count": 0, "jobs": []}), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "failed Publish"):
            self.verify()

    def test_duplicate_failed_runs_fail_closed(self):
        data = json.loads(self.runs.read_text())
        duplicate = dict(data["workflow_runs"][0])
        duplicate["id"] = 9999
        data["workflow_runs"].append(duplicate)
        data["total_count"] = 2
        self.runs.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            self.verify()

    def test_truncated_run_evidence_fails_closed(self):
        data = json.loads(self.runs.read_text())
        data["total_count"] = 2
        self.runs.write_text(json.dumps(data), encoding="utf-8")
        with self.assertRaisesRegex(ValueError, "complete"):
            self.verify()

    def test_noncanonical_tag_fails_closed(self):
        self.tag = "v0.1.0-rc.02"
        with self.assertRaisesRegex(ValueError, "canonical"):
            self.verify()


if __name__ == "__main__":
    unittest.main()
