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
    fun exactCurrentPidControlStillRequiresCmdlineIdentityNotProcDirectoryExistence() {
        val source = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()

        assertTrue(source.contains("exact_pid()"))
        assertTrue(source.contains("[ -r \"/proc/"))
        assertFalse(source.contains("[ -d \"/proc/"))
        assertFalse(source.contains("[ ! -d \"/proc/"))
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
        assertFalse(supervisor.contains("private fun writeOwnedOrphanCleanup"))

        assertTrue(reconciler.contains("planRuntimeProcessCleanup"))
        assertTrue(reconciler.contains("sha256sum"))
        assertTrue(reconciler.contains("same_snapshot()"))
        assertTrue(reconciler.contains("RuntimeProcessCleanupDecision.FAIL_CLOSED"))
        assertFalse(reconciler.contains("pkill"))

        assertTrue(rustOwner.contains("pub fn plan_runtime_process_cleanup"))
        assertTrue(rustOwner.contains("RuntimeProcessCleanupDecision::TerminateOwned"))
        assertTrue(rustOwner.contains("RuntimeProcessCleanupDecision::FailClosed"))
    }

    @Test
    fun terminationFastPathNeverShortCircuitsRustReconciliationProof() {
        val source = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()

        assertFalse(source.contains("stopExactRootSingBox(pid)) || cleanupOwnedOrphanProcesses()"))
        assertFalse(source.contains("stopExactRootSingBox(currentPid)) || cleanupOwnedOrphanProcesses()"))
        assertTrue(source.contains("if (pid != null) runCatching { stopExactRootSingBox(pid) }"))
        assertTrue(source.contains("if (currentPid != null) runCatching { stopExactRootSingBox(currentPid) }"))
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
                effects += "proxy" },
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
