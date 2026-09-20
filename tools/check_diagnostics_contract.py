#!/usr/bin/env python3
"""Fail-closed guard for the read-only atomic MISH diagnostics control path."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def require(text: str, needle: str, label: str) -> None:
    if needle not in text:
        raise SystemExit(f"diagnostics contract missing {label}: {needle!r}")


def forbid(text: str, needle: str, label: str) -> None:
    if needle.lower() in text.lower():
        raise SystemExit(f"diagnostics contract contains forbidden {label}: {needle!r}")


def main() -> None:
    manifest = read("android/app/src/main/AndroidManifest.xml")
    provider = read("android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt")
    runtime_controller = read("android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt")
    diagnostics_owner = read("crates/runtime/src/product_diagnostics.rs")
    product_ffi = read("crates/android-ffi/src/product_runtime_ffi.rs")
    collector = read("lab/windows/collect-device-diagnostic.ps1")
    classifier = read("lab/windows/DeviceDiagnosticClassification.psm1")
    credential_bridge = read("lab/windows/CredentialProvisioning.psm1")
    workflow = read(".github/workflows/mish-lab-diagnostic.yml")

    # Stable read-only Android boundary.
    require(manifest, 'android:name=".MishDiagnosticsProvider"', "provider component")
    require(manifest, 'android:authorities="${applicationId}.diagnostics"', "stable authority")
    require(manifest, 'android:permission="android.permission.DUMP"', "DUMP permission gate")
    require(manifest, 'android:exported="true"', "ADB-visible provider")
    require(provider, 'MISH_DIAGNOSTICS_SCHEMA_V2 = "mish.diagnostics/v2"', "V2 schema")
    require(provider, 'MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2 = "snapshot_v2"', "V2 method")
    require(provider, "diagnostics provider is read-only", "mutation rejection")
    require(
        provider,
        "val snapshot = app.runtimeController.diagnosticSnapshot()",
        "single native snapshot request",
    )
    require(
        provider,
        "snapshot: ProductDiagnosticSnapshotView",
        "aggregate native serializer input",
    )
    require(
        runtime_controller,
        "productRuntime.diagnosticSnapshot()",
        "stable runtime aggregate projection",
    )

    # Rust owns generation fencing and semantic composition.
    for needle, label in (
        ("pub struct ProductDiagnosticSnapshot", "native aggregate snapshot"),
        ("pub struct ProductGenerationDiagnosticSnapshot", "generation aggregate snapshot"),
        ("DIAGNOSTIC_STABILITY_ATTEMPTS", "bounded stability capture"),
        ("Arc::ptr_eq(&generation, &current)", "generation identity fence"),
        ("runtime_before == runtime_after", "lifecycle stability fence"),
        ("first == second", "owner-fact stability fence"),
        ("self.diagnostic_snapshot_with(capture_generation)", "single native capture implementation"),
        ("let first = capture(&generation)?", "first pinned generation read"),
        ("let second = capture(&generation)?", "second pinned generation read"),
        ("generation_replacement_during_capture_never_returns_a_mixed_snapshot", "concurrent generation regression"),
        ("root_publication: Option<CellularPolicyPublication>", "root publication binding"),
        ("root_session_generation: Option<u64>", "root session generation"),
        ("pub rotation: RotationSnapshot", "native rotation owner projection"),
        ("let rotation_snapshot = generation.rotation().snapshot()", "rotation snapshot capture"),
    ):
        require(diagnostics_owner, needle, label)

    for needle, label in (
        ("pub struct ProductDiagnosticSnapshotView", "aggregate UniFFI record"),
        ("pub fn diagnostic_snapshot(", "single UniFFI diagnostic method"),
        ("map_product_diagnostic_snapshot", "Rust semantic projection"),
        ("root_policy_authorized_generation", "root authorization generation"),
        ("root_last_failure_class", "root last failure class"),
        ("proxy_recovery_operation_id", "Proxy recovery operation identity"),
        ("mesh_serving_generation", "Mesh serving generation"),
        ("readiness_expected_freshness", "readiness expected freshness"),
        ("readiness_observed_freshness", "readiness observed freshness"),
        ("rotation_operation_id", "rotation operation identity"),
        ("rotation_before_generation", "rotation before generation"),
        ("rotation_after_generation", "rotation after generation"),
        ("rotation_restore_required", "rotation restore requirement"),
        ("rotation_terminal_result", "rotation terminal result"),
        ("rotation_restore_result", "rotation restore result"),
        ("rotation_active_tasks", "rotation active task count"),
    ):
        require(product_ffi, needle, label)

    for obsolete in (
        "pub fn readiness_diagnostic_snapshot(",
        "pub fn proxy_active_sessions(",
        "pub fn dns_diagnostic_snapshot(",
        "pub fn cellular_reconcile_diagnostic(",
        "pub fn root_recovery_diagnostic(",
        "pub fn root_policy_reconcile_diagnostic(",
    ):
        forbid(product_ffi, obsolete, "per-owner diagnostic export")

    # Kotlin must serialize, not reconstruct PRODUCT state.
    for forbidden in (
        "currentCellularRuntime",
        "currentProxyRuntime",
        "currentProductRuntime",
        "currentMeshRuntime",
        "runtimeRecoveryBefore",
        "runtimeRecoveryAfter",
        "cellularBefore",
        "cellularAfter",
        "proxyBefore",
        "proxyAfter",
        "readinessBefore",
        "readinessAfter",
        "meshBefore",
        "meshAfter",
        "sameGeneration",
        "MishDiagnosticFactsV2",
        "CellularAdmissionState",
        "ProductReadinessState",
        "ProcessBuilder(",
        "airplane-mode enable",
        "airplane-mode disable",
        "rotateExternalCredential",
        "revokeExternalCredential",
    ):
        forbid(provider, forbidden, "Kotlin semantic composition or mutation")

    # The canonical JSON still exposes the bounded owner-backed V2 facts expected by LAB.
    for needle, label in (
        ('put("generation", snapshot.runtimeGeneration.toLong())', "runtime generation"),
        ('put("owner_sequence", snapshot.cellularOwnerSequence?.toLong() ?: JSONObject.NULL)', "Cellular owner sequence"),
        ('snapshot.proxyServingGeneration?.toLong() ?: JSONObject.NULL', "Proxy serving generation"),
        ('put("version", snapshot.credentialVersion?.toLong() ?: JSONObject.NULL)', "credential version"),
        ('snapshot.meshObservationSequence?.toLong() ?: JSONObject.NULL', "Mesh observation sequence"),
        ('snapshot.meshAdmissionEpoch?.toLong() ?: JSONObject.NULL', "Mesh admission epoch"),
        ('put("attempts_since_reset", snapshot.rootRecovery.attemptsSinceReset.toLong())', "root recovery attempt"),
        ('put("next_delay_ms", snapshot.rootRecovery.nextDelayMs.toLong())', "root recovery backoff"),
        ('snapshot.proxyRecoveryAttemptsScheduled.toLong()', "proxy recovery attempt"),
        ('put("next_delay_ms", snapshot.proxyRecoveryNextDelayMs.toLong())', "proxy recovery backoff"),
        ('snapshot.rootPolicyAuthorizedGeneration?.toLong() ?: JSONObject.NULL', "root authorized generation"),
        ('putNullable("last_failure_class", snapshot.rootLastFailureClass)', "root last failure class"),
        ('put("operation_id", snapshot.proxyRecoveryOperationId.toLong())', "Proxy recovery operation"),
        ('snapshot.meshServingGeneration?.toLong() ?: JSONObject.NULL', "Mesh serving generation"),
        ('snapshot.readinessExpectedFreshness?.toLong() ?: JSONObject.NULL', "readiness expected freshness"),
        ('snapshot.readinessObservedFreshness?.toLong() ?: JSONObject.NULL', "readiness observed freshness"),
        ('snapshot.rotationOperationId?.toLong() ?: JSONObject.NULL', "rotation operation id"),
        ('snapshot.rotationBeforeGeneration?.toLong() ?: JSONObject.NULL', "rotation before generation"),
        ('snapshot.rotationAfterGeneration?.toLong() ?: JSONObject.NULL', "rotation after generation"),
        ('put("restore_required", snapshot.rotationRestoreRequired)', "rotation restore requirement"),
        ('putNullable("terminal_result", snapshot.rotationTerminalResult)', "rotation terminal result"),
        ('putNullable("restore_result", snapshot.rotationRestoreResult)', "rotation restore result"),
        ('put("active_tasks", snapshot.rotationActiveTasks.toLong())', "rotation active task count"),
        ('put("raw_ip_persisted", false)', "raw public IP persistence prohibition"),
    ):
        require(provider, needle, label)

    if provider.count('put("active_sessions"') != 2:
        raise SystemExit("diagnostics contract must publish exactly proxy + Mesh active_sessions")

    # Current LAB control remains bound to the V2 schema and classifies facts without repair.
    require(collector, "mish.lab.diagnostic/v2", "LAB V2 schema")
    require(collector, "mish.diagnostics/v2", "Android V2 schema binding")
    require(collector, "snapshot_v2", "V2 snapshot method")
    require(collector, "'shell', 'content', 'call'", "single ADB snapshot bridge")
    require(collector, "android.cellular.admitted", "Cellular owner projection")
    require(collector, "android.root.authority_observation", "root authority projection")
    require(collector, "android.root.policy_authorized", "root policy projection")
    require(collector, "Get-MishDeviceDiagnosticClassification", "deterministic classifier")
    for forbidden in (
        "snapshot_v1",
        "mish.diagnostics/v1",
        "mish.lab.diagnostic/v1",
        "adb install",
        "force-stop",
        "airplane-mode",
        "settings put",
    ):
        forbid(collector, forbidden, "collector mutation or obsolete schema")

    require(classifier, "PRODUCT_ROOT_AUTHORITY_UNAVAILABLE", "root authority classification")
    require(classifier, "PRODUCT_ROOT_POLICY_NOT_AUTHORIZED", "root policy classification")
    require(classifier, "PRODUCT_CELLULAR_", "Cellular classification")
    require(classifier, "PRODUCT_PROXY_", "Proxy classification")
    require(classifier, "PRODUCT_CREDENTIAL_INACTIVE", "credential classification")
    forbid(classifier, "repair", "diagnostics classifier repair instruction")

    require(
        credential_bridge,
        "$script:ProvisioningReceiverClass = 'com.mobileproxymish.app.CredentialProvisioningReceiver'",
        "stable provisioning receiver",
    )

    require(workflow, "github.event.issue.number == 163", "dedicated control issue")
    require(workflow, "github.event.comment.user.login == 'iamaman11'", "owner gate")
    require(workflow, "github.event.comment.body == '/mish-diag snapshot'", "strict command grammar")
    require(workflow, "collect-device-diagnostic.ps1", "canonical collector")
    require(workflow, "mish-device-diagnostic-v2.json", "V2 evidence path")

    serialization_test = read(
        "android/app/src/test/java/com/mobileproxymish/app/MishDiagnosticsSerializationTest.kt"
    )
    require(serialization_test, "ProductDiagnosticSnapshotView(", "atomic snapshot fixture")
    require(serialization_test, "renderMishDiagnosticSnapshotV2(", "serializer invocation")
    require(serialization_test, 'getLong("policy_authorized_generation")', "root generation assertion")
    require(serialization_test, 'getLong("operation_id")', "Proxy operation assertion")
    require(serialization_test, 'getLong("serving_generation")', "Mesh generation assertion")
    require(serialization_test, 'getLong("expected_freshness")', "readiness freshness assertion")
    require(serialization_test, 'getLong("operation_id")', "rotation operation assertion")
    require(serialization_test, 'getLong("before_generation")', "rotation generation assertion")
    require(serialization_test, 'getLong("active_tasks")', "rotation active-task assertion")
    require(serialization_test, 'getBoolean("raw_ip_persisted")', "raw IP persistence assertion")

    print("diagnostics contract: PASS")


if __name__ == "__main__":
    main()
