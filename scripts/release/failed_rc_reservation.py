#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

HEX40_RE = re.compile(r"^[0-9a-f]{40}$")
RC_TAG_RE = re.compile(r"^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-rc\.([1-9]\d*)$")
WORKFLOW_NAME = "Android Release Candidate"
WORKFLOW_PATH = ".github/workflows/android-release.yml"
PUBLISH_JOB_NAME = "Publish immutable Android RC"
BOT_LOGIN = "github-actions[bot]"


def verify(*, tag: str, tag_sha: str, runs_path: Path, jobs_path: Path) -> dict[str, object]:
    if RC_TAG_RE.fullmatch(tag) is None:
        raise ValueError("previous reservation tag is not a canonical RC tag")
    if HEX40_RE.fullmatch(tag_sha) is None:
        raise ValueError("previous reservation source must be a lowercase 40-hex Git SHA")

    runs_doc = json.loads(runs_path.read_text(encoding="utf-8"))
    runs = runs_doc.get("workflow_runs") if isinstance(runs_doc, dict) else None
    if not isinstance(runs, list):
        raise ValueError("workflow run evidence must contain workflow_runs list")
    total_count = runs_doc.get("total_count")
    if not isinstance(total_count, int) or isinstance(total_count, bool) or total_count != len(runs):
        raise ValueError("workflow run evidence must be complete and unpaginated")

    matching = [
        run
        for run in runs
        if isinstance(run, dict)
        and run.get("name") == WORKFLOW_NAME
        and run.get("path") == WORKFLOW_PATH
        and run.get("head_branch") == tag
        and run.get("head_sha") == tag_sha
        and run.get("event") == "workflow_dispatch"
        and run.get("status") == "completed"
        and run.get("conclusion") == "failure"
        and isinstance(run.get("actor"), dict)
        and run["actor"].get("login") == BOT_LOGIN
    ]
    if len(matching) != 1:
        raise ValueError("previous unpublished RC must have exactly one failed machine-owned Android release workflow_dispatch run")

    run_id = matching[0].get("id")
    if not isinstance(run_id, int) or isinstance(run_id, bool) or run_id <= 0:
        raise ValueError("failed reservation workflow run id is invalid")

    jobs_doc = json.loads(jobs_path.read_text(encoding="utf-8"))
    jobs = jobs_doc.get("jobs") if isinstance(jobs_doc, dict) else None
    if not isinstance(jobs, list):
        raise ValueError("workflow job evidence must contain jobs list")
    jobs_total = jobs_doc.get("total_count")
    if not isinstance(jobs_total, int) or isinstance(jobs_total, bool) or jobs_total != len(jobs):
        raise ValueError("workflow job evidence must be complete and unpaginated")

    publish_jobs = [
        job
        for job in jobs
        if isinstance(job, dict)
        and job.get("run_id") == run_id
        and job.get("name") == PUBLISH_JOB_NAME
        and job.get("status") == "completed"
        and job.get("conclusion") == "failure"
    ]
    if len(publish_jobs) != 1:
        raise ValueError("failed reservation must contain exactly one failed Publish immutable Android RC job")

    publish_job_id = publish_jobs[0].get("id")
    if not isinstance(publish_job_id, int) or isinstance(publish_job_id, bool) or publish_job_id <= 0:
        raise ValueError("failed reservation publish job id is invalid")

    return {
        "tag": tag,
        "source_sha": tag_sha,
        "run_id": run_id,
        "publish_job_id": publish_job_id,
        "status": "VERIFIED_FAILED_MACHINE_OWNED_UNPUBLISHED_RESERVATION",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--tag-sha", required=True)
    parser.add_argument("--runs-json", required=True)
    parser.add_argument("--jobs-json", required=True)
    args = parser.parse_args()
    try:
        result = verify(
            tag=args.tag,
            tag_sha=args.tag_sha,
            runs_path=Path(args.runs_json),
            jobs_path=Path(args.jobs_json),
        )
    except (OSError, json.JSONDecodeError, ValueError) as exc:
        print(f"failed RC reservation verification failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
