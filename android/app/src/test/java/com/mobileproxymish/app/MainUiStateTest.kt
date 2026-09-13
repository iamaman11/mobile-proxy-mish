package com.mobileproxymish.app

import com.mobileproxymish.ffi.ProductReadinessState
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MainUiStateTest {
    @Test
    fun bootstrapStateDoesNotClaimProductionAcceptance() {
        val state = MainUiState()

        assertEquals(readinessStatus(ProductReadinessState.UNKNOWN), state.overallStatus)
        assertTrue(state.overallStatus.contains("acceptance pending"))
        assertEquals("Unknown", state.cellularState)
        assertEquals("cellular.no_observation", state.cellularReasonCode)
        assertEquals("Stopped", state.proxyState)
        assertEquals(null, state.proxyReasonCode)
    }

    @Test
    fun overallStatusMapsOnlyRustReadinessEnumAndNeverClaimsFormalAcceptance() {
        val expected = mapOf(
            ProductReadinessState.READY to "READY",
            ProductReadinessState.NOT_READY to "NOT_READY",
            ProductReadinessState.DEGRADED to "DEGRADED",
            ProductReadinessState.UNKNOWN to "UNKNOWN",
        )
        for ((state, token) in expected) {
            val text = readinessStatus(state)
            assertTrue(text.contains("— $token"))
            assertTrue(text.contains("runtime projection"))
            assertTrue(text.contains("production acceptance pending"))
        }
    }
}
