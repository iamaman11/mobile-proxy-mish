package com.mobileproxymish.app.cellular

import android.util.Log

/**
 * P0 recovery-attribution observation only. This is not product state and owns no retry,
 * admission, readiness, routing, or lifecycle decision.
 *
 * Values are deliberately limited to monotonic timestamps, owner sequence keys, bounded
 * durations/backoff, and typed enum outcomes. Network handles, interfaces, commands, public
 * addresses, credentials, and root output must never be emitted here.
 */
internal enum class CellularRecoveryStage {
    CELLULAR_VALIDATED,
    POLICY_EXECUTOR_STARTED,
    ROOT_EFFECT_DRAIN_COMPLETED,
    ROOT_RECONCILE_COMPLETED,
    ROOT_POLICY_AUTHORIZED,
    ROOT_AUTHORITY_BACKOFF,
}

internal enum class CellularRecoveryDetail {
    QUIESCED,
    DRAIN_FAILED,
    AUTHORIZED,
    BACKOFF_SCHEDULED,
}

internal data class CellularRecoveryObservation(
    val stage: CellularRecoveryStage,
    val ownerSequence: ULong?,
    val monotonicNanos: Long,
    val elapsedNanos: Long? = null,
    val detail: CellularRecoveryDetail? = null,
    val policyResult: CellularRootPolicyResult? = null,
    val backoffMs: Long? = null,
)

private fun RootAuthorityStatus.telemetryName(): String = when (this) {
    RootAuthorityStatus.Ready -> "READY"
    RootAuthorityStatus.InteractiveGrantRequired -> "INTERACTIVE_GRANT_REQUIRED"
    RootAuthorityStatus.Denied -> "DENIED"
    RootAuthorityStatus.Unavailable -> "UNAVAILABLE"
    RootAuthorityStatus.Incomplete -> "INCOMPLETE"
}

internal fun formatCellularRecoveryObservation(
    observation: CellularRecoveryObservation,
): String {
    val fields = mutableListOf(
        "MISH_RECOVERY_V1",
        "stage=${observation.stage.name}",
        "sequence=${observation.ownerSequence?.toString() ?: "NONE"}",
        "monotonic_ns=${observation.monotonicNanos}",
    )
    observation.elapsedNanos?.let { elapsed ->
        fields += "elapsed_ms=${elapsed.coerceAtLeast(0L) / 1_000_000L}"
    }
    observation.detail?.let { fields += "detail=${it.name}" }
    observation.policyResult?.let { result ->
        when (result) {
            CellularRootPolicyResult.Enforced -> fields += "policy_result=ENFORCED"
            is CellularRootPolicyResult.FailClosed -> {
                fields += "policy_result=FAIL_CLOSED"
                result.reason?.let { fields += "policy_reason=${it.name}" }
            }
            is CellularRootPolicyResult.AuthorityUnavailable -> {
                fields += "policy_result=AUTHORITY_UNAVAILABLE"
                fields += "authority_status=${result.status.telemetryName()}"
            }
        }
    }
    observation.backoffMs?.let { fields += "backoff_ms=${it.coerceAtLeast(0L)}" }
    return fields.joinToString(" ")
}

internal object CellularRecoveryTelemetry {
    private const val TAG = "MishRecovery"

    fun emit(
        stage: CellularRecoveryStage,
        ownerSequence: ULong?,
        elapsedNanos: Long? = null,
        detail: CellularRecoveryDetail? = null,
        policyResult: CellularRootPolicyResult? = null,
        backoffMs: Long? = null,
    ) {
        Log.i(
            TAG,
            formatCellularRecoveryObservation(
                CellularRecoveryObservation(
                    stage = stage,
                    ownerSequence = ownerSequence,
                    monotonicNanos = System.nanoTime(),
                    elapsedNanos = elapsedNanos,
                    detail = detail,
                    policyResult = policyResult,
                    backoffMs = backoffMs,
                ),
            ),
        )
    }
}
