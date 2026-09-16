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
    fun androidProxyAdapterCannotOwnNativeHealthOrLifecycleSupervision() {
        val supervisor = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()
        val forbidden = listOf(
            "ProxyServingLifecycleController",
            ".requestStart()",
            ".markRunning()",
            ".markFailed(",
            ".markStopped()",
            "startMonitor(",
            "HEALTH_POLL_MS",
            "monitorScope",
            "monitorJob",
            "kotlinx.coroutines.delay",
            "kotlinx.coroutines.launch",
            "SERVING_UNHEALTHY\n                            } else",
        )
        val offenders = forbidden.filter(supervisor::contains)

        assertTrue(
            "Android ProxyRuntimeSupervisor must not own native lifecycle/health supervision: $offenders",
            offenders.isEmpty(),
        )
        assertTrue(
            "Android must project the immutable Rust runtime snapshot",
            supervisor.contains("newRuntime.snapshot()") &&
                supervisor.contains("projectOwnerSnapshot("),
        )
        assertTrue(
            "Android must subscribe to the typed Rust terminal observation path",
            supervisor.contains("NativeProxyRuntimeObserver") &&
                supervisor.contains("observeTerminalFailure("),
        )
    }

    @Test
    fun rustProxyRuntimeOwnsLifecycleSnapshotAndTerminalFailure() {
        val runtime = repositoryFile("crates/runtime/src/proxy_runtime.rs").readText()
        val ffi = repositoryFile("crates/android-ffi/src/proxy_serving_ffi.rs").readText()
        val lifecycleFfi = repositoryFile(
            "crates/android-ffi/src/runtime_lifecycle_ffi.rs",
        ).readText()

        assertTrue(
            "ProxyServingRuntime must own the semantic lifecycle state",
            runtime.contains("ProxyServingLifecycle") &&
                runtime.contains("pub fn snapshot(&self) -> ProxyServingSnapshot") &&
                runtime.contains("owner_state.mark_running()") &&
                runtime.contains("owner_state.mark_stopped()") &&
                runtime.contains("publish_failure(ProxyServingFailure::ServingUnhealthy)"),
        )
        assertTrue(
            "UniFFI must expose only the runtime-owned immutable snapshot",
            ffi.contains("pub fn snapshot(&self) -> ProxyServingSnapshotView") &&
                ffi.contains("map_proxy_snapshot(self.inner.snapshot())"),
        )
        assertFalse(
            "a second standalone Proxy Serving lifecycle controller must not cross UniFFI",
            lifecycleFfi.contains("ProxyServingLifecycleController"),
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
