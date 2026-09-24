package com.mobileproxymish.app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import com.mobileproxymish.ffi.ControlRuntimeSnapshotView
import com.mobileproxymish.ffi.ProductDiagnosticSnapshotView
import com.mobileproxymish.ffi.RootPolicyPhaseDiagnosticView
import java.nio.charset.StandardCharsets
import org.json.JSONObject

internal const val MISH_DIAGNOSTICS_SCHEMA_V2 = "mish.diagnostics/v2"
internal const val MISH_CONTROL_DIAGNOSTICS_SCHEMA_V1 = "mish.control.diagnostics/v1"
internal const val MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2 = "snapshot_v2"
internal const val MISH_DIAGNOSTICS_METHOD_CONTROL_SNAPSHOT_V1 = "control_snapshot_v1"
internal const val MISH_DIAGNOSTICS_RESULT_PAYLOAD_B64 = "payload_b64"

private fun renderRootPolicyPhaseDiagnostic(
    phase: RootPolicyPhaseDiagnosticView,
): JSONObject = JSONObject().apply {
    put("elapsed_ms", phase.elapsedMs.toLong())
    put("commands", phase.commands.toLong())
    put("observation_commands", phase.observationCommands.toLong())
    put("mutation_commands", phase.mutationCommands.toLong())
    put("duplicate_observations", phase.duplicateObservations.toLong())
}

/**
 * Serializes one already-composed native PRODUCT diagnostic snapshot.
 *
 * Rust owns generation fencing, consistency and all PRODUCT semantic composition. Kotlin adds only
 * Android process metadata and JSON/Base64 transport for the DUMP-gated ContentProvider boundary.
 */
