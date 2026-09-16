package com.mobileproxymish.app

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Executable proof that the L8 PRODUCT proxy cutover is one-way. */
class L8OneWayArchitectureTest {
    @Test
    fun shippingProductContainsNoPreL8AndroidProxyRuntimeCompatibility() {
        val androidMain = repositoryDirectory("android/app/src/main")
        val forbiddenProxyTokens = listOf(
            "sing-box",
            "libsingbox.so",
            "legacysingbox",
            "legacymigrationblocked",
            "proxy.legacy_migration_blocked",
            "proxy-native-migration",
            "sing-box-current-generation",
            "sing-box-owned-cleanup",
        )

        val offenders = androidMain.walkTopDown()
            .filter(File::isFile)
            .filter { it.extension in setOf("kt", "java", "xml") }
            .flatMap { file ->
                val sourceLowercase = file.readText().lowercase()
                forbiddenProxyTokens.asSequence()
                    .filter(sourceLowercase::contains)
                    .map { token -> "${file.relativeTo(androidMain).invariantSeparatorsPath}:$token" }
            }
            .toList()

        assertTrue(
            "pre-L8 Android proxy compatibility must be absent: $offenders",
            offenders.isEmpty(),
        )
    }

    @Test
    fun rustRuntimeAndFfiExposeOnlyCurrentNativeProxyFailures() {
        val roots = listOf(
            repositoryDirectory("crates/runtime/src"),
            repositoryDirectory("crates/android-ffi/src"),
        )
        val forbiddenProxyTokens = listOf(
            "sing-box",
            "libsingbox",
            "legacysingbox",
            "legacymigrationblocked",
            "proxy-native-migration",
        )

        val offenders = roots.flatMap { root ->
            root.walkTopDown()
                .filter(File::isFile)
                .filter { it.extension == "rs" }
                .flatMap { file ->
                    val sourceLowercase = file.readText().lowercase()
                    forbiddenProxyTokens.asSequence()
                        .filter(sourceLowercase::contains)
                        .map { token -> "${file.relativeTo(repositoryRoot()).invariantSeparatorsPath}:$token" }
                }
                .toList()
        }

        assertTrue(
            "pre-L8 Rust/FFI proxy compatibility must be absent: $offenders",
            offenders.isEmpty(),
        )
    }

    @Test
    fun androidProxySupervisorObservesRustTerminalFailureWithoutHealthPolling() {
        val supervisor = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()
        val runtime = repositoryFile("crates/runtime/src/proxy_runtime.rs").readText()
        val ffi = repositoryFile("crates/android-ffi/src/proxy_serving_ffi.rs").readText()

        assertTrue(
            "Rust runtime must expose one blocking terminal-failure observation",
            runtime.contains("pub fn wait_terminal_failure("),
        )
        assertTrue(
            "UniFFI must project the Rust terminal-failure observation without reclassifying health",
            ffi.contains("pub fn wait_for_terminal_failure("),
        )
        assertTrue(
            "Android must wait on the typed Rust terminal event",
            supervisor.contains("expectedRuntime.waitForTerminalFailure()"),
        )
        for (forbidden in listOf("HEALTH_POLL_MS", "delay(", "while (isActive")) {
            assertFalse(
                "Android proxy supervisor must not actively poll serving health: $forbidden",
                supervisor.contains(forbidden),
            )
        }
    }

    @Test
    fun obsoleteProxyMigrationSourceFileDoesNotExist() {
        val obsolete = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/LegacySingBoxUpgradeMigration.kt",
        )
        assertFalse("pre-L8 proxy migration source must stay deleted", obsolete.exists())
    }

    private fun repositoryDirectory(relativePath: String): File {
        val directory = File(repositoryRoot(), relativePath)
        assertTrue("repository directory missing: $relativePath", directory.isDirectory)
        return directory
    }

    private fun repositoryFile(relativePath: String): File = File(repositoryRoot(), relativePath)

    private fun repositoryRoot(): File {
        var cursor = File(requireNotNull(System.getProperty("user.dir"))).absoluteFile
        repeat(9) {
            if (File(cursor, "Cargo.toml").isFile && File(cursor, "android/app").isDirectory) {
                return cursor
            }
            val parent = cursor.parentFile
            if (parent != null) cursor = parent
        }
        error("repository root not found from ${System.getProperty("user.dir")}")
    }
}
