package com.mobileproxymish.app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.BaseBundle
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.util.Base64
import com.mobileproxymish.app.cellular.CellularBoundaryFailure
import com.mobileproxymish.app.cellular.CellularRootPolicyReconcileDiagnostic
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularDnsDiagnosticView
import com.mobileproxymish.ffi.ProductReadinessState
import java.nio.charset.StandardCharsets
import org.json.JSONObject

internal const val MISH_DIAGNOSTICS_SCHEMA_V2 = "mish.diagnostics/v2"
internal const val MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V2 = "snapshot_v2"
internal const val MISH_DIAGNOSTICS_RESULT_PAYLOAD_B64 = "payload_b64"

/** Stable semantic diagnostics for the native L8 product topology. */
internal data class MishDiagnosticFactsV2(
    val applicationId: String,
    val pid: Int,
    val capturedElapsedMs: Long,
    val consistent: Boolean,
    val runtimeRunning: Boolean,
    val cellularState: String,
    val cellularReason: String,
    val cellularAdmitted: Boolean,
    val cellularBoundaryFailure: String?,
    val cellularReconcileRequested: Long,
    val cellularReconcileExecuted: Long,
    val cellularReconcileCoalesced: Long,
    val cellularReconcilePending: Boolean,
    val cellularReconcileDrainScheduled: Boolean,
    val dnsObservation: CellularDnsDiagnosticView?,
    val rootAuthorityObservation: String,
    val rootPolicyAuthorized: Boolean,
    val rootReconcile: CellularRootPolicyReconcileDiagnostic,
    val proxyState: String,
    val proxyHealthy: Boolean,
    val proxyFailure: String?,
    val proxyActiveSessions: UInt?,
    val credentialActive: Boolean,
    val meshState: String,
    val meshAdmitted: Boolean,
    val meshEpochPresent: Boolean,
    val meshIngressRunning: Boolean,
    val meshIngressFailure: String,
    val meshActiveSessions: ULong?,
    val readinessState: String,
    val readinessBindingEligible: Boolean,
    val readinessProbeState: String,
)

