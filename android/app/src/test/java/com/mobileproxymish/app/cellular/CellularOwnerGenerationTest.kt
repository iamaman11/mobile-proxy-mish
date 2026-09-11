package com.mobileproxymish.app.cellular

import com.mobileproxymish.ffi.CellularAdmissionReason
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CellularOwnerGenerationTest {
    @Test
    fun exactOwnerGenerationMatches() {
        val expected = admitted(sequence = 7uL, handle = 42uL)

        assertTrue(
            sameCellularOwnerGeneration(
                expected = expected,
                current = admitted(sequence = 7uL, handle = 42uL),
            ),
        )
    }

    @Test
    fun newerSequenceRejectsStaleInfrastructureEffect() {
        assertFalse(
            sameCellularOwnerGeneration(
                expected = admitted(sequence = 7uL, handle = 42uL),
                current = admitted(sequence = 8uL, handle = 42uL),
            ),
        )
    }

    @Test
    fun changedHandleRejectsStaleInfrastructureEffect() {
        assertFalse(
            sameCellularOwnerGeneration(
                expected = admitted(sequence = 7uL, handle = 42uL),
                current = admitted(sequence = 7uL, handle = 43uL),
            ),
        )
    }

    @Test
    fun ownerLossRejectsPreviouslyAdmittedGeneration() {
        assertFalse(
            sameCellularOwnerGeneration(
                expected = admitted(sequence = 7uL, handle = 42uL),
                current = CellularAdmissionView(
                    state = CellularAdmissionState.NOT_ADMITTED,
                    reason = CellularAdmissionReason.NETWORK_LOST,
                    admittedNetworkHandle = null,
                    lastSequence = 8uL,
                ),
            ),
        )
    }

    @Test
    fun missingSequenceCanNeverAuthorizeInfrastructureEffect() {
        assertFalse(
            sameCellularOwnerGeneration(
                expected = CellularAdmissionView(
                    state = CellularAdmissionState.UNKNOWN,
                    reason = CellularAdmissionReason.NO_OBSERVATION,
                    admittedNetworkHandle = null,
                    lastSequence = null,
                ),
                current = CellularAdmissionView(
                    state = CellularAdmissionState.UNKNOWN,
                    reason = CellularAdmissionReason.NO_OBSERVATION,
                    admittedNetworkHandle = null,
                    lastSequence = null,
                ),
            ),
        )
    }

    private fun admitted(sequence: ULong, handle: ULong): CellularAdmissionView =
        CellularAdmissionView(
            state = CellularAdmissionState.ADMITTED,
            reason = null,
            admittedNetworkHandle = handle,
            lastSequence = sequence,
        )
}
