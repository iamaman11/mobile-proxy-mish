#!/usr/bin/env python3
"""Fail-closed architecture guard dispatcher for the Candidate A Rotation transition.

The accepted pre-transition checker is retained byte-for-byte in
check_architecture_legacy.py.  This dispatcher replaces exactly one sentinel-bounded Rotation
section with the current Candidate A invariants, then executes the complete checker.  Every
non-Rotation invariant therefore remains identical to the accepted baseline.  Sentinel drift is a
hard failure rather than a silent skip.
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent
LEGACY = HERE / "check_architecture_legacy.py"
START = "    # G first-class rotation is one-way: mish-rotation owns semantics, mish-runtime executes\n"
END = "    # U5 root ownership is one-way: policy semantics live in mish-cellular, while the one\n"

CANDIDATE_A = r'''    # Candidate A first-class Rotation remains one-way: mish-rotation owns semantics,
    # mish-runtime executes sealed mobile-data effects over the existing persistent root session,
    # and Android remains a typed command/projection boundary with no PRODUCT timing or retry owner.
    rotation_semantics = "crates/rotation/src/lib.rs"
    rotation_runtime = "crates/runtime/src/rotation_runtime.rs"
    mobile_data_effect = "crates/runtime/src/mobile_data_effect.rs"
    product_generation = "crates/runtime/src/product_generation.rs"
    proxy_owner = "crates/runtime/src/proxy_coordinator.rs"

    for required in (
        "pub struct RotationStateMachine",
        "pub enum RotationMutationOutcome",
        "DataDisabling",
        "WaitingCellularLoss",
        "DataEnabling",
        "pub fn data_disable_effect_completed(",
        "pub fn data_enable_effect_completed(",
        "pub fn observe_cellular(",
        "pub fn observe_root_policy(",
        "pub fn deadline_exceeded(",
        "RotationTerminalResult::Changed",
        "RotationTerminalResult::Unchanged",
        "RotationTerminalResult::Failed",
        "CredentialChanged,",
    ):
        require_product(
            rotation_semantics,
            required,
            "mish-rotation must remain the sole Candidate A IP-rotation semantic owner",
        )
    for required in (
        "entering_disable_phase_marks_restore_before_mutation_can_race_deadline",
        "disable_completion_alone_never_implies_cellular_loss",
        "enable_is_reached_only_after_fresh_authoritative_loss",
        "loss_can_arrive_during_disable_effect_without_being_lost",
        "uncertain_disable_fails_main_path_and_requires_restore",
        "uncertain_enable_fails_main_path_and_preserves_restore_requirement",
        "fresh_generation_requires_exact_root_authorization",
        "root_fact_may_arrive_before_same_generation_cellular",
        "newer_owner_loss_invalidates_older_recovery_and_root_facts",
        "absolute_deadline_keeps_restore_requirement_only_while_data_may_be_disabled",
    ):
        require(
            rotation_semantics,
            required,
            "Candidate A pure tests must pin currentness, uncertainty, ordering and deadline semantics",
        )

    for required in (
        "pub struct RotationRuntimeCoordinator",
        "ROTATION_SAFETY_DEADLINE",
        "timeout_at(deadline, cancel.notified())",
        "observe_public_egress_ip_async",
        "policy.add_internal_observer",
        "policy.mobile_data_effect()",
        "RotationAction::DisableData",
        "RotationAction::EnableData",
        "RotationAction::RestoreEnabled",
        "MobileDataState::Disabled",
        "MobileDataState::Enabled",
        "restore_enabled_direct",
        "credential_guard_current",
        "RESTORE_EFFECT_TIMEOUT",
    ):
        require_product(
            rotation_runtime,
            required,
            "mish-runtime must execute one event-driven Candidate A rotation on the shared Tokio runtime",
        )
    for forbidden in (
        "Runtime::new",
        "Builder::new",
        "std::thread",
        "thread::sleep",
        "tokio::time::sleep(",
        "retry_until_changed",
        "AirplaneModeState::",
        "airplane_effect()",
    ):
        forbid_product(
            rotation_runtime,
            forbidden,
            "Candidate A runtime must not create a second executor, dwell/retry loop, or runtime airplane fallback",
        )

    for required in (
        "RootSessionManager",
        'RootCommand::observation("settings get global mobile_data")',
        'RootCommand::mutation("cmd phone data disable")',
        'RootCommand::mutation("cmd phone data enable")',
        "MutationUncertain",
        '"1" => Some(MobileDataState::Enabled)',
        '"0" => Some(MobileDataState::Disabled)',
    ):
        require_product(
            mobile_data_effect,
            required,
            "Candidate A mobile-data observation/disable/enable must be sealed typed effects over the one persistent root session",
        )
    forbid_product(
        mobile_data_effect,
        "sleep(",
        "mobile-data effect must not own recovery timing",
    )
    require_product_count(
        mobile_data_effect,
        'RootCommand::mutation("cmd phone data disable")',
        1,
        "Candidate A must have one sealed disable command construction site",
    )
    require_product_count(
        mobile_data_effect,
        'RootCommand::mutation("cmd phone data enable")',
        1,
        "Candidate A must have one sealed enable command construction site",
    )

    require_product(
        "crates/runtime/src/cellular_policy_coordinator.rs",
        "crate::mobile_data_effect::MobileDataEffect::new(Arc::clone(&self.root_session))",
        "Candidate A must borrow the existing persistent RootSessionManager rather than create a second root owner",
    )
    require_product(
        "crates/runtime/Cargo.toml",
        'mish-rotation = { path = "../rotation" }',
        "mish-runtime must depend on the rotation semantic owner",
    )
    for required in ("mod mobile_data_effect;", "mod rotation_runtime;"):
        require_product(
            "crates/runtime/src/entry.rs",
            required,
            "Candidate A execution modules must compile inside mish-runtime",
        )
    for required in (
        "rotation: Arc<RotationRuntimeCoordinator>",
        "let rotation = RotationRuntimeCoordinator::new(",
        "let rotation_clean = self.rotation.shutdown().await;",
    ):
        require_product(
            product_generation,
            required,
            "ProductGeneration must own and drain exactly one Rotation runtime",
        )
    for required in (
        "pub fn start_public_ip_rotation(",
        "generation.rotation().observe_cellular(admission)",
        "pub fn rotation_snapshot(",
    ):
        require_product(
            "crates/runtime/src/product_runtime.rs",
            required,
            "stable PRODUCT runtime must expose and feed the Rust-owned Rotation operation",
        )
    for required in (
        "struct ProxyCredentialGuard",
        "pub(crate) fn credential_guard(&self)",
        "pub(crate) fn credential_guard_matches",
    ):
        require_product(
            proxy_owner,
            required,
            "network rotation must prove external proxy credential version/material stability",
        )

    product_ffi = "crates/android-ffi/src/product_runtime_ffi.rs"
    for required in (
        "pub struct RotationSnapshotView",
        "pub fn start_public_ip_rotation(",
        "pub fn rotation_snapshot(",
        "rotation_operation_id",
        "rotation_before_generation",
        "rotation_after_generation",
        "rotation_restore_required",
        "rotation_terminal_result",
        "rotation_restore_result",
    ):
        require_product(
            product_ffi,
            required,
            "Android must receive only typed first-class Rotation command/projection",
        )

    controller = "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt"
    debug_rotation = "android/app/src/debug/java/com/mobileproxymish/app/DebugRotationActivity.kt"
    debug_stop = "android/app/src/debug/java/com/mobileproxymish/app/DebugRuntimeStopActivity.kt"
    debug_start = "android/app/src/debug/java/com/mobileproxymish/app/DebugRuntimeStartActivity.kt"
    debug_manifest = "android/app/src/debug/AndroidManifest.xml"
    require(
        controller,
        "internal fun startPublicIpRotation(): ULong =",
        "Android may expose only a thin command facade into the Rust-owned Rotation operation",
    )
    require(
        controller,
        "productRuntime.startPublicIpRotation(",
        "Rotation command facade must delegate directly to native PRODUCT ownership",
    )
    for kotlin_path in (
        "android/app/src/main/java/com/mobileproxymish/app/MishRuntimeController.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MainViewModel.kt",
        "android/app/src/main/java/com/mobileproxymish/app/MainActivity.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt",
        "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularNetworkObserver.kt",
    ):
        for forbidden in (
            "cmd phone data",
            "svc data",
            "kotlinx.coroutines.delay",
            "Thread.sleep",
        ):
            forbid(
                kotlin_path,
                forbidden,
                "Kotlin must not regain Candidate A mutation, retry or normal-path timing ownership",
            )

    for required in (
        "class DebugRotationActivity : Activity()",
        "runCatching(runtime::startPublicIpRotation)",
        'const val TAG = "MishRotationAcceptance"',
    ):
        require(
            debug_rotation,
            required,
            "physical acceptance trigger must remain a zero-input debug-only PRODUCT command",
        )
    for required in (
        "class DebugRuntimeStopActivity : Activity()",
        "val stopped = runtime.stop()",
        'const val TAG = "MishRuntimeStopAcceptance"',
    ):
        require(
            debug_stop,
            required,
            "restore acceptance must use only the normal PRODUCT stop path",
        )
    for required in (
        "class DebugRuntimeStartActivity : Activity()",
        "ProxyRuntimeService.requestStart(this)",
        'const val TAG = "MishRuntimeStartAcceptance"',
    ):
        require(
            debug_start,
            required,
            "restore acceptance start trigger must remain a zero-input debug-only service-lifetime request",
        )
    for debug_path in (debug_rotation, debug_stop, debug_start):
        for forbidden in (
            "cmd phone data",
            "svc data",
            "cmd connectivity airplane-mode",
            "Thread.sleep",
            "SystemClock.sleep",
            "kotlinx.coroutines.delay",
        ):
            forbid(
                debug_path,
                forbidden,
                "debug acceptance trigger must never become a second Rotation/platform-effect owner",
            )
    for required in (
        'android:name=".DebugRotationActivity"',
        'android:name=".DebugRuntimeStopActivity"',
        'android:name=".DebugRuntimeStartActivity"',
    ):
        require(
            debug_manifest,
            required,
            "acceptance triggers must be packaged only by the debug source set",
        )
    for forbidden in ("DebugRotationActivity", "DebugRuntimeStopActivity", "DebugRuntimeStartActivity"):
        forbid(
            "android/app/src/main/AndroidManifest.xml",
            forbidden,
            "acceptance trigger must not leak into release PRODUCT manifest",
        )

    diagnostics = "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt"
    for forbidden in ("before_ip", "after_ip", "beforeIp", "afterIp"):
        forbid(
            diagnostics,
            forbidden,
            "raw public IP must never cross the durable/diagnostic Android boundary",
        )
    require(
        diagnostics,
        'put("raw_ip_persisted", false)',
        "Rotation diagnostics must explicitly prove raw IP is not persisted",
    )

'''


def main() -> None:
    if not LEGACY.is_file():
        raise SystemExit("architecture guard: accepted legacy checker is missing")
    source = LEGACY.read_text(encoding="utf-8")
    if source.count(START) != 1 or source.count(END) != 1:
        raise SystemExit("architecture guard: Rotation sentinel drift; refusing partial checker rewrite")
    start = source.index(START)
    end = source.index(END, start)
    if end <= start:
        raise SystemExit("architecture guard: invalid Rotation sentinel ordering")
    effective = source[:start] + CANDIDATE_A + source[end:]
    namespace = {
        "__name__": "__main__",
        "__file__": str(LEGACY),
        "__package__": None,
    }
    exec(compile(effective, str(LEGACY), "exec"), namespace, namespace)


if __name__ == "__main__":
    main()
