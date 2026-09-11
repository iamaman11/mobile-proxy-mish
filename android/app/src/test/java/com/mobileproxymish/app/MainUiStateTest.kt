package com.mobileproxymish.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MainUiStateTest {
    @Test
    fun bootstrapStateDoesNotClaimReadiness() {
        val state = MainUiState()

        assertTrue(state.overallStatus.contains("acceptance pending"))
        assertEquals("Unknown", state.cellularState)
        assertEquals("cellular.no_observation", state.cellularReasonCode)
        assertEquals("Stopped", state.proxyState)
        assertEquals(null, state.proxyReasonCode)
    }
}
