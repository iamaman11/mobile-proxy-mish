package com.mobileproxymish.app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import com.mobileproxymish.ffi.ProductDiagnosticSnapshotView
import java.nio.charset.StandardCharsets
import org.json.JSONObject

internal const val MISH_DIAGNOSTICS_SCHEMA_V2 = "mish.diagnostics/v2"
internal const val MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2 = "snapshot_v2"
internal const val MISH_DIAGNOSTICS_RESULT_PAYLOAD_B64 = "payload_b64"

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
    })
}.toString()

private fun JSONObject.putNullable(name: String, value: String?) {
    put(name, value ?: JSONObject.NULL)
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
        require(method == MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2) {
            "unsupported diagnostics method"
        }
        require(arg == null && (extras == null || extras.isEmpty)) {
            "diagnostics snapshot accepts no arguments"
        }
        val app = context?.applicationContext as? MishApplication
            ?: error("MishApplication is unavailable")
        val snapshot = app.runtimeController.diagnosticSnapshot()
        val json = renderMishDiagnosticSnapshotV2(
            applicationId = app.packageName,
            pid = Process.myPid(),
            capturedElapsedMs = SystemClock.elapsedRealtime(),
            snapshot = snapshot,
        )
        val encoded = Base64.encodeToString(
            json.toByteArray(StandardCharsets.UTF_8),
            Base64.NO_WRAP,
        )
        return Bundle().apply {
            putString("schema", MISH_DIAGNOSTICS_SCHEMA_V2)
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
