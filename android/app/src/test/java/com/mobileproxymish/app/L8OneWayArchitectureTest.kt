package com.mobileproxymish.app

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Executable proof that the L8 PRODUCT cutover is one-way. */
class L8OneWayArchitectureTest {
    @Test
    fun shippingProductContainsNoPreL8AndroidProxyRuntimeCompatibility() {
        val androidMain = repositoryDirectory("android/app/src/main")
        val forbiddenLowercase = listOf(
            "sing-box",
            "libsingbox.so",
            "legacysingbox",
            "legacyruntimecutover",
            "legacy_migration",
            "legacy migration",
            "legacy_cutover",
            "proxy-native-migration",
            "sing-box-current-generation",
            "sing-box-owned-cleanup",
        )

        val offenders = androidMain.walkTopDown()
            .filter(File::isFile)
            .filter { it.extension in setOf("kt", "java", "xml") }
            .flatMap { file ->
                val sourceLowercase = file.readText().lowercase()
                forbiddenLowercase.asSequence()
                    .filter(sourceLowercase::contains)
                    .map { token -> "${file.relativeTo(androidMain).invariantSeparatorsPath}:$token" }
            }
            .toList()

        assertTrue("pre-L8 Android PRODUCT semantics must be absent: $offenders", offenders.isEmpty())
    }

    @Test
    fun rustRuntimeAndFfiExposeOnlyCurrentNativeProxyFailures() {
        val roots = listOf(
            repositoryDirectory("crates/runtime/src"),
            repositoryDirectory("crates/android-ffi/src"),
        )
        val forbiddenLowercase = listOf(
            "sing-box",
            "libsingbox",
            "legacymigrationblocked",
            "legacy_migration",
            "legacy migration",
            "legacysingbox",
            "legacyruntimecutover",
            "legacy_cutover",
        )

        val offenders = roots.flatMap { root ->
            root.walkTopDown()
                .filter(File::isFile)
                .filter { it.extension == "rs" }
                .flatMap { file ->
                    val sourceLowercase = file.readText().lowercase()
                    forbiddenLowercase.asSequence()
                        .filter(sourceLowercase::contains)
                        .map { token -> "${file.relativeTo(repositoryRoot()).invariantSeparatorsPath}:$token" }
                }
                .toList()
        }

        assertTrue("pre-L8 Rust/FFI semantics must be absent: $offenders", offenders.isEmpty())
    }

    @Test
    fun obsoleteMigrationSourceFileDoesNotExist() {
        val obsolete = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/LegacySingBoxUpgradeMigration.kt",
        )
        assertFalse("pre-L8 migration source must stay deleted", obsolete.exists())
    }

    private fun repositoryDirectory(relativePath: String): File {
        val directory = File(repositoryRoot(), relativePath)
        assertTrue("repository directory missing: $relativePath", directory.isDirectory)
        return directory
    }

    private fun repositoryFile(relativePath: String): File = File(repositoryRoot(), relativePath)

    private fun repositoryRoot(): File {
        var cursor = File(System.getProperty("user.dir")).absoluteFile
        repeat(8) {
            if (File(cursor, "Cargo.toml").isFile && File(cursor, "android/app").isDirectory) {
                return cursor
            }
            cursor = cursor.parentFile ?: return@repeat
        }
        error("repository root not found from ${System.getProperty("user.dir")}")
    }
}
