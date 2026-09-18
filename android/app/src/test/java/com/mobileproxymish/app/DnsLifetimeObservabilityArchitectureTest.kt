package com.mobileproxymish.app

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** U3 guard: native DNS lifetime telemetry stays Rust-owned and observation-only. */
class DnsLifetimeObservabilityArchitectureTest {
    @Test
    fun dnsLifetimeFactsStayInRustWithoutAndroidSchedulerOrCounters() {
        val connector = repositoryFile("crates/runtime/src/cellular_connector.rs").readText()
        val bridge = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/cellular/CellularRuntimeBridge.kt",
        ).readText()
        val diagnostics = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt",
        ).readText()

        assertTrue(
            "Rust connector must expose process-wide native DNS occupancy facts",
            connector.contains("static DNS_DIAGNOSTICS") &&
                connector.contains("completed_after_owner_change") &&
                connector.contains("discarded_stale") &&
                connector.contains("peak_active"),
        )
        assertTrue(
            "Android must only project the Rust DNS snapshot",
            bridge.contains("controller?.dnsDiagnosticSnapshot()") &&
                diagnostics.contains("dnsObservation = dnsAfter") &&
                diagnostics.contains("\"completed_after_owner_change\""),
        )

        for (forbidden in listOf("newSingleThreadExecutor", "newFixedThreadPool", "AtomicInteger", "AtomicLong")) {
            assertFalse(
                "DNS observability must not introduce Android scheduling/accounting: $forbidden",
                bridge.substringAfter("internal fun dnsDiagnosticObservation").substringBefore("fun start()")
                    .contains(forbidden),
            )
        }
        assertFalse(
            "DNS connector must not create a second runtime or dedicated scheduler",
            connector.contains("tokio::runtime::Builder") ||
                connector.contains("std::thread::spawn"),
        )
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
