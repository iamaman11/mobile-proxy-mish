package com.mobileproxymish.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android-side tests cover only effect ordering/redaction. Lifecycle state transitions are owned
 * and directly tested in `crates/runtime`; Kotlin deliberately has no parallel lifecycle machine.
 */
class ProxyRuntimeLifecycleTest {
    @Test
    fun exactGenerationCleanupClosesMeshThenProxyThenCellularOwner() {
        val effects = mutableListOf<String>()

        val clean = closeRuntimeGenerationExact(
            closeMesh = { effects += "mesh" },
            closeProxy = { effects += "proxy" },
            closeCellular = { effects += "cellular" },
        )

        assertTrue(clean)
        assertEquals(listOf("mesh", "proxy", "cellular"), effects)
    }

    @Test
    fun exactGenerationCleanupAttemptsEveryEffectAfterEarlierFailures() {
        val effects = mutableListOf<String>()

        val clean = closeRuntimeGenerationExact(
            closeMesh = {
                effects += "mesh"
                error("Mesh cleanup failed")
            },
            closeProxy = {
                effects += "proxy"
                error("proxy cleanup failed")
            },
            closeCellular = { effects += "cellular" },
        )

        assertFalse(clean)
        assertEquals(listOf("mesh", "proxy", "cellular"), effects)
    }

    @Test
    fun externalCredentialMaterialIsRedactedFromStringProjection() {
        val credentials = ProxyRuntimeCredentials(
            username = "external-user-secret",
            password = "external-password-secret",
        )

        assertEquals("external-user-secret", credentials.username)
        assertEquals("external-password-secret", credentials.password)
        assertFalse(credentials.toString().contains(credentials.username))
        assertFalse(credentials.toString().contains(credentials.password))
    }
}
