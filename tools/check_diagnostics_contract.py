#!/usr/bin/env python3
"""Fail-closed guard for the permanent read-only MISH diagnostics bridge."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f"diagnostics contract missing {label}: {needle!r}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle.lower() in text.lower():
        raise SystemExit(f"diagnostics contract contains forbidden {label}: {needle!r}")


def main() -> None:
    manifest = (ROOT / "android/app/src/main/AndroidManifest.xml").read_text(encoding="utf-8")
    provider = (
        ROOT
        / "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt"
    ).read_text(encoding="utf-8")
    collector = (ROOT / "lab/windows/collect-device-diagnostic.ps1").read_text(encoding="utf-8")
    workflow = (ROOT / ".github/workflows/mish-lab-diagnostic.yml").read_text(encoding="utf-8")

    require(manifest, 'android:name=".MishDiagnosticsProvider"', "provider component")
    require(manifest, 'android:authorities="${applicationId}.diagnostics"', "stable authority")
    require(manifest, 'android:permission="android.permission.DUMP"', "DUMP permission gate")
    require(manifest, 'android:exported="true"', "ADB-visible provider")

    require(provider, 'mish.diagnostics/v1', "Android V1 schema")
    require(provider, 'snapshot_v1', "snapshot method")
    require(provider, 'diagnostics provider is read-only', "mutation rejection")
    require(provider, 'READY_AT_POLICY_AUTHORIZATION', "non-mutating root observation")
    for forbidden in (
        "ProcessBuilder(",
        "settings put",
        "airplane-mode enable",
        "airplane-mode disable",
        "adb install",
    ):
        forbid(provider, forbidden, "diagnostic mutation/control surface")

    require(collector, 'mish.lab.diagnostic/v1', "LAB V1 schema")
    require(collector, "'shell', 'content', 'call'", "single ADB snapshot bridge")
    require(collector, "forward 'tcp:0' 'tcp:3128'", "independent loopback E2E probe")
    require(collector, 'Open-MishExternalProxyCredentialLease', "existing credential authority")
    for forbidden in (
        "adb install",
        "force-stop",
        "airplane-mode",
        "settings put",
        "cloudflare prove",
    ):
        forbid(collector, forbidden, "collector mutation")

    require(workflow, "github.event.issue.number == 163", "dedicated control issue")
    require(workflow, "github.event.comment.user.login == 'iamaman11'", "owner gate")
    require(workflow, "github.event.comment.body == '/mish-diag snapshot'", "strict command grammar")
    require(workflow, 'collect-device-diagnostic.ps1', "canonical collector")

    print("diagnostics contract: PASS")


if __name__ == "__main__":
    main()
