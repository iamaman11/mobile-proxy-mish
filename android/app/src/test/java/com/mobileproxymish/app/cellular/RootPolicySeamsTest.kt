package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RootPolicySeamsTest {
    @Test
    fun snapshotParserAcceptsOnlySafeUniqueTablesAndReservedMarkOverlap() {
        assertEquals(
            listOf("100", "rmnet_data0"),
            RootPolicySnapshot.referencedTables(
                listOf(
                    "1000: from all lookup 100",
                    "1001: from all table rmnet_data0",
                    "1002: from all lookup 100",
                    "1003: from all lookup bad/table",
                ),
            ),
        )
        assertTrue(RootPolicySnapshot.isSafeInterfaceName("rmnet_data0"))
        assertFalse(RootPolicySnapshot.isSafeInterfaceName("rmnet data0"))
        assertTrue(RootPolicySnapshot.rpdbLineTouchesReservedMark("9500: from all fwmark 0x200000/0x200000", 0x200000UL))
        assertFalse(RootPolicySnapshot.rpdbLineTouchesReservedMark("9500: from all fwmark 0x400000/0x400000", 0x200000UL))
    }

    @Test
    fun executorRejectsIncompleteAuthoritativeOutput() {
        val executor = RootPolicyExecutor(
            ScriptedRootProcess(
                mutableMapOf(
                    "ip -4 rule show" to RootProcessResult(
                        exitCode = 0,
                        stdout = "1000: from all lookup 100\n",
                        outputComplete = false,
                    ),
                ),
            ),
        )
        assertNull(executor.lines("ip -4 rule show"))
    }

    @Test
    fun routeInspectorFailsClosedOnAmbiguityAndVerifiesExactInterface() {
        val ambiguous = DirectCellularRouteInspector(
            RootPolicyExecutor(
                ScriptedRootProcess(
                    mutableMapOf(
                        "ip -4 rule show" to ok("1000: from all lookup 100\n1001: from all lookup 101\n"),
                        "ip -4 route show table 100 default" to ok("default dev rmnet_data0\n"),
                        "ip -4 route show table 101 default" to ok("default dev rmnet_data0\n"),
                    ),
                ),
            ),
        )
        assertNull(ambiguous.discoverValidatedIpv4Table("rmnet_data0", "ip -4 rule show"))

        val process = ScriptedRootProcess(
            mutableMapOf(
                "ip -4 rule show" to ok("1000: from all lookup 100\n"),
                "ip -4 route show table 100 default" to ok("default via 10.0.0.1 dev rmnet_data0\n"),
                "ip -4 route get 1.1.1.1 mark 0x200000" to ok("1.1.1.1 dev rmnet_data0 src 10.0.0.2\n"),
            ),
        )
        val inspector = DirectCellularRouteInspector(RootPolicyExecutor(process))
        assertEquals("100", inspector.discoverValidatedIpv4Table("rmnet_data0", "ip -4 rule show"))
        assertTrue(inspector.verifyIpv4Path("rmnet_data0", "0x200000"))
        assertFalse(inspector.verifyIpv4Path("rmnet_data1", "0x200000"))
    }

    private class ScriptedRootProcess(
        private val results: MutableMap<String, RootProcessResult>,
    ) : RootProcess {
        override fun run(arguments: List<String>): RootProcessResult {
            require(arguments.size == 3 && arguments[0] == "su" && arguments[1] == "-c")
            return results[arguments[2]] ?: RootProcessResult(
                exitCode = 1,
                stdout = "",
            )
        }
    }

    private companion object {
        fun ok(stdout: String) = RootProcessResult(exitCode = 0, stdout = stdout)
    }
}
