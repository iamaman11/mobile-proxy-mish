package com.mobileproxymish.app

import com.mobileproxymish.app.cellular.RootProcess
import com.mobileproxymish.app.cellular.RootProcessResult
import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class LegacySingBoxUpgradeMigrationTest {
    @Test
    fun multipleExactOwnedLegacyChildrenAreCleanedBeforeMarkerPublication() {
        val root = Files.createTempDirectory("mish-legacy-migration").toFile()
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

        val migrated = LegacySingBoxUpgradeMigration(runtime, marker, process).runOnce()

        assertTrue(migrated)
        assertTrue(marker.readText(Charsets.US_ASCII).trim() == "native-proxy-v1")
        assertTrue(process.commands.size == 4)
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

        val migrated = LegacySingBoxUpgradeMigration(runtime, marker, process).runOnce()

        assertTrue(migrated)
        assertTrue(marker.isFile)
        assertTrue(process.commands.size == 2)
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

        val migrated = LegacySingBoxUpgradeMigration(runtime, marker, process).runOnce()

        assertFalse(migrated)
        assertFalse(marker.exists())
        assertTrue(process.commands.size == 1)
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

        val migrated = LegacySingBoxUpgradeMigration(runtime, marker, process).runOnce()

        assertFalse(migrated)
        assertFalse(marker.exists())
    }

    private class FakeRootProcess(vararg responses: RootProcessResult) : RootProcess {
        private val pending = ArrayDeque(responses.toList())
        val commands = mutableListOf<String>()

        override fun run(arguments: List<String>): RootProcessResult {
            commands += arguments.singleOrNull { it != "su" && it != "-c" }
                ?: arguments.last()
            return pending.removeFirstOrNull()
                ?: error("unexpected root command: ${arguments.joinToString(" ")}")
        }
    }
}
