package com.mobileproxymish.app

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProcessCmdlineSnapshotTest {
    @Test
    fun digestMatchesExactNulDelimitedProcCmdlineSnapshot() {
        val argv = listOf(
            "/data/app/lib/libsingbox.so",
            "run",
            "-c",
            "/data/user/0/com.mobileproxymish.app.debug/no_backup/proxy-runtime/" +
                "sing-box-abcdefghijklmnopqrstuvwx.json",
        )

        val expected = "8dc057cc3570d8ccd2d951d4bc7c6ba3c557c4cbf31761f4ca38c483b5f038ff"
        assertTrue(procCmdlineSnapshotMatchesDigest(argv, expected))
    }

    @Test
    fun mixedOrMalformedSnapshotFailsClosed() {
        val argv = listOf("/data/app/lib/libsingbox.so", "run", "-c", "/owned/config.json")
        val digest = procCmdlineSha256(argv)

        assertTrue(procCmdlineSnapshotMatchesDigest(argv, digest))
        assertFalse(procCmdlineSnapshotMatchesDigest(argv + "unexpected", digest))
        assertFalse(procCmdlineSnapshotMatchesDigest(argv, "not-a-sha256"))
    }

    @Test
    fun reconcilerMustBindParsedArgvBeforeProjectingObservationToRustOwner() {
        val source = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyProcessReconciler.kt",
        ).readText()

        val observeStart = source.indexOf("private fun observeCandidates()")
        val observeEnd = source.indexOf("private fun terminateAuthorized", startIndex = observeStart)
        assertTrue(observeStart >= 0 && observeEnd > observeStart)
        val observeBody = source.substring(observeStart, observeEnd)

        val integrityCheck = "procCmdlineSnapshotMatchesDigest(argv, digest)"
        val observationProjection = "observations += RuntimeProcessObservationView("
        val integrityIndex = observeBody.indexOf(integrityCheck)
        val projectionIndex = observeBody.indexOf(observationProjection)
        assertTrue(integrityIndex >= 0)
        assertTrue(projectionIndex > integrityIndex)

        val cleanupStart = source.indexOf("fun cleanupOwnedProcesses()")
        val cleanupEnd = source.indexOf("private fun observeCandidates()", startIndex = cleanupStart)
        assertTrue(cleanupStart >= 0 && cleanupEnd > cleanupStart)
        val cleanupBody = source.substring(cleanupStart, cleanupEnd)
        val observationCall = "val observations = observeCandidates() ?: return false"
        val ownerCall = "planRuntimeProcessCleanup(runtimeDir.absolutePath, observations)"
        val observationIndex = cleanupBody.indexOf(observationCall)
        val ownerIndex = cleanupBody.indexOf(ownerCall)
        assertTrue(observationIndex >= 0)
        assertTrue(ownerIndex > observationIndex)
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
