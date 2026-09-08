package com.mobileproxymish.app

import org.junit.Assert.assertTrue
import org.junit.Test

class MainUiStateTest {
    @Test
    fun bootstrapStateDoesNotClaimReadiness() {
        assertTrue(MainUiState().status.contains("not implemented"))
    }
}
