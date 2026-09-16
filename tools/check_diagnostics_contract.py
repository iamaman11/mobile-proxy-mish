#!/usr/bin/env python3
"""Fail-closed guard for the read-only MISH diagnostics control path."""

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
    provider = (ROOT / "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt").read_text(encoding="utf-8")
    collector = (ROOT / "lab/windows/collect-device-diagnostic.ps1").read_text(encoding="utf-8")
    classifier = (ROOT / "lab/windows/DeviceDiagnosticClassification.psm1").read_text(encoding="utf-8")
    credential_bridge = (ROOT / "lab/windows/CredentialProvisioning.psm1").read_text(encoding="utf-8")
    workflow = (ROOT / ".github/workflows/mish-lab-diagnostic.yml").read_text(encoding="utf-8")

    # Protected main may temporarily carry the previous PRODUCT provider while DEVICE-1 control
    # consumes an already-built exact integration candidate. Guard the stable provider boundary and
    # read-only semantics here; the exact PRODUCT candidate's schema/topology is proved by its own
    # hosted architecture gate. Never partially promote PRODUCT runtime code just to update LAB control.
    require(manifest, 'android:name=".MishDiagnosticsProvider"', "provider component")
    require(manifest, 'android:authorities="${applicationId}.diagnostics"', "stable authority")
    require(manifest, 'android:permission="android.permission.DUMP"', "DUMP permission gate")
    require(manifest, 'android:exported="true"', "ADB-visible provider")
    require(provider, 'diagnostics provider is read-only', "mutation rejection")
    require(provider, 'READY_AT_POLICY_AUTHORIZATION', "non-mutating root observation")
    for forbidden in ("ProcessBuilder(", "settings put", "airplane-mode enable", "airplane-mode disable", "adb install"):
        forbid(provider, forbidden, "diagnostic mutation/control surface")

    # Current U2 control is explicitly bound to the generation-fenced L8 candidate contract.
    require(collector, 'mish.lab.diagnostic/v2', "LAB V2 schema")
    require(collector, 'mish.diagnostics/v2', "Android V2 candidate schema binding")
    require(collector, 'snapshot_v2', "V2 snapshot method")
    require(collector, "'shell', 'content', 'call'", "single ADB snapshot bridge")
    require(collector, "forward 'tcp:0' 'tcp:3128'", "independent loopback E2E probe")
    require(collector, 'Open-MishExternalProxyCredentialLease', "existing credential authority")
    require(collector, "android.proxy.state -ceq 'RUNNING' -and [bool]$android.credential.active", "late LAB credential lease gate")
    require(collector, 'credential_lease_status = $credentialLeaseStatus', "typed LAB credential status")
    require(collector, 'android.cellular.admitted', "Cellular owner projection")
    require(collector, 'android.root.authority_observation', "root authority projection")
    require(collector, 'android.root.policy_authorized', "root policy projection")
    require(collector, 'Get-MishDeviceDiagnosticClassification', "deterministic fact classifier")
    for forbidden in (
        "snapshot_v1",
        "mish.diagnostics/v1",
        "mish.lab.diagnostic/v1",
        "adb install",
        "force-stop",
        "airplane-mode",
        "settings put",
        "cloudflare prove",
        "CREDENTIAL_LEASE_UNAVAILABLE",
    ):
        forbid(collector, forbidden, "collector mutation, obsolete schema or ambiguous attribution")

    require(classifier, "PRODUCT_ROOT_AUTHORITY_UNAVAILABLE", "root authority failure priority")
    require(classifier, "PRODUCT_ROOT_POLICY_NOT_AUTHORIZED", "root policy failure priority")
    require(classifier, "PRODUCT_CELLULAR_", "Cellular owner failure priority")
    require(classifier, "PRODUCT_PROXY_", "PRODUCT proxy failure priority")
    require(classifier, "PRODUCT_CREDENTIAL_INACTIVE", "PRODUCT credential distinction")
    require(classifier, "LAB_CREDENTIAL_PROVISIONING_FAILED", "LAB provisioning distinction")
    require(classifier, "LAB_CREDENTIAL_LEASE_OPEN_FAILED", "LAB lease-open distinction")
    forbid(classifier, "repair", "diagnostics must classify facts, never prescribe repair")

    require(
        credential_bridge,
        "$script:ProvisioningReceiverClass = 'com.mobileproxymish.app.CredentialProvisioningReceiver'",
        "stable receiver implementation class",
    )
    require(
        credential_bridge,
        '$provisioningComponent = "$resolvedPackage/$script:ProvisioningReceiverClass"',
        "applicationId/namespace-safe component address",
    )
    forbid(credential_bridge, '$resolvedPackage/.CredentialProvisioningReceiver', "applicationId-relative receiver class")

    require(workflow, "github.event.issue.number == 163", "dedicated control issue")
    require(workflow, "github.event.comment.user.login == 'iamaman11'", "owner gate")
    require(workflow, "github.event.comment.body == '/mish-diag snapshot'", "strict command grammar")
    require(workflow, 'collect-device-diagnostic.ps1', "canonical collector")
    require(workflow, "DIAGNOSTIC_PWSH_VERSION: '7.6.6'", "pinned diagnostic PowerShell")
    require(workflow, 'mish-device-diagnostic-v2.json', "V2 runtime evidence path")
    require(workflow, 'mish-device-diagnostic-v2-${{ github.run_id }}', "V2 artifact identity")
    require(workflow, '[ScriptBlock]::Create', "extensionless GitHub temp-script execution under pinned pwsh")
    forbid(workflow, 'mish-device-diagnostic-v1', "obsolete V1 evidence identity")
    forbid(workflow, 'shell: powershell', "Windows PowerShell 5.1 diagnostic execution")
    forbid(workflow, 'EVIDENCE_PATH: ${{ runner.temp }}', "runner context in job-level env")

    print("diagnostics contract: PASS")


if __name__ == "__main__":
    main()
