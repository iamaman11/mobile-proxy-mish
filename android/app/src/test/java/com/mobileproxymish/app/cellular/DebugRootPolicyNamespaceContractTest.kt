package com.mobileproxymish.app.cellular

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

class DebugRootPolicyNamespaceContractTest {
    @Test
    fun releaseAndDebugRootPolicyNamespacesStayDistinct() {
        val source = source("CellularRootPolicy.kt")

        assertTrue(source.contains("RELEASE_MISH_CHAIN = \"MISH_EGRESS_V1\""))
        assertTrue(source.contains("DEBUG_MISH_CHAIN = \"MISH_DEBUG_EGRESS_V1\""))
        assertTrue(source.contains("PolicyIdentity(\"0x200000\", 0x200000UL, 9500, 9501)"))
        assertTrue(source.contains("PolicyIdentity(\"0x2000000\", 0x2000000UL, 9580, 9581)"))
        assertTrue(
            source.contains(
                "get() = if (debugIsolation) DEBUG_POLICY_CANDIDATES else RELEASE_POLICY_CANDIDATES",
            ),
        )
        assertTrue(
            source.contains("get() = if (debugIsolation) DEBUG_MISH_CHAIN else RELEASE_MISH_CHAIN"),
        )
    }

    @Test
    fun runtimeEnablesIsolationOnlyForDebuggableDebugPackage() {
        val source = source("CellularRuntimeBridge.kt")

        assertTrue(source.contains("debugIsolation = context.packageName.endsWith(\".debug\") &&"))
        assertTrue(source.contains("ApplicationInfo.FLAG_DEBUGGABLE"))
    }

    private fun source(name: String): String {
        val file = File(
            System.getProperty("user.dir"),
            "src/main/java/com/mobileproxymish/app/cellular/$name",
        )
        check(file.isFile) { "missing production source contract: ${file.absolutePath}" }
        return file.readText()
    }
}
