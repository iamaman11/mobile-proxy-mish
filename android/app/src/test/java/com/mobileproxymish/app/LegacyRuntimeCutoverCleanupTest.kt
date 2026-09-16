package com.mobileproxymish.app

import com.mobileproxymish.app.cellular.RootProcess
import com.mobileproxymish.app.cellular.RootProcessResult
import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacyRuntimeCutoverCleanupTest {
    @Test
    fun multipleExactOwnedLegacyChildrenAreCleanedBeforeMarkerPublication() {
        val root = Files.createTempDirectory("mish-legacy-cutover").toFile()
        val runtime = root.resolve("proxy-runtime")
        val marker = root.resolve("proxy-native-migration-v1")
        val first = runtime.resolve("sing-box-abcdefghijklmnopqrstuvwx.json").absolutePath
        val second = runtime.resolve("sing-box-zyxwvutsrqponmlkjihgfedc.json").absolutePath
        val process = FakeRootProcess(
            RootProcessResult(
                exitCode = 0,
                stdout =
                    "101\t/system/bin/toybox\tnohup\t/data/app/lib/libsingbox.so\trun\t-c\t$first\t\n" +
                        "202\t/data/app/lib/libsingbox.so\trun\t-c\t$second\t\n",
            ),
            RootProcessResult(exitCode = 0, stdout = ""),
            RootProcessResult(exitCode = 0, stdout = ""),
            RootProcessResult(exitCode = 0, stdout = ""),
        )

        val clean = LegacyRuntimeCutoverCleanup(runtime, marker, process).ensureLegacyRuntimeAbsent()

        assertTrue(clean)
        assertTrue(marker.readText(Charsets.US_ASCII).trim() == "native-proxy-v1")
        assertEquals(4, process.commands.size)
        assertTrue(process.commands[1].contains("kill -TERM"))
        assertTrue(process.commands[1].contains("kill -KILL"))
        assertTrue(process.commands[2].contains("kill -KILL"))
    }

    @Test
    fun foreignSingBoxIsObservedButNeverSignalled() {
        val root = Files.createTempDirectory("mish-legacy-foreign").toFile()
        val runtime = root.resolve("proxy-runtime")
        val marker = root.resolve("proxy-native-migration-v1")
        val process = FakeRootProcess(
            RootProcessResult(
                exitCode = 0,
                stdout = "303\t/data/local/tmp/libsingbox.so\trun\t-c\t/data/local/tmp/foreign.json\t\n",
            ),
            RootProcessResult(
                exitCode = 0,
                stdout = "303\t/data/local/tmp/libsingbox.so\trun\t-c\t/data/local/tmp/foreign.json\t\n",
            ),
        )

        val clean = LegacyRuntimeCutoverCleanup(runtime, marker, process).ensureLegacyRuntimeAbsent()

        assertTrue(clean)
        assertTrue(marker.isFile)
        assertEquals(2, process.commands.size)
        assertFalse(process.commands.any { it.contains("kill -TERM") || it.contains("kill -KILL") })
    }

    @Test
    fun malformedCandidateMentioningOwnedConfigFailsClosedWithoutSignalOrMarker() {
        val root = Files.createTempDirectory("mish-legacy-ambiguous").toFile()
        val runtime = root.resolve("proxy-runtime")
        val marker = root.resolve("proxy-native-migration-v1")
        val config = runtime.resolve("sing-box.json").absolutePath
        val process = FakeRootProcess(
            RootProcessResult(
                exitCode = 0,
                stdout = "404\t/system/bin/sh\t-c\t$config\t/data/app/lib/libsingbox.so\t\n",
            ),
        )

        val clean = LegacyRuntimeCutoverCleanup(runtime, marker, process).ensureLegacyRuntimeAbsent()

        assertFalse(clean)
        assertFalse(marker.exists())
        assertEquals(1, process.commands.size)
    }

    @Test
    fun incompleteRootObservationFailsClosedAndDoesNotPublishMarker() {
        val root = Files.createTempDirectory("mish-legacy-root-failure").toFile()
        val runtime = root.resolve("proxy-runtime")
        val marker = root.resolve("proxy-native-migration-v1")
        val process = FakeRootProcess(
            RootProcessResult(
                exitCode = -1,
                stdout = "",
                timedOut = true,
                outputComplete = false,
            ),
        )

        val clean = LegacyRuntimeCutoverCleanup(runtime, marker, process).ensureLegacyRuntimeAbsent()

        assertFalse(clean)
        assertFalse(marker.exists())
    }

    @Test
    fun preL8RuntimeMechanismsAreConfinedToOneShotCutoverCleanup() {
        val mainSource = repositoryDirectory("android/app/src/main/java/com/mobileproxymish/app")
        val forbiddenLegacyMechanisms = listOf(
            "libsingbox.so",
            "sing-box.json",
            "sing-box-current-generation",
            "sing-box-owned-cleanup.sh",
            "ProxyProcessReconciler",
            "RuntimeProcessLifecycle",
            "startPrivateBridge(",
        )
        val offenders = mainSource.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .filter { file ->
                val source = file.readText()
                forbiddenLegacyMechanisms.any(source::contains)
            }
            .map { it.relativeTo(mainSource).invariantSeparatorsPath }
            .sorted()
            .toList()

        assertEquals(listOf("LegacyRuntimeCutoverCleanup.kt"), offenders)

        val cleanup = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/LegacyRuntimeCutoverCleanup.kt",
        ).readText()
        for (steadyStateToken in listOf(
            "startNativeProxyRuntime",
            "NativeProxyRuntime",
            "proxyListenerPorts",
            "MeshTransport",
            "ProductReadiness",
        )) {
            assertFalse("cutover cleanup must not become steady-state runtime: $steadyStateToken", cleanup.contains(steadyStateToken))
        }
    }

    @Test
    fun diagnosticsCannotExecuteLegacyCutoverOrRootRepair() {
        val diagnostics = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt",
        ).readText()
        for (forbidden in listOf(
            "LegacyRuntimeCutoverCleanup",
            "libsingbox.so",
            "sing-box.json",
            "SuProcess(",
            "ProcessBuilder(",
            "startNativeProxyRuntime(",
            "kill -TERM",
            "kill -KILL",
        )) {
            assertFalse("diagnostics must remain observation-only: $forbidden", diagnostics.contains(forbidden))
        }
        assertTrue(diagnostics.contains("This provider is strictly read-only"))
        assertTrue(diagnostics.contains("snapshot_v2"))
        assertFalse(diagnostics.contains("snapshot_v1"))
        assertFalse(diagnostics.contains("privateBridge"))
    }

    private fun repositoryDirectory(relativePath: String): File =
        repositoryFile(relativePath, requireFile = false)

    private fun repositoryFile(relativePath: String, requireFile: Boolean = true): File {
        var cursor = File(System.getProperty("user.dir")).absoluteFile
        repeat(8) {
            val candidate = File(cursor, relativePath)
            if ((requireFile && candidate.isFile) || (!requireFile && candidate.isDirectory)) return candidate
            cursor = cursor.parentFile ?: return@repeat
        }
        error("repository path not found from ${System.getProperty("user.dir")}: $relativePath")
    }

    private class FakeRootProcess(vararg responses: RootProcessResult) : RootProcess {
        private val pending = ArrayDeque(responses.toList())
        val commands = mutableListOf<String>()

        override fun run(arguments: List<String>): RootProcessResult {
            commands += arguments.last()
            return pending.removeFirstOrNull()
                ?: error("unexpected root command: ${arguments.joinToString(" ")}")
        }
    }
}