internal fun renderMishDiagnosticSnapshotV2(facts: MishDiagnosticFactsV2): String =
    JSONObject().apply {
        put("schema", MISH_DIAGNOSTICS_SCHEMA_V2)
        put("application_id", facts.applicationId)
        put("pid", facts.pid)
        put("captured_elapsed_ms", facts.capturedElapsedMs)
        put("consistent", facts.consistent)
        put("runtime", JSONObject().apply {
            put("running", facts.runtimeRunning)
        })
        put("cellular", JSONObject().apply {
            put("state", facts.cellularState)
            put("reason", facts.cellularReason)
            put("admitted", facts.cellularAdmitted)
            putNullable("boundary_failure", facts.cellularBoundaryFailure)
            put("reconcile", JSONObject().apply {
                put("requested", facts.cellularReconcileRequested)
                put("executed", facts.cellularReconcileExecuted)
                put("coalesced", facts.cellularReconcileCoalesced)
                put("pending", facts.cellularReconcilePending)
                put("drain_scheduled", facts.cellularReconcileDrainScheduled)
            })
            put("dns", JSONObject().apply {
                val dns = facts.dnsObservation
                put("available", dns != null)
                put("slow_threshold_ms", dns?.slowThresholdMs?.toLong() ?: JSONObject.NULL)
                put("started", dns?.started?.toLong() ?: JSONObject.NULL)
                put("completed", dns?.completed?.toLong() ?: JSONObject.NULL)
                put("active", dns?.active?.toLong() ?: JSONObject.NULL)
                put("peak_active", dns?.peakActive?.toLong() ?: JSONObject.NULL)
                put("slow_completions", dns?.slowCompletions?.toLong() ?: JSONObject.NULL)
                put("resolver_failed", dns?.resolverFailed?.toLong() ?: JSONObject.NULL)
                put(
                    "discarded_after_deadline",
                    dns?.discardedAfterDeadline?.toLong() ?: JSONObject.NULL,
                )
                put(
                    "completed_after_owner_change",
                    dns?.completedAfterOwnerChange?.toLong() ?: JSONObject.NULL,
                )
                put("discarded_stale", dns?.discardedStale?.toLong() ?: JSONObject.NULL)
                put(
                    "authority_validation_failed",
                    dns?.authorityValidationFailed?.toLong() ?: JSONObject.NULL,
                )
                put("unusable_result", dns?.unusableResult?.toLong() ?: JSONObject.NULL)
                put("accepted_current", dns?.acceptedCurrent?.toLong() ?: JSONObject.NULL)
                put(
                    "max_native_elapsed_ms",
                    dns?.maxNativeElapsedMs?.toLong() ?: JSONObject.NULL,
                )
                put(
                    "last_started_owner_sequence",
                    dns?.lastStartedOwnerSequence?.toLong() ?: JSONObject.NULL,
                )
                put(
                    "last_completed_start_owner_sequence",
                    dns?.lastCompletedStartOwnerSequence?.toLong() ?: JSONObject.NULL,
                )
                put(
                    "last_completed_current_owner_sequence",
                    dns?.lastCompletedCurrentOwnerSequence?.toLong() ?: JSONObject.NULL,
                )
            })
        })
        put("root", JSONObject().apply {
            put("authority_observation", facts.rootAuthorityObservation)
            put("policy_authorized", facts.rootPolicyAuthorized)
            put("reconcile", JSONObject().apply {
                put("attempts", facts.rootReconcile.attempts)
                put("total_executor_commands", facts.rootReconcile.totalExecutorCommands)
                put("total_observation_commands", facts.rootReconcile.totalObservationCommands)
                put("total_mutation_commands", facts.rootReconcile.totalMutationCommands)
                put(
                    "total_duplicate_observations",
                    facts.rootReconcile.totalDuplicateObservations,
                )
                put("last_reconcile_elapsed_ms", facts.rootReconcile.lastReconcileElapsedMs)
                put("max_reconcile_elapsed_ms", facts.rootReconcile.maxReconcileElapsedMs)
                put(
                    "last_policy_effect_elapsed_ms",
                    facts.rootReconcile.lastPolicyEffectElapsedMs,
                )
                put(
                    "max_policy_effect_elapsed_ms",
                    facts.rootReconcile.maxPolicyEffectElapsedMs,
                )
                put("last_executor_commands", facts.rootReconcile.lastExecutorCommands)
                put("last_observation_commands", facts.rootReconcile.lastObservationCommands)
                put("last_mutation_commands", facts.rootReconcile.lastMutationCommands)
                put(
                    "last_duplicate_observations",
                    facts.rootReconcile.lastDuplicateObservations,
                )
                put(
                    "last_incomplete_or_timed_out_commands",
                    facts.rootReconcile.lastIncompleteOrTimedOutCommands,
                )
                put("last_mutation_failures", facts.rootReconcile.lastMutationFailures)
            })
        })
        put("proxy", JSONObject().apply {
            put("state", facts.proxyState)
            put("healthy", facts.proxyHealthy)
            putNullable("failure", facts.proxyFailure)
            put("active_sessions", facts.proxyActiveSessions?.toLong() ?: JSONObject.NULL)
        })
        put("credential", JSONObject().apply {
            put("active", facts.credentialActive)
        })
        put("mesh", JSONObject().apply {
            put("state", facts.meshState)
            put("admitted", facts.meshAdmitted)
            put("epoch_present", facts.meshEpochPresent)
            put("ingress_running", facts.meshIngressRunning)
            put("ingress_failure", facts.meshIngressFailure)
            put("active_sessions", facts.meshActiveSessions?.toLong() ?: JSONObject.NULL)
        })
        put("readiness", JSONObject().apply {
            put("state", facts.readinessState)
            put("binding_eligible", facts.readinessBindingEligible)
            put("probe_state", facts.readinessProbeState)
        })
        put("rotation", JSONObject().apply {
            put("state", "NOT_SUPPORTED")
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
        val json = captureSnapshot(app)
        val encoded = Base64.encodeToString(
            json.toByteArray(StandardCharsets.UTF_8),
            Base64.NO_WRAP,
        )
        return Bundle().apply {
            putString("schema", MISH_DIAGNOSTICS_SCHEMA_V2)
            putString(MISH_DIAGNOSTICS_RESULT_PAYLOAD_B64, encoded)
        }
    }

    private fun captureSnapshot(app: MishApplication): String {
        val runtime = app.runtimeController

        // Capture exact generation object identities before reading projections. Every runtime
        // replacement installs fresh adapter objects, so identity equality is a cheap generation
        // fence without introducing a second lifecycle/generation owner into diagnostics.
        val cellularGeneration = runtime.currentCellularRuntime
        val proxyGeneration = runtime.currentProxyRuntime
        val readinessGeneration = runtime.currentReadinessRuntime
        val meshGeneration = runtime.currentMeshRuntime
        val runtimeRunningBefore = runtime.isRunning

        val cellularBefore = runtime.cellularSnapshot.value
        val cellularReconcileBefore = cellularGeneration.reconcileDiagnosticObservation()
        val rootReconcileBefore = cellularGeneration.rootPolicyReconcileDiagnosticObservation()
        val dnsBefore = cellularGeneration.dnsDiagnosticObservation()
        val proxyBefore = runtime.proxySnapshot.value
        val readinessBefore = runtime.readinessSnapshot.value
        val meshBefore = runtime.meshSnapshot.value

        val readinessDiagnostic = readinessGeneration.diagnosticObservation()
        val proxyDiagnostic = proxyGeneration.diagnosticObservation()
        val meshIngressFailure = meshGeneration.diagnosticIngressFailure().name
        val meshActiveSessions = meshGeneration.diagnosticActiveSessions()

        val cellularAfter = runtime.cellularSnapshot.value
        val cellularReconcileAfter = cellularGeneration.reconcileDiagnosticObservation()
        val rootReconcileAfter = cellularGeneration.rootPolicyReconcileDiagnosticObservation()
        val dnsAfter = cellularGeneration.dnsDiagnosticObservation()
        val proxyAfter = runtime.proxySnapshot.value
        val readinessAfter = runtime.readinessSnapshot.value
        val meshAfter = runtime.meshSnapshot.value
        val runtimeRunningAfter = runtime.isRunning

        val sameGeneration = cellularGeneration === runtime.currentCellularRuntime &&
            proxyGeneration === runtime.currentProxyRuntime &&
            readinessGeneration === runtime.currentReadinessRuntime &&
            meshGeneration === runtime.currentMeshRuntime
        val consistent = sameGeneration &&
            runtimeRunningBefore == runtimeRunningAfter &&
            cellularBefore == cellularAfter &&
            cellularReconcileBefore == cellularReconcileAfter &&
            rootReconcileBefore == rootReconcileAfter &&
            dnsBefore == dnsAfter &&
            proxyBefore == proxyAfter &&
            readinessBefore == readinessAfter &&
            meshBefore == meshAfter

        val ownerAdmission = (cellularAfter as? CellularRuntimeSnapshot.OwnerSnapshot)?.admission
        val boundaryFailure = (cellularAfter as? CellularRuntimeSnapshot.BoundaryUnavailable)?.reason
        val cellularState = ownerAdmission?.state?.name ?: "BOUNDARY_UNAVAILABLE"
        val cellularReason = ownerAdmission?.reason?.name ?: "NONE"
        val cellularAdmitted = ownerAdmission?.state == CellularAdmissionState.ADMITTED
        val proxyFailure = (proxyAfter as? ProxyRuntimeSnapshot.Failed)?.reason?.name
        val proxyState = when (proxyAfter) {
            ProxyRuntimeSnapshot.Stopped -> "STOPPED"
            ProxyRuntimeSnapshot.Starting -> "STARTING"
            ProxyRuntimeSnapshot.Running -> "RUNNING"
            is ProxyRuntimeSnapshot.Failed -> "FAILED"
        }
        val rootAuthorityObservation = when {
            boundaryFailure == CellularBoundaryFailure.RootAuthorityUnavailable -> "UNAVAILABLE"
            readinessDiagnostic.rootPolicyVerified -> "READY_AT_POLICY_AUTHORIZATION"
            else -> "NOT_OBSERVED"
        }
        val meshState = meshAfter?.state?.name ?: "ABSENT"
        val readinessProbeState = when (readinessAfter) {
            ProductReadinessState.READY -> "SUCCEEDED"
            ProductReadinessState.DEGRADED -> "FAILED"
            ProductReadinessState.NOT_READY -> "BLOCKED"
            ProductReadinessState.UNKNOWN -> "NOT_OBSERVED"
        }

        return renderMishDiagnosticSnapshotV2(
            MishDiagnosticFactsV2(
                applicationId = app.packageName,
                pid = Process.myPid(),
                capturedElapsedMs = SystemClock.elapsedRealtime(),
                consistent = consistent,
                runtimeRunning = runtimeRunningAfter,
                cellularState = cellularState,
                cellularReason = cellularReason,
                cellularAdmitted = cellularAdmitted,
                cellularBoundaryFailure = boundaryFailure?.diagnosticCode(),
                cellularReconcileRequested = cellularReconcileAfter.requested,
                cellularReconcileExecuted = cellularReconcileAfter.executed,
                cellularReconcileCoalesced = cellularReconcileAfter.coalesced,
                cellularReconcilePending = cellularReconcileAfter.pending,
                cellularReconcileDrainScheduled = cellularReconcileAfter.drainScheduled,
                dnsObservation = dnsAfter,
                rootAuthorityObservation = rootAuthorityObservation,
                rootPolicyAuthorized = readinessDiagnostic.rootPolicyVerified,
                rootReconcile = rootReconcileAfter,
                proxyState = proxyState,
                proxyHealthy = readinessDiagnostic.proxyHealthy,
                proxyFailure = proxyFailure,
                proxyActiveSessions = proxyDiagnostic.activeSessions,
                credentialActive = readinessDiagnostic.credentialActive,
                meshState = meshState,
                meshAdmitted = readinessDiagnostic.meshAdmitted,
                meshEpochPresent = meshAfter?.admissionEpoch != null,
                meshIngressRunning = meshAfter?.ingressRunning == true,
                meshIngressFailure = meshIngressFailure,
                meshActiveSessions = meshActiveSessions,
                readinessState = readinessAfter.name,
                readinessBindingEligible = readinessDiagnostic.bindingEligible,
                readinessProbeState = readinessProbeState,
            ),
        )
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

private fun CellularBoundaryFailure.diagnosticCode(): String = when (this) {
    CellularBoundaryFailure.NativeLibraryUnavailable -> "NATIVE_LIBRARY_UNAVAILABLE"
    CellularBoundaryFailure.ForeignCallFailed -> "FOREIGN_CALL_FAILED"
    CellularBoundaryFailure.RootAuthorityUnavailable -> "ROOT_AUTHORITY_UNAVAILABLE"
    CellularBoundaryFailure.RootPolicyReconcileFailed -> "ROOT_POLICY_RECONCILE_FAILED"
    CellularBoundaryFailure.RootPolicyGenerationChanged -> "ROOT_POLICY_GENERATION_CHANGED"
    CellularBoundaryFailure.RootPolicyCleanupFailed -> "ROOT_POLICY_CLEANUP_FAILED"
    is CellularBoundaryFailure.RootPolicyUnavailable -> "ROOT_POLICY_${failure.name.uppercase()}"
}