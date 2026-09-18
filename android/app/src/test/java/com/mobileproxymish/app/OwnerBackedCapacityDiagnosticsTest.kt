package com.mobileproxymish.app

import java.io.File
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Executable guard that capacity diagnostics stay projections of the Rust natural owners. */
class OwnerBackedCapacityDiagnosticsTest {
    @Test
    fun activeSessionDiagnosticsComeFromRustOwnersWithoutAndroidAccounting() {
        val proxyFfi = repositoryFile("crates/android-ffi/src/proxy_serving_ffi.rs").readText()
        val transportFfi = repositoryFile("crates/android-ffi/src/transport_ffi.rs").readText()
        val proxyAdapter = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/ProxyRuntimeSupervisor.kt",
        ).readText()
        val meshAdapter = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/MeshIngressRuntimeBridge.kt",
        ).readText()
        val diagnostics = repositoryFile(
            "android/app/src/main/java/com/mobileproxymish/app/MishDiagnosticsProvider.kt",
        ).readText()

        assertTrue(
            "Proxy Serving owner must expose its own live session count through UniFFI",
            proxyFfi.contains("pub fn active_sessions(&self) -> u32") &&
                proxyFfi.contains("self.inner.active_sessions()"),
        )
        assertTrue(
            "Transport owner snapshot must expose external Mesh session and capacity-reject facts through UniFFI",
            transportFfi.contains("pub active_sessions: u64") &&
                transportFfi.contains("pub capacity_rejects: u64") &&
                transportFfi.contains("active_sessions: snapshot.active_sessions() as u64") &&
                transportFfi.contains("capacity_rejects: snapshot.capacity_rejects() as u64"),
        )
        assertTrue(
            "Android proxy diagnostics must read the native owner rather than count sessions",
            proxyAdapter.contains("runCatching { it.activeSessions() }") &&
                proxyAdapter.contains("activeSessions = activeSessions"),
        )
        assertTrue(
            "Android Mesh diagnostics must fetch one fresh Transport-owner capacity observation",
            meshAdapter.contains("val owner = activeController.admissionSnapshot()") &&
                meshAdapter.contains("activeSessions = owner.activeSessions") &&
                meshAdapter.contains("capacityRejects = owner.capacityRejects") &&
                meshAdapter.contains("diagnosticSessionObservation()"),
        )
        assertTrue(
            "The canonical diagnostics payload must publish owner-backed active and capacity-reject facts",
            diagnostics.contains("proxyActiveSessions = proxyDiagnosticAfter.activeSessions") &&
                diagnostics.contains("meshActiveSessions = meshSessionObservation?.activeSessions") &&
                diagnostics.contains("meshCapacityRejects = meshSessionObservation?.capacityRejects") &&
                diagnostics.split("put(\"active_sessions\"").size - 1 == 2 &&
                diagnostics.contains("put(\"capacity_rejects\", facts.meshCapacityRejects"),
        )

        for (source in listOf(proxyAdapter, meshAdapter, diagnostics)) {
            assertFalse(
                "Android diagnostics must not introduce a parallel capacity semaphore",
                source.contains("Semaphore("),
            )
            assertFalse(
                "Android diagnostics must not introduce a parallel active-session atomic counter",
                source.contains("AtomicInteger("),
            )
        }
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
