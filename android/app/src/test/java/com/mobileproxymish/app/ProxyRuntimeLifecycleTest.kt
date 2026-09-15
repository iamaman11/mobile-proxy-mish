package com.mobileproxymish.app

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android-side tests cover only effect ordering/redaction and adapter-boundary invariants.
 * Lifecycle and process-ownership decisions are owned and directly tested in `crates/runtime`.
 */
class ProxyRuntimeLifecycleTest {
    @Test
    fun loopbackHealthRequiresConsecutiveFailuresBeforeTerminalCleanup() {
        assertFalse(confirmedLoopbackHealthFailure(1))
        assertFalse(confirmedLoopbackHealthFailure(2))
        assertTrue(confirmedLoopbackHealthFailure(3))
    }

    @Test
    fun startupHealthRejectsStaleListenerWhenCurrentChildDoesNotSurviveStabilityGap() {
        val first = ProxyStartupHealthObservation(
            exactChildAlive = true,
            privateBridgeHealthy = true,
            listenersReachable = true,
        )
        val second = ProxyStartupHealthObservation(
            exactChildAlive = false,
            privateBridgeHealthy = true,
            listenersReachable = true,
        )

        assertFalse(stableStartupHealth(first, second))
        assertTrue(stableStartupHealth(first, first))
    }

    @Test
    fun generationIdentityIsRetainedUntilPossibleRootChildTerminationIsConfirmed() {
        assertFalse(
            generationIdentityMayBeDeleted(
                ownedChildMayExist = true,
                terminationConfirmed = false,
            ),
        )
        assertTrue(
            generationIdentityMayBeDeleted(
                ownedChildMayExist = true,
                terminationConfirmed = true,
            ),
        )
        assertTrue(
            generationIdentityMayBeDeleted(
                ownedChildMayExist = false,
                terminationConfirmed = false,
            ),
        )
    }

    @Test
    fun currentPidComesFromRustOwnerNotLauncherBackgroundPid() {
        val supervisor = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()
        val rustOwner = repositoryFile(
            "crates/runtime/src/process_reconciliation.rs",
        ).readText()

        assertTrue(supervisor.contains("processReconciler.resolveCurrentProcess(configFile)"))
        assertTrue(supervisor.contains("persistCanonicalPid(pid)"))
        assertFalse(supervisor.contains("child_pid=\"${'$'}!\""))
        assertFalse(supervisor.contains("exact_pid()"))
        assertFalse(supervisor.contains("writeRootControl"))
        assertTrue(rustOwner.contains("pub fn resolve_current_runtime_process"))
        assertTrue(rustOwner.contains("RuntimeCurrentProcessDecision::Conflict"))
    }

    @Test
    fun staleProcessOwnershipDecisionLivesInRustAndAndroidOnlyExecutesObservedTargets() {
        val supervisor = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()
        val reconciler = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyProcessReconciler.kt",
        ).readText()
        val rustOwner = repositoryFile(
            "crates/runtime/src/process_reconciliation.rs",
        ).readText()

        assertTrue(supervisor.contains("ProxyProcessReconciler(runtimeDir)"))
        assertTrue(supervisor.contains("processReconciler.cleanupOwnedProcesses()"))
        assertTrue(supervisor.contains("processReconciler.resolveCurrentProcess(configFile)"))
        assertFalse(supervisor.contains("private fun writeOwnedOrphanCleanup"))

        assertTrue(reconciler.contains("planRuntimeProcessCleanup"))
        assertTrue(reconciler.contains("resolveCurrentRuntimeProcess"))
        assertTrue(reconciler.contains("sha256sum"))
        assertTrue(reconciler.contains("same_snapshot()"))
        assertTrue(reconciler.contains("RuntimeProcessCleanupDecision.FAIL_CLOSED"))
        assertFalse(reconciler.contains("pkill"))

        assertTrue(rustOwner.contains("pub fn plan_runtime_process_cleanup"))
        assertTrue(rustOwner.contains("pub fn resolve_current_runtime_process"))
        assertTrue(rustOwner.contains("RuntimeProcessCleanupDecision::TerminateOwned"))
        assertTrue(rustOwner.contains("RuntimeProcessCleanupDecision::FailClosed"))
    }

    @Test
    fun cleanupNeverUsesASecondShellIdentityOwner() {
        val source = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()

        assertFalse(source.contains("stopExactRootSingBox"))
        assertFalse(source.contains("runRootControl"))
        assertFalse(source.contains("writeRootControl"))
        assertTrue(source.contains("cleanupOwnedOrphanProcesses()"))
    }

    @Test
    fun steadyStateOwnershipCheckIsIndependentOfListenerReachability() {
        val source = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()

        val ownership = source.indexOf("val ownershipFailure = if (now >= nextOwnershipCheck)")
        val listeners = source.indexOf("canonicalLoopbackListenersReachable()")
        assertTrue(ownership >= 0)
        assertTrue(listeners >= 0)
        assertTrue(ownership < listeners)
        assertTrue(source.contains("OWNERSHIP_POLL_MS = 3_000L"))
    }

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

    private fun repositoryFile(relativePath: String): File {
        var cursor = File(System.getProperty("user.dir")).absoluteFile
        repeat(8) {
            File(cursor, relativePath).takeIf(File::isFile)?.let { return it }
            cursor = cursor.parentFile ?: return@repeat
        }
        error("repository file not found from ${System.getProperty("user.dir")}: $relativePath")
    }
}