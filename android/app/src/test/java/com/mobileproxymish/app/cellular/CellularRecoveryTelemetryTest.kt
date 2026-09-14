package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class CellularRecoveryTelemetryTest {
    @Test
    fun formatsBoundedMonotonicObservation() {
        val line = formatCellularRecoveryObservation(
            CellularRecoveryObservation(
                stage = CellularRecoveryStage.ROOT_EFFECT_DRAIN_COMPLETED,
                ownerSequence = 17UL,
                monotonicNanos = 123_456_789L,
                elapsedNanos = 42_900_000L,
                detail = CellularRecoveryDetail.QUIESCED,
            ),
        )

        assertEquals(
            "MISH_RECOVERY_V1 stage=ROOT_EFFECT_DRAIN_COMPLETED sequence=17 " +
                "monotonic_ns=123456789 elapsed_ms=42 detail=QUIESCED",
            line,
        )
        assertFalse(line.contains("rmnet"))
        assertFalse(line.contains("su -c"))
    }

    @Test
    fun formatsTypedPolicyOutcomeWithoutCommandOrNetworkData() {
        val line = formatCellularRecoveryObservation(
            CellularRecoveryObservation(
                stage = CellularRecoveryStage.ROOT_RECONCILE_COMPLETED,
                ownerSequence = 21UL,
                monotonicNanos = 987_654_321L,
                elapsedNanos = 1_234_000_000L,
                policyResult = CellularRootPolicyResult.FailClosed(
                    CellularRootPolicyFailure.RouteTableDiscoveryFailed,
                ),
            ),
        )

        assertEquals(
            "MISH_RECOVERY_V1 stage=ROOT_RECONCILE_COMPLETED sequence=21 " +
                "monotonic_ns=987654321 elapsed_ms=1234 policy_result=FAIL_CLOSED " +
                "policy_reason=RouteTableDiscoveryFailed",
            line,
        )
    }

    @Test
    fun formatsTypedRootAuthorityStatus() {
        val line = formatCellularRecoveryObservation(
            CellularRecoveryObservation(
                stage = CellularRecoveryStage.ROOT_RECONCILE_COMPLETED,
                ownerSequence = 22UL,
                monotonicNanos = 987_654_322L,
                policyResult = CellularRootPolicyResult.AuthorityUnavailable(
                    RootAuthorityStatus.InteractiveGrantRequired,
                ),
            ),
        )

        assertEquals(
            "MISH_RECOVERY_V1 stage=ROOT_RECONCILE_COMPLETED sequence=22 " +
                "monotonic_ns=987654322 policy_result=AUTHORITY_UNAVAILABLE " +
                "authority_status=INTERACTIVE_GRANT_REQUIRED",
            line,
        )
    }

    @Test
    fun formatsBoundedRootAuthorityBackoff() {
        val line = formatCellularRecoveryObservation(
            CellularRecoveryObservation(
                stage = CellularRecoveryStage.ROOT_AUTHORITY_BACKOFF,
                ownerSequence = 33UL,
                monotonicNanos = 555L,
                detail = CellularRecoveryDetail.BACKOFF_SCHEDULED,
                backoffMs = 5_000L,
            ),
        )

        assertEquals(
            "MISH_RECOVERY_V1 stage=ROOT_AUTHORITY_BACKOFF sequence=33 monotonic_ns=555 " +
                "detail=BACKOFF_SCHEDULED backoff_ms=5000",
            line,
        )
    }

    @Test
    fun formatsDownstreamServingStagesWithoutSensitiveNetworkData() {
        val line = formatCellularRecoveryObservation(
            CellularRecoveryObservation(
                stage = CellularRecoveryStage.MESH_INGRESS_RUNNING,
                ownerSequence = null,
                monotonicNanos = 777L,
                detail = CellularRecoveryDetail.INGRESS_RUNNING,
            ),
        )

        assertEquals(
            "MISH_RECOVERY_V1 stage=MESH_INGRESS_RUNNING sequence=NONE monotonic_ns=777 " +
                "detail=INGRESS_RUNNING",
            line,
        )
        assertFalse(line.contains("100.96."))
        assertFalse(line.contains("1080"))
    }
}
