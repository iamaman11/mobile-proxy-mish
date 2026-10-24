#!/usr/bin/env python3
"""Evidence-locked one-time branch cleanup. No PRODUCT or DEVICE mutations."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "iamaman11/mobile-proxy-mish"
ALLOWLIST = Path(".github/branch-prune-allowlist-2026-10-25.json")
INVENTORY = Path("docs/audits/branch-inventory-2026-10-25.json")
RECEIPT = Path("branch-hygiene-receipt.json")
SAFE_NAME = re.compile(r"[A-Za-z0-9._/-]+", re.ASCII)


def api(method, path, token, *, missing_ok=False):
    url = "https://api.github.com/repos/" + REPOSITORY + path
    req = urllib.request.Request(url, method=method, headers={
        "Authorization": "Bearer " + token,
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "mish-evidence-locked-branch-pruner",
    })
    try:
        with urllib.request.urlopen(req, timeout=40) as response:
            raw = response.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as exc:
        if missing_ok and exc.code == 404:
            return None
        raise RuntimeError("GitHub API rejected " + method + " " + path.split("?")[0]
                           + ": HTTP " + str(exc.code)) from exc


def run():
    comment = os.environ.get("MISH_BRANCH_COMMAND", "").strip()
    match = re.fullmatch(r"/mish-maint branches-(dry-run|prune) ([0-9a-f]{40})", comment)
    if not match:
        raise RuntimeError("Exact operator command required")
    mode, expected_blob = match.groups()
    if os.environ.get("GITHUB_REPOSITORY") != REPOSITORY:
        raise RuntimeError("Unexpected repository")
    if os.environ.get("MISH_COMMENT_AUTHOR") != "iamaman11":
        raise RuntimeError("Only the repository owner can approve deletion")
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        raise RuntimeError("No GitHub Actions token")
    actual_blob = subprocess.check_output(
        ["git", "hash-object", str(ALLOWLIST)], text=True
    ).strip()
    if actual_blob != expected_blob:
        raise RuntimeError("Allowlist Git blob SHA mismatch; aborting all mutations")
    allow = json.loads(ALLOWLIST.read_text(encoding="utf-8"))
    inventory = json.loads(INVENTORY.read_text(encoding="utf-8"))
    if allow.get("schema") != "mish.merged-pr-branch-allowlist/v1":
        raise RuntimeError("Unknown allowlist schema")
    if inventory.get("schema") != "mish.branch-hygiene-inventory/v1":
        raise RuntimeError("Unknown inventory schema")
    candidates = {row["branch"]: row for row in inventory["rows"]
                  if row["classification"] == "DELETE_CANDIDATE"}
    entries = allow.get("entries", [])
    if len(entries) != 272 or len(candidates) != 272:
        raise RuntimeError("Expected exactly 272 reviewed main-merged candidates")
    if set(e["branch"] for e in entries) != set(candidates):
        raise RuntimeError("Inventory and allowlist disagree")
    if len(set(e["branch"] for e in entries)) != len(entries):
        raise RuntimeError("Duplicate branch names")
    if allow.get("baseline_main_sha") != inventory.get("protected_main_sha"):
        raise RuntimeError("Baseline identity mismatch")
    workflow_sources = {
        str(p): p.read_text(encoding="utf-8")
        for p in Path(".github/workflows").glob("*.yml")
    }
    results = []
    failure = None
    try:
        # Fetch all open PRs in bounded pages, not one API call per branch.
        # Periodically refresh to account for new PRs while staying inside
        # the 1,000-requests/hour GITHUB_TOKEN per-repository API budget.
        for index, item in enumerate(entries):
            if index % 20 == 0:
                open_prs = api("GET", "/pulls?state=open&per_page=100", token)
                if len(open_prs) == 100:
                    raise RuntimeError("Open PR list may be truncated; refuse deletion")
            name, sha, pr_num = item["branch"], item["expected_sha"], item["merged_pr"]
            result = {"branch": name, "expected_sha": sha, "merged_pr": pr_num}
            if (not SAFE_NAME.fullmatch(name) or name.startswith("/") or ".." in name
                    or name in ("main", "integration/m1", "rotation/candidate-a-product")
                    or name.startswith("maint/457-")):
                raise RuntimeError("Ref refused by hard exclusions: " + name)
            record = candidates[name]
            if record["head_sha"] != sha or not any(
                    p["number"] == pr_num and p["pr_head_sha"] == sha
                    and p["merged_at"] and p["base"] == "main"
                    for p in record["related_prs"]):
                raise RuntimeError("Candidate lacks exact merged-to-main evidence: " + name)
            if any(name in source for source in workflow_sources.values()):
                raise RuntimeError("Active workflow refers to branch: " + name)
            encoded = urllib.parse.quote(name, safe="/")
            existing = api("GET", "/git/ref/heads/" + encoded, token, missing_ok=True)
            if existing is None:
                result["status"] = "ALREADY_ABSENT"
                results.append(result)
                continue
            if existing.get("object", {}).get("sha") != sha:
                raise RuntimeError("Head SHA changed since inventory: " + name)
            branch = api("GET", "/branches/" + encoded, token)
            if branch.get("protected"):
                raise RuntimeError("Protected branch: " + name)
            pr = api("GET", "/pulls/" + str(pr_num), token)
            head = pr.get("head", {})
            if not (pr.get("merged_at") and pr.get("base", {}).get("ref") == "main"
                    and head.get("sha") == sha and head.get("ref") == name
                    and (head.get("repo") or {}).get("full_name") == REPOSITORY):
                raise RuntimeError("GitHub merged PR no longer proves tip: " + name)
            if any(p.get("head", {}).get("ref") == name and
                   (p.get("head", {}).get("repo") or {}).get("full_name") == REPOSITORY
                   for p in open_prs):
                raise RuntimeError("Open PR references branch: " + name)
            if mode == "prune":
                api("DELETE", "/git/refs/heads/" + encoded, token)
                result["status"] = "DELETED"
                time.sleep(0.25)
            else:
                result["status"] = "DRY_RUN_OK"
            results.append(result)
            if len(results) % 25 == 0:
                print("Audited", len(results), "of", len(entries), "exact branch refs", flush=True)
    except Exception as exc:
        failure = str(exc)
    receipt = {
        "schema": "mish.branch-hygiene-receipt/v1",
        "mode": mode, "allowlist_blob_sha": expected_blob,
        "expected_entries": len(entries),
        "checked_entries": len(results),
        "deleted": sum(x["status"] == "DELETED" for x in results),
        "already_absent": sum(x["status"] == "ALREADY_ABSENT" for x in results),
        "dry_run_ok": sum(x["status"] == "DRY_RUN_OK" for x in results),
        "failure": failure,
        "entries": results,
    }
    RECEIPT.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    print("BRANCH_HYGIENE_MODE=" + mode)
    print("BRANCH_HYGIENE_CHECKED=" + str(len(results)))
    print("BRANCH_HYGIENE_DELETED=" + str(receipt["deleted"]))
    print("BRANCH_HYGIENE_FAILURE=" + str(failure or "NONE"))
    if failure:
        raise RuntimeError(failure)


if __name__ == "__main__":
    try:
        run()
    except Exception as ex:
        print("BRANCH_HYGIENE_ABORT=" + str(ex), file=sys.stderr)
        sys.exit(1)
