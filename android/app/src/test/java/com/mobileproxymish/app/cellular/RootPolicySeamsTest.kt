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
    fun executorDiagnosticWindowCountsObservationsMutationsAndExactDuplicateReads() {
        val observation = "ip -4 rule show"
        val mutation = "ip -4 rule add pref 9501 fwmark 0x200000/0x200000 unreachable"
        val executor = RootPolicyExecutor(
            ScriptedRootProcess(
                mutableMapOf(
                    observation to ok("1000: from all lookup 100\n"),
                    mutation to ok(""),
                ),
            ),
        )

        executor.beginDiagnosticWindow()
        assertEquals(listOf("1000: from all lookup 100"), executor.lines(observation))
        assertEquals(listOf("1000: from all lookup 100"), executor.lines(observation))
        assertTrue(executor.commandSucceeded(mutation))
        val diagnostic = executor.finishDiagnosticWindow()

        assertEquals(3, diagnostic.commands)
        assertEquals(2, diagnostic.observationCommands)
        assertEquals(1, diagnostic.mutationCommands)
        assertEquals(1, diagnostic.duplicateObservations)
        assertEquals(0, diagnostic.incompleteOrTimedOutCommands)
        assertEquals(0, diagnostic.mutationFailures)
    }

    @Test
    fun executorDiagnosticWindowSeparatesIncompleteObservationFromMutationFailure() {
        val incomplete = "ip -4 rule show"
        val absent = "iptables -t mangle -C OUTPUT -j MISH_EGRESS_V1"
        val failedMutation = "iptables -t mangle -D OUTPUT -j MISH_EGRESS_V1"
        val executor = RootPolicyExecutor(
            ScriptedRootProcess(
                mutableMapOf(
                    incomplete to RootProcessResult(
                        exitCode = 0,
                        stdout = "",
                        outputComplete = false,
                    ),
                    absent to RootProcessResult(exitCode = 1, stdout = ""),
                    failedMutation to RootProcessResult(exitCode = 1, stdout = ""),
                ),
            ),
        )

        executor.beginDiagnosticWindow()
        assertNull(executor.lines(incomplete))
        assertTrue(executor.removeExactRule(absent, failedMutation, maxPasses = 1))
        assertFalse(executor.commandSucceeded(failedMutation))
        val diagnostic = executor.finishDiagnosticWindow()

        assertEquals(3, diagnostic.commands)
        assertEquals(2, diagnostic.observationCommands)
        assertEquals(1, diagnostic.mutationCommands)
        assertEquals(0, diagnostic.duplicateObservations)
        assertEquals(1, diagnostic.incompleteOrTimedOutCommands)
        assertEquals(1, diagnostic.mutationFailures)
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
