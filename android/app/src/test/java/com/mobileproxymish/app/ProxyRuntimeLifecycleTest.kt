package com.mobileproxymish.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProxyRuntimeLifecycleTest {
    @Test
    fun startIsIdempotentUntilFailureOrStop() {
        val lifecycle = ProxyRuntimeLifecycle()

        assertEquals(ProxyRuntimeSnapshot.Stopped, lifecycle.snapshot.value)
        assertTrue(lifecycle.requestStart())
        assertEquals(ProxyRuntimeSnapshot.Starting, lifecycle.snapshot.value)
        assertFalse(lifecycle.requestStart())

        assertTrue(lifecycle.markRunning())
        assertEquals(ProxyRuntimeSnapshot.Running, lifecycle.snapshot.value)
        assertFalse(lifecycle.requestStart())
    }

    @Test
    fun childFailureClearsRunningAndAllowsBoundedRestart() {
        val lifecycle = ProxyRuntimeLifecycle()
        assertTrue(lifecycle.requestStart())
        assertTrue(lifecycle.markRunning())

        lifecycle.markFailed(ProxyRuntimeFailure.ChildExited)
        assertEquals(
            ProxyRuntimeSnapshot.Failed(ProxyRuntimeFailure.ChildExited),
            lifecycle.snapshot.value,
        )
        assertTrue(lifecycle.requestStart())
        assertEquals(ProxyRuntimeSnapshot.Starting, lifecycle.snapshot.value)
        assertTrue(lifecycle.markRunning())
        assertEquals(ProxyRuntimeSnapshot.Running, lifecycle.snapshot.value)
    }

    @Test
    fun cleanupFailureNeverLeavesStaleRunning() {
        val lifecycle = ProxyRuntimeLifecycle()
        assertTrue(lifecycle.requestStart())
        assertTrue(lifecycle.markRunning())

        lifecycle.markFailed(ProxyRuntimeFailure.CleanupFailed)

        assertEquals(
            ProxyRuntimeSnapshot.Failed(ProxyRuntimeFailure.CleanupFailed),
            lifecycle.snapshot.value,
        )
        assertFalse(lifecycle.snapshot.value == ProxyRuntimeSnapshot.Running)
    }

    @Test
    fun stopAndProcessGenerationRecreationReturnToStopped() {
        val lifecycle = ProxyRuntimeLifecycle()
        assertTrue(lifecycle.requestStart())
        assertTrue(lifecycle.markRunning())
        lifecycle.markStopped()
        assertEquals(ProxyRuntimeSnapshot.Stopped, lifecycle.snapshot.value)
        assertTrue(lifecycle.requestStart())

        val recreated = ProxyRuntimeLifecycle()
        assertEquals(ProxyRuntimeSnapshot.Stopped, recreated.snapshot.value)
        assertFalse(recreated.markRunning())
        assertEquals(ProxyRuntimeSnapshot.Stopped, recreated.snapshot.value)
    }

    @Test
    fun healthCannotPublishRunningWithoutAStartGeneration() {
        val lifecycle = ProxyRuntimeLifecycle()

        assertFalse(lifecycle.markRunning())
        assertEquals(ProxyRuntimeSnapshot.Stopped, lifecycle.snapshot.value)

        lifecycle.markFailed(ProxyRuntimeFailure.HealthCheckFailed)
        assertFalse(lifecycle.markRunning())
        assertEquals(
            ProxyRuntimeSnapshot.Failed(ProxyRuntimeFailure.HealthCheckFailed),
            lifecycle.snapshot.value,
        )
    }

    @Test
    fun exactGenerationCleanupClosesProxyBeforeCellularOwner() {
        val effects = mutableListOf<String>()

        val clean = closeRuntimeGenerationExact(
            closeProxy = { effects += "proxy" },
            closeCellular = { effects += "cellular" },
        )

        assertTrue(clean)
        assertEquals(listOf("proxy", "cellular"), effects)
    }

    @Test
    fun exactGenerationCleanupStillAttemptsCellularAfterProxyFailure() {
        val effects = mutableListOf<String>()

        val clean = closeRuntimeGenerationExact(
            closeProxy = {
                effects += "proxy"
                error("proxy cleanup failed")
            },
            closeCellular = { effects += "cellular" },
        )

        assertFalse(clean)
        assertEquals(listOf("proxy", "cellular"), effects)
    }

    @Test
    fun processGenerationCredentialsAreExplicitTypedMaterial() {
        val credentials = ProxyRuntimeCredentials(
            username = "process-generation-user",
            password = "process-generation-password",
        )

        assertEquals("process-generation-user", credentials.username)
        assertEquals("process-generation-password", credentials.password)
        assertNotEquals(credentials.username, credentials.password)
    }
}
