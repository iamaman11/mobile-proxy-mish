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
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.ProductReadinessState
import java.nio.charset.StandardCharsets
import org.json.JSONObject

internal const val MISH_DIAGNOSTICS_SCHEMA_V1 = "mish.diagnostics/v1"
internal const val MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V1 = "snapshot_v1"
internal const val MISH_DIAGNOSTICS_RESULT_PAYLOAD_B64 = "payload_b64"

/**
 * Stable semantic diagnostics payload. These fields intentionally describe product facts rather
 * than Kotlin/Rust implementation class names so the ADB/LAB bridge can survive internal rewrites.
 */
internal data class MishDiagnosticFactsV1(
    val applicationId: String,
    val pid: Int,
    val capturedElapsedMs: Long,
    val consistent: Boolean,
    val runtimeRunning: Boolean,
    val cellularState: String,
    val cellularReason: String,
    val cellularAdmitted: Boolean,
    val cellularBoundaryFailure: String?,
    val rootAuthorityObservation: String,
    val rootPolicyAuthorized: Boolean,
    val privateBridgeHealthy: Boolean,
    val proxyState: String,
    val proxyHealthy: Boolean,
    val proxyFailure: String?,
    val credentialActive: Boolean,
    val meshState: String,
    val meshAdmitted: Boolean,
    val meshEpochPresent: Boolean,
    val meshIngressRunning: Boolean,
    val meshIngressFailure: String,
    val readinessState: String,
    val readinessBindingEligible: Boolean,
    val readinessProbeState: String,
)

internal fun renderMishDiagnosticSnapshotV1(facts: MishDiagnosticFactsV1): String =
    JSONObject().apply {
        put("schema", MISH_DIAGNOSTICS_SCHEMA_V1)
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
        })
        put("root", JSONObject().apply {
            put("authority_observation", facts.rootAuthorityObservation)
            put("policy_authorized", facts.rootPolicyAuthorized)
        })
        put("bridge", JSONObject().apply {
            put("private_healthy", facts.privateBridgeHealthy)
        })
        put("proxy", JSONObject().apply {
            put("state", facts.proxyState)
            put("healthy", facts.proxyHealthy)
            putNullable("failure", facts.proxyFailure)
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
        })
        put("readiness", JSONObject().apply {
            put("state", facts.readinessState)
            put("binding_eligible", facts.readinessBindingEligible)
            // V1 deliberately does not duplicate the readiness probe implementation. The LAB
            // collector runs an independent authenticated loopback probe for detailed attribution.
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
 * This provider is strictly read-only. It executes no root command, no retry/recovery action,
 * no network toggle, no credential mutation and no provider mutation. The manifest protects it
 * with the platform `android.permission.DUMP` permission, which is available to ADB shell but not
 * ordinary third-party applications.
 */
class MishDiagnosticsProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        require(method == MISH_DIAGNOSTICS_METHOD_SNAPSHOT_V1) {
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
            putString("schema", MISH_DIAGNOSTICS_SCHEMA_V1)
            putString(MISH_DIAGNOSTICS_RESULT_PAYLOAD_B64, encoded)
        }
    }

    private fun captureSnapshot(app: MishApplication): String {
        val runtime = app.runtimeController

        val cellularBefore = runtime.cellularSnapshot.value
        val proxyBefore = runtime.proxySnapshot.value
        val readinessBefore = runtime.readinessSnapshot.value
        val meshBefore = runtime.meshSnapshot.value

        val readinessDiagnostic = runtime.currentReadinessRuntime.diagnosticObservation()
        val meshIngressFailure = runtime.currentMeshRuntime.diagnosticIngressFailure().name

        val cellularAfter = runtime.cellularSnapshot.value
        val proxyAfter = runtime.proxySnapshot.value
        val readinessAfter = runtime.readinessSnapshot.value
        val meshAfter = runtime.meshSnapshot.value

        val consistent = cellularBefore == cellularAfter &&
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

        return renderMishDiagnosticSnapshotV1(
            MishDiagnosticFactsV1(
                applicationId = app.packageName,
                pid = Process.myPid(),
                capturedElapsedMs = SystemClock.elapsedRealtime(),
                consistent = consistent,
                runtimeRunning = runtime.isRunning,
                cellularState = cellularState,
                cellularReason = cellularReason,
                cellularAdmitted = cellularAdmitted,
                cellularBoundaryFailure = boundaryFailure?.diagnosticCode(),
                rootAuthorityObservation = rootAuthorityObservation,
                rootPolicyAuthorized = readinessDiagnostic.rootPolicyVerified,
                privateBridgeHealthy = readinessDiagnostic.privateBridgeHealthy,
                proxyState = proxyState,
                proxyHealthy = readinessDiagnostic.proxyHealthy,
                proxyFailure = proxyFailure,
                credentialActive = readinessDiagnostic.credentialActive,
                meshState = meshState,
                meshAdmitted = readinessDiagnostic.meshAdmitted,
                meshEpochPresent = meshAfter?.admissionEpoch != null,
                meshIngressRunning = meshAfter?.ingressRunning == true,
                meshIngressFailure = meshIngressFailure,
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