internal fun renderMishDiagnosticSnapshotV2(
    applicationId: String,
    pid: Int,
    capturedElapsedMs: Long,
    snapshot: ProductDiagnosticSnapshotView,
): String = JSONObject().apply {
    put("schema", MISH_DIAGNOSTICS_SCHEMA_V2)
    put("application_id", applicationId)
    put("pid", pid)
    put("captured_elapsed_ms", capturedElapsedMs)
    put("consistent", snapshot.consistent)
    put("runtime", JSONObject().apply {
        put("running", snapshot.runtimeRunning)
        put("generation", snapshot.runtimeGeneration.toLong())
        put("active_tasks", snapshot.runtimeActiveTasks.toLong())
    })
    put("cellular", JSONObject().apply {
        put("state", snapshot.cellularState)
        put("reason", snapshot.cellularReason)
        put("admitted", snapshot.cellularAdmitted)
        put("owner_sequence", snapshot.cellularOwnerSequence?.toLong() ?: JSONObject.NULL)
        putNullable("boundary_failure", snapshot.cellularBoundaryFailure)
        put("reconcile", JSONObject().apply {
            put("requested", snapshot.cellularReconcile.requested.toLong())
            put("executed", snapshot.cellularReconcile.executed.toLong())
            put("coalesced", snapshot.cellularReconcile.coalesced.toLong())
            put("pending", snapshot.cellularReconcile.pending)
            put("drain_scheduled", snapshot.cellularReconcile.drainScheduled)
            put(
                "last_owner_sequence",
                snapshot.cellularReconcile.lastOwnerSequence?.toLong() ?: JSONObject.NULL,
            )
            put("last_dequeue_wait_ms", snapshot.cellularReconcile.lastDequeueWaitMs.toLong())
            put("max_dequeue_wait_ms", snapshot.cellularReconcile.maxDequeueWaitMs.toLong())
            put("last_quiesce_wait_ms", snapshot.cellularReconcile.lastQuiesceWaitMs.toLong())
            put("max_quiesce_wait_ms", snapshot.cellularReconcile.maxQuiesceWaitMs.toLong())
            put("stale_after_reconcile", snapshot.cellularReconcile.staleAfterReconcile.toLong())
            put(
                "superseded_during_reconcile",
                snapshot.cellularReconcile.supersededDuringReconcile.toLong(),
            )
        })
        put("dns", JSONObject().apply {
            val dns = snapshot.dns
            put("available", true)
            put("slow_threshold_ms", dns.slowThresholdMs.toLong())
            put("started", dns.started.toLong())
            put("completed", dns.completed.toLong())
            put("active", dns.active.toLong())
            put("peak_active", dns.peakActive.toLong())
            put("slow_completions", dns.slowCompletions.toLong())
            put("resolver_failed", dns.resolverFailed.toLong())
            put("discarded_after_deadline", dns.discardedAfterDeadline.toLong())
            put("completed_after_owner_change", dns.completedAfterOwnerChange.toLong())
            put("discarded_stale", dns.discardedStale.toLong())
            put("authority_validation_failed", dns.authorityValidationFailed.toLong())
            put("unusable_result", dns.unusableResult.toLong())
            put("accepted_current", dns.acceptedCurrent.toLong())
            put("max_native_elapsed_ms", dns.maxNativeElapsedMs.toLong())
            put(
                "last_started_owner_sequence",
                dns.lastStartedOwnerSequence?.toLong() ?: JSONObject.NULL,
            )
            put(
                "last_completed_start_owner_sequence",
                dns.lastCompletedStartOwnerSequence?.toLong() ?: JSONObject.NULL,
            )
            put(
                "last_completed_current_owner_sequence",
                dns.lastCompletedCurrentOwnerSequence?.toLong() ?: JSONObject.NULL,
            )
        })
    })
    put("root", JSONObject().apply {
        put("authority_observation", snapshot.rootAuthorityObservation)
        put("policy_authorized", snapshot.rootPolicyAuthorized)
        put(
            "session_generation",
            snapshot.rootSessionGeneration?.toLong() ?: JSONObject.NULL,
        )
        putNullable("last_failure_class", snapshot.rootLastFailureClass)
        put(
            "policy_authorized_generation",
            snapshot.rootPolicyAuthorizedGeneration?.toLong() ?: JSONObject.NULL,
        )
        put("reconcile", JSONObject().apply {
            val root = snapshot.rootReconcile
            put("attempts", root.attempts.toLong())
            put("total_executor_commands", root.totalExecutorCommands.toLong())
            put("total_observation_commands", root.totalObservationCommands.toLong())
            put("total_mutation_commands", root.totalMutationCommands.toLong())
            put("total_duplicate_observations", root.totalDuplicateObservations.toLong())
            put("last_reconcile_elapsed_ms", root.lastReconcileElapsedMs.toLong())
            put("max_reconcile_elapsed_ms", root.maxReconcileElapsedMs.toLong())
            put("last_policy_effect_elapsed_ms", root.lastPolicyEffectElapsedMs.toLong())
            put("max_policy_effect_elapsed_ms", root.maxPolicyEffectElapsedMs.toLong())
            put("last_executor_commands", root.lastExecutorCommands.toLong())
            put("last_observation_commands", root.lastObservationCommands.toLong())
            put("last_mutation_commands", root.lastMutationCommands.toLong())
            put("last_duplicate_observations", root.lastDuplicateObservations.toLong())
            put(
                "last_incomplete_or_timed_out_commands",
                root.lastIncompleteOrTimedOutCommands.toLong(),
            )
            put("last_mutation_failures", root.lastMutationFailures.toLong())
            put("phases", JSONObject().apply {
                val phases = root.lastPhases
                put(
                    "initial_snapshot",
                    renderRootPolicyPhaseDiagnostic(phases.initialSnapshot),
                )
                put(
                    "fail_closed_prepare",
                    renderRootPolicyPhaseDiagnostic(phases.failClosedPrepare),
                )
                put(
                    "fail_closed_verify",
                    renderRootPolicyPhaseDiagnostic(phases.failClosedVerify),
                )
                put(
                    "table_discovery",
                    renderRootPolicyPhaseDiagnostic(phases.tableDiscovery),
                )
                put(
                    "admitted_apply_verify",
                    renderRootPolicyPhaseDiagnostic(phases.admittedApplyVerify),
                )
            })
        })
        put("recovery", JSONObject().apply {
            put("pending", snapshot.rootRecovery.pending)
            put("attempts_since_reset", snapshot.rootRecovery.attemptsSinceReset.toLong())
            put("next_delay_ms", snapshot.rootRecovery.nextDelayMs.toLong())
        })
    })
    put("proxy", JSONObject().apply {
        put("state", snapshot.proxyState)
        put("healthy", snapshot.proxyHealthy)
        putNullable("failure", snapshot.proxyFailure)
        put(
            "serving_generation",
            snapshot.proxyServingGeneration?.toLong() ?: JSONObject.NULL,
        )
        put("active_sessions", snapshot.proxyActiveSessions.toLong())
        put("recovery", JSONObject().apply {
            put("pending", snapshot.proxyRecoveryPending)
            put("operation_id", snapshot.proxyRecoveryOperationId.toLong())
            put(
                "attempts_scheduled",
                snapshot.proxyRecoveryAttemptsScheduled.toLong(),
            )
            put("next_delay_ms", snapshot.proxyRecoveryNextDelayMs.toLong())
        })
    })
    put("credential", JSONObject().apply {
        put("active", snapshot.credentialActive)
        put("version", snapshot.credentialVersion?.toLong() ?: JSONObject.NULL)
    })
    put("mesh", JSONObject().apply {
        put("state", snapshot.meshState)
        put("admitted", snapshot.meshAdmitted)
        put(
            "observation_sequence",
            snapshot.meshObservationSequence?.toLong() ?: JSONObject.NULL,
        )
        put(
            "admission_epoch",
            snapshot.meshAdmissionEpoch?.toLong() ?: JSONObject.NULL,
        )
        put("epoch_present", snapshot.meshEpochPresent)
        put("ingress_running", snapshot.meshIngressRunning)
        put(
            "serving_generation",
            snapshot.meshServingGeneration?.toLong() ?: JSONObject.NULL,
        )
        put("ingress_failure", snapshot.meshIngressFailure)
        put(
            "active_sessions",
            snapshot.meshActiveSessions?.toLong() ?: JSONObject.NULL,
        )
        put(
            "capacity_rejects",
            snapshot.meshCapacityRejects?.toLong() ?: JSONObject.NULL,
        )
    })
    put("readiness", JSONObject().apply {
        put("state", snapshot.readinessState)
        put("binding_eligible", snapshot.readinessBindingEligible)
        put("binding", JSONObject().apply {
            put(
                "cellular_owner_generation",
                snapshot.readinessBindingCellularOwnerGeneration?.toLong() ?: JSONObject.NULL,
            )
            put(
                "runtime_generation",
                snapshot.readinessBindingRuntimeGeneration?.toLong() ?: JSONObject.NULL,
            )
            put(
                "proxy_serving_generation",
                snapshot.readinessBindingProxyServingGeneration?.toLong() ?: JSONObject.NULL,
            )
            put(
                "mesh_admission_epoch",
                snapshot.readinessBindingMeshAdmissionEpoch?.toLong() ?: JSONObject.NULL,
            )
            put(
                "credential_version",
                snapshot.readinessBindingCredentialVersion?.toLong() ?: JSONObject.NULL,
            )
        })
        put(
            "expected_freshness",
            snapshot.readinessExpectedFreshness?.toLong() ?: JSONObject.NULL,
        )
        put(
            "observed_freshness",
            snapshot.readinessObservedFreshness?.toLong() ?: JSONObject.NULL,
        )
        put("probe_in_flight", snapshot.readinessProbeInFlight)
        put("refresh_pending", snapshot.readinessRefreshPending)
        put("probe_state", snapshot.readinessProbeState)
    })
    put("rotation", JSONObject().apply {
        put("state", snapshot.rotationState)
        put("operation_id", snapshot.rotationOperationId?.toLong() ?: JSONObject.NULL)
        put(
            "before_generation",
            snapshot.rotationBeforeGeneration?.toLong() ?: JSONObject.NULL,
        )
        put(
            "after_generation",
            snapshot.rotationAfterGeneration?.toLong() ?: JSONObject.NULL,
        )
        put("restore_required", snapshot.rotationRestoreRequired)
        putNullable("terminal_result", snapshot.rotationTerminalResult)
        putNullable("failure", snapshot.rotationFailure)
        putNullable("restore_result", snapshot.rotationRestoreResult)
        put("active_tasks", snapshot.rotationActiveTasks.toLong())
        put("raw_ip_persisted", false)
    })
}.toString()

internal fun renderMishControlDiagnosticSnapshotV1(
    applicationId: String,
    pid: Int,
    capturedElapsedMs: Long,
    snapshot: ControlRuntimeSnapshotView,
): String = JSONObject().apply {
    put("schema", MISH_CONTROL_DIAGNOSTICS_SCHEMA_V1)
    put("application_id", applicationId)
    put("pid", pid)
    put("captured_elapsed_ms", capturedElapsedMs)
    put("control", JSONObject().apply {
        put("state", snapshot.state.name)
        put("reconnect_attempts", snapshot.reconnectAttempts.toLong())
        put("reconnect_count", snapshot.reconnectCount.toLong())
        put("next_delay_ms", snapshot.nextDelayMs.toLong())
        put("session_age_ms", snapshot.sessionAgeMs?.toLong() ?: JSONObject.NULL)
        put("application_heartbeat_count", snapshot.applicationHeartbeatCount.toLong())
        put("payload_tx_bytes", snapshot.payloadTxBytes.toLong())
        put("payload_rx_bytes", snapshot.payloadRxBytes.toLong())
        put("last_tx_age_ms", snapshot.lastTxAgeMs?.toLong() ?: JSONObject.NULL)
        put("last_rx_age_ms", snapshot.lastRxAgeMs?.toLong() ?: JSONObject.NULL)
        put("pending_operation", snapshot.pendingOperation)
        put(
            "pending_operation_id",
            snapshot.pendingOperationId?.toLong() ?: JSONObject.NULL,
        )
        put(
            "last_terminal_result",
            snapshot.lastTerminalResult?.name ?: JSONObject.NULL,
        )
        put("operation_timing", JSONObject().apply {
            put("origin", "REMOTE_COMMAND_RECEIVED")
            put("operation_id", snapshot.operationTiming.operationId?.toLong() ?: JSONObject.NULL)
            put("operation_age_ms", snapshot.operationTiming.operationAgeMs?.toLong() ?: JSONObject.NULL)
            put(
                "operation_reserved_ms",
                snapshot.operationTiming.operationReservedMs?.toLong() ?: JSONObject.NULL,
            )
            put(
                "accepted_sent_ms",
                snapshot.operationTiming.acceptedSentMs?.toLong() ?: JSONObject.NULL,
            )
            put(
                "reconnect_started_ms",
                snapshot.operationTiming.reconnectStartedMs?.toLong() ?: JSONObject.NULL,
            )
            put(
                "reconnect_ready_ms",
                snapshot.operationTiming.reconnectReadyMs?.toLong() ?: JSONObject.NULL,
            )
            put(
                "rotation_terminal_ms",
                snapshot.operationTiming.rotationTerminalMs?.toLong() ?: JSONObject.NULL,
            )
            put(
                "result_sent_ms",
                snapshot.operationTiming.resultSentMs?.toLong() ?: JSONObject.NULL,
            )
            put(
                "result_ack_ms",
                snapshot.operationTiming.resultAckMs?.toLong() ?: JSONObject.NULL,
            )
            put(
                "rotation_origin_from_command_ms",
                snapshot.operationTiming.rotationOriginFromCommandMs?.toLong() ?: JSONObject.NULL,
            )
            put("rotation", JSONObject().apply {
                put("operation_id", snapshot.rotationTiming.operationId?.toLong() ?: JSONObject.NULL)
                put(
                    "operation_age_ms",
                    snapshot.rotationTiming.operationAgeMs?.toLong() ?: JSONObject.NULL,
                )
                putNullableLong("activated_ms", snapshot.rotationTiming.activatedMs)
                putNullableLong("pre_rotation_probe_started_ms", snapshot.rotationTiming.preRotationProbeStartedMs)
                putNullableLong("pre_rotation_probe_completed_ms", snapshot.rotationTiming.preRotationProbeCompletedMs)
                putNullableLong(
                    "airplane_enable_started_ms",
                    snapshot.rotationTiming.airplaneEnableStartedMs,
                )
                putNullableLong(
                    "airplane_enable_effect_completed_ms",
                    snapshot.rotationTiming.airplaneEnableEffectCompletedMs,
                )
                putNullableLong(
                    "airplane_on_observed_ms",
                    snapshot.rotationTiming.airplaneOnObservedMs,
                )
                putNullableLong(
                    "cellular_loss_observed_ms",
                    snapshot.rotationTiming.cellularLossObservedMs,
                )
                putNullableLong(
                    "airplane_disable_started_ms",
                    snapshot.rotationTiming.airplaneDisableStartedMs,
                )
                putNullableLong(
                    "airplane_disable_effect_completed_ms",
                    snapshot.rotationTiming.airplaneDisableEffectCompletedMs,
                )
                putNullableLong(
                    "airplane_off_observed_ms",
                    snapshot.rotationTiming.airplaneOffObservedMs,
                )
                putNullableLong(
                    "cellular_request_rearm_started_ms",
                    snapshot.rotationTiming.cellularRequestRearmStartedMs,
                )
                putNullableLong(
                    "cellular_request_rearm_completed_ms",
                    snapshot.rotationTiming.cellularRequestRearmCompletedMs,
                )
                putNullableLong(
                    "first_platform_cellular_observation_ms",
                    snapshot.rotationTiming.firstPlatformCellularObservationMs,
                )
                put(
                    "platform_cellular_observations_after_rearm",
                    snapshot.rotationTiming.platformCellularObservationsAfterRearm.toLong(),
                )
                putNullableLong(
                    "fresh_cellular_observed_ms",
                    snapshot.rotationTiming.freshCellularObservedMs,
                )
                putNullableLong(
                    "fresh_cellular_generation",
                    snapshot.rotationTiming.freshCellularGeneration,
                )
                putNullableLong("root_authorized_ms", snapshot.rotationTiming.rootAuthorizedMs)
                putNullableLong(
                    "root_authorized_generation",
                    snapshot.rotationTiming.rootAuthorizedGeneration,
                )
                putNullableLong("post_rotation_probe_started_ms", snapshot.rotationTiming.postRotationProbeStartedMs)
                putNullableLong("post_rotation_probe_completed_ms", snapshot.rotationTiming.postRotationProbeCompletedMs)
                putNullableLong("terminal_ms", snapshot.rotationTiming.terminalMs)
                putNullableLong(
                    "restore_completed_ms",
                    snapshot.rotationTiming.restoreCompletedMs,
                )
            })
        })
    })
}.toString()

private fun JSONObject.putNullable(name: String, value: String?) {
    put(name, value ?: JSONObject.NULL)
}

private fun JSONObject.putNullableLong(name: String, value: ULong?) {
    put(name, value?.toLong() ?: JSONObject.NULL)
}

/**
 * Permission-gated ADB diagnostics bridge available in every APK variant.
 *
 * This provider is strictly read-only. It executes no root command, retry/recovery action, network
 * toggle, credential mutation or provider mutation. The manifest protects it with DUMP permission.
 */
class MishDiagnosticsProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        require(
            method == MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2 ||
                method == MISH_DIAGNOSTICS_METHOD_CONTROL_SNAPSHOT_V1,
        ) {
            "unsupported diagnostics method"
        }
        require(arg == null && (extras == null || extras.isEmpty)) {
            "diagnostics snapshot accepts no arguments"
        }
        val app = context?.applicationContext as? MishApplication
            ?: error("MishApplication is unavailable")
        val capturedElapsedMs = SystemClock.elapsedRealtime()
        val (schema, json) = when (method) {
            MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2 -> {
                val snapshot = app.runtimeController.diagnosticSnapshot()
                MISH_DIAGNOSTICS_SCHEMA_V2 to renderMishDiagnosticSnapshotV2(
                    applicationId = app.packageName,
                    pid = Process.myPid(),
                    capturedElapsedMs = capturedElapsedMs,
                    snapshot = snapshot,
                )
            }
            MISH_DIAGNOSTICS_METHOD_CONTROL_SNAPSHOT_V1 -> {
                val snapshot = app.runtimeController.controlSnapshot()
                MISH_CONTROL_DIAGNOSTICS_SCHEMA_V1 to renderMishControlDiagnosticSnapshotV1(
                    applicationId = app.packageName,
                    pid = Process.myPid(),
                    capturedElapsedMs = capturedElapsedMs,
                    snapshot = snapshot,
                )
            }
            else -> error("unsupported diagnostics method")
        }
        val encoded = Base64.encodeToString(
            json.toByteArray(StandardCharsets.UTF_8),
            Base64.NO_WRAP,
        )
        return Bundle().apply {
            putString("schema", schema)
            putString(MISH_DIAGNOSTICS_RESULT_PAYLOAD_B64, encoded)
        }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String = "application/json"

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("diagnostics provider is read-only")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("diagnostics provider is read-only")

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException("diagnostics provider is read-only")
}
