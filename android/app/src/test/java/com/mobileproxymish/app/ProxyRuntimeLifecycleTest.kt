package com.mobileproxymish.app

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android-side tests cover only effect ordering/redaction and small lifecycle adapter invariants.
 * Lifecycle state transitions are owned and directly tested in `crates/runtime`; Kotlin deliberately
 * has no parallel lifecycle machine.
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
    fun rootCleanupUsesExactCmdlineIdentityNotProcDirectoryExistence() {
        val source = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()

        assertTrue(source.contains("owned_pid()"))
        assertTrue(source.contains("exact_pid()"))
        assertTrue(source.contains("[ -r \"/proc/"))
        assertFalse(source.contains("[ -d \"/proc/"))
        assertFalse(source.contains("[ ! -d \"/proc/"))
    }

    @Test
    fun orphanCleanupParsesEveryCmdlineWithBuiltinsAndExactPositionalArgv() {
        val source = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()
        val cleanupStart = source.indexOf("private fun writeOwnedOrphanCleanup")
        val cleanupEnd = source.indexOf("private fun cleanupOwnedOrphanProcesses", cleanupStart)

        assertTrue(cleanupStart >= 0)
        assertTrue(cleanupEnd > cleanupStart)
        val cleanup = source.substring(cleanupStart, cleanupEnd)

        assertTrue(cleanup.contains("exec 3< \"/proc/"))
        assertTrue(cleanup.contains("IFS= read -r -d '' arg1 <&3"))
        assertTrue(cleanup.contains("IFS= read -r -d '' arg2 <&3"))
        assertTrue(cleanup.contains("IFS= read -r -d '' arg3 <&3"))
        assertTrue(cleanup.contains("IFS= read -r -d '' arg4 <&3"))
        assertTrue(cleanup.contains("IFS= read -r -d '' extra <&3"))
        assertTrue(cleanup.contains("[ \"\${'$'}arg2\" = run ] || return 1"))
        assertTrue(cleanup.contains("[ \"\${'$'}arg3\" = -c ] || return 1"))
        assertTrue(cleanup.contains("\"\${'$'}runtime\"/sing-box-*.json"))
        assertFalse(cleanup.contains("tr '\\000'"))
        assertFalse(cleanup.contains("read -r process_name < \"/proc/"))
        assertFalse(source.contains("pkill"))
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

    private fun repositoryFile(relativePath: String): File {
        var cursor = File(System.getProperty("user.dir")).absoluteFile
        repeat(8) {
            File(cursor, relativePath).takeIf(File::isFile)?.let { return it }
            cursor = cursor.parentFile ?: return@repeat
        }
        error("repository file not found from ${System.getProperty("user.dir")}: $relativePath")
    }
}