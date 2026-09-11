package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RootPolicyExecutorTest {
    @Test
    fun admittedGenerationInstallsLookupOnlyAfterGuardAndSelector() {
        val platform = FakePlatform().apply { discoveredTable = "1012" }
        val executor = RootPolicyExecutor.forTesting(platform)

        val result = executor.reconcile(
            productUid = 10123,
            intent = RootPolicyIntent.Admitted(
                generation = 7,
                interfaceName = "rmnet_data0",
            ),
        )

        assertEquals(
            RootPolicyStatus.Active(7, "rmnet_data0", "1012"),
            result,
        )
        assertEquals(
            listOf(
                "authority",
                "guard",
                "selector:10123",
                "remove-lookup",
                "discover:rmnet_data0",
                "install:1012",
                "verify-active:10123:rmnet_data0:1012",
            ),
            platform.calls,
        )
    }

    @Test
    fun missingCellularTableLeavesOnlyFailClosedPolicy() {
        val platform = FakePlatform().apply { discoveredTable = null }
        val executor = RootPolicyExecutor.forTesting(platform)

        val result = executor.reconcile(
            10123,
            RootPolicyIntent.Admitted(8, "rmnet_data0"),
        )

        assertEquals(
            RootPolicyStatus.FailClosed(RootPolicyFailClosedReason.RouteDiscoveryFailed),
            result,
        )
        assertEquals(1, platform.removeLookupCalls)
        assertEquals(0, platform.installLookupCalls)
    }

    @Test
    fun failedActiveVerificationRemovesLookupBeforeReturning() {
        val platform = FakePlatform().apply {
            discoveredTable = "1012"
            activeVerified = false
            failClosedVerified = true
        }
        val executor = RootPolicyExecutor.forTesting(platform)

        val result = executor.reconcile(
            10123,
            RootPolicyIntent.Admitted(9, "rmnet_data0"),
        )

        assertEquals(
            RootPolicyStatus.FailClosed(RootPolicyFailClosedReason.PolicyVerificationFailed),
            result,
        )
        assertEquals(2, platform.removeLookupCalls)
        assertTrue(platform.calls.indexOf("remove-lookup") < platform.calls.lastIndexOf("verify-fail-closed:10123"))
    }

    @Test
    fun cellularLossKeepsSelectorAndUnreachableGuard() {
        val platform = FakePlatform()
        val executor = RootPolicyExecutor.forTesting(platform)

        val result = executor.reconcile(
            10123,
            RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.NoAdmittedNetwork),
        )

        assertEquals(
            RootPolicyStatus.FailClosed(RootPolicyFailClosedReason.NoAdmittedNetwork),
            result,
        )
        assertEquals(
            listOf(
                "authority",
                "guard",
                "selector:10123",
                "remove-lookup",
                "verify-fail-closed:10123",
            ),
            platform.calls,
        )
    }

    @Test
    fun deniedRootNeverAttemptsKernelMutation() {
        val platform = FakePlatform().apply { authority = RootAuthorityStatus.Denied }
        val executor = RootPolicyExecutor.forTesting(platform)

        val result = executor.reconcile(
            10123,
            RootPolicyIntent.FailClosed(RootPolicyFailClosedReason.Startup),
        )

        assertEquals(
            RootPolicyStatus.Unavailable(RootPolicyFailureReason.RootDenied),
            result,
        )
        assertEquals(listOf("authority"), platform.calls)
    }

    @Test
    fun explicitCleanupIsSeparateFromLossReconciliation() {
        val platform = FakePlatform()
        val executor = RootPolicyExecutor.forTesting(platform)

        assertEquals(RootPolicyCleanupStatus.Cleaned, executor.cleanup(10123))
        assertEquals(listOf("authority", "cleanup:10123"), platform.calls)
    }

    @Test
    fun routeParserRequiresOneDedicatedTableForExactInterface() {
        val output = """
            default via 10.0.0.1 dev rmnet_data0 table 1012 proto static
            10.0.0.0/30 dev rmnet_data0 table 1012 proto static scope link
            default via 192.0.2.1 dev wlan0 table 1009 proto static
        """.trimIndent()

        assertEquals(
            "1012",
            RootPolicyParsers.discoverUniqueCellularTable(output, "rmnet_data0"),
        )
    }

    @Test
    fun routeParserRejectsMainAndAmbiguousTables() {
        assertNull(
            RootPolicyParsers.discoverUniqueCellularTable(
                "default via 10.0.0.1 dev rmnet_data0 table main",
                "rmnet_data0",
            ),
        )
        assertNull(
            RootPolicyParsers.discoverUniqueCellularTable(
                """
                    default via 10.0.0.1 dev rmnet_data0 table 1012
                    default via 10.0.0.1 dev rmnet_data0 table 1013
                """.trimIndent(),
                "rmnet_data0",
            ),
        )
    }

    private class FakePlatform : RootPolicyPlatform {
        val calls = mutableListOf<String>()
        var authority: RootAuthorityStatus = RootAuthorityStatus.Ready
        var discoveredTable: String? = "1012"
        var activeVerified = true
        var failClosedVerified = true
        var cleanupSucceeded = true
        var removeLookupCalls = 0
        var installLookupCalls = 0

        override fun authorityStatus(): RootAuthorityStatus {
            calls += "authority"
            return authority
        }

        override fun ensureGuard(): Boolean {
            calls += "guard"
            return true
        }

        override fun ensureSelector(productUid: Int): Boolean {
            calls += "selector:$productUid"
            return true
        }

        override fun removeLookup(): Boolean {
            calls += "remove-lookup"
            removeLookupCalls += 1
            return true
        }

        override fun discoverValidatedTable(interfaceName: String): String? {
            calls += "discover:$interfaceName"
            return discoveredTable
        }

        override fun installLookup(table: String): Boolean {
            calls += "install:$table"
            installLookupCalls += 1
            return true
        }

        override fun verifyActive(
            productUid: Int,
            interfaceName: String,
            table: String,
        ): Boolean {
            calls += "verify-active:$productUid:$interfaceName:$table"
            return activeVerified
        }

        override fun verifyFailClosed(productUid: Int): Boolean {
            calls += "verify-fail-closed:$productUid"
            return failClosedVerified
        }

        override fun cleanup(productUid: Int): Boolean {
            calls += "cleanup:$productUid"
            return cleanupSucceeded
        }
    }
}
