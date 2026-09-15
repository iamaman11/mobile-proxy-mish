#!/usr/bin/env python3
"""Fail-closed guard for CI PRODUCT-vs-infrastructure path classification."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github/workflows/ci.yml"


def main() -> None:
    text = CI.read_text(encoding="utf-8")

    required = (
        "tools/check_*.py",
        ".github/workflows/device-cycle.yml",
        "No Rust product inputs changed",
        "No Android product inputs changed",
        "full_product_gate",
    )
    for needle in required:
        if needle not in text:
            raise SystemExit(f"ci scope contract: required infra-only classification fact missing: {needle}")

    forbidden = (
        "tools/*|",
        "tools/*.py|",
        "tools/materialize_sing_box_android.py|",
    )
    for needle in forbidden:
        if needle in text:
            raise SystemExit(f"ci scope contract: PRODUCT-affecting tools must not be broadly excluded: {needle}")

    classifier = next((line.strip() for line in text.splitlines() if "tools/check_*.py" in line), "")
    if "lab/*" not in classifier or ".github/workflows/device-cycle.yml" not in classifier:
        raise SystemExit("ci scope contract: diagnostic/control paths are not classified together as infra-only")
    if ".github/workflows/ci.yml" in classifier:
        raise SystemExit("ci scope contract: changes to CI gate authority itself must still exercise the full PRODUCT gate")

    print("CI_SCOPE_CONTRACT=PASS")


if __name__ == "__main__":
    main()
