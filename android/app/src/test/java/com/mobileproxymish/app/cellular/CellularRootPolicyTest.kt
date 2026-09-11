package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CellularRootPolicyTest {
    @Test
    fun nonAdmittedOwnerInstallsFailClosedBaseOnly() {
        val process = FakePolicyProcess()
        val policy = policy(process)

        val result = policy.reconcile(admitted = false, interfaceName = null)

        assertEquals(CellularRootPolicyResult.FailClosed(), result)
        assertTrue(process.ipv4Selector)
        assertTrue(process.ipv6Selector)
        assertTrue(process.ipv4Guard)
        assertTrue(process.ipv6Guard)
        assertNull(process.ipv4LookupTable)
    }

    @Test
    fun admittedOwnerInstallsValidatedCellularLookupBeforeGuard() {
        val process = FakePolicyProcess()
        val policy = policy(process)

        val result = policy.reconcile(admitted = true, interfaceName = "rmnet_data0")

        assertEquals(CellularRootPolicyResult.Enforced, result)
        assertEquals("1052", process.ipv4LookupTable)
        assertTrue(process.ipv4Guard)
        assertTrue(process.ipv6Guard)
    }

    @Test
    fun ownerLossRemovesLookupButKeepsSameMarkGuards() {
        val process = FakePolicyProcess()
        val policy = policy(process)
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )

        val result = policy.reconcile(admitted = false, interfaceName = null)

        assertEquals(CellularRootPolicyResult.FailClosed(), result)
        assertNull(process.ipv4LookupTable)
        assertTrue(process.ipv4Guard)
        assertTrue(process.ipv6Guard)
    }

    @Test
    fun unsafeInterfaceNeverReachesRootShell() {
        val process = FakePolicyProcess()
        val policy = policy(process)

        val result = policy.reconcile(admitted = true, interfaceName = "rmnet0;reboot")

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.InvalidInterface),
            result,
        )
        assertFalse(process.commands.any { it.contains("reboot") })
        assertNull(process.ipv4LookupTable)
        assertTrue(process.ipv4Guard)
    }

    @Test
    fun intentionalCloseRemovesOnlyExactProductRules() {
        val process = FakePolicyProcess()
        val policy = policy(process)
        policy.reconcile(admitted = true, interfaceName = "rmnet_data0")

        policy.close()

        assertNull(process.ipv4LookupTable)
        assertFalse(process.ipv4Guard)
        assertFalse(process.ipv6Guard)
        assertFalse(process.ipv4Selector)
        assertFalse(process.ipv6Selector)
    }

    private fun policy(process: FakePolicyProcess): CellularRootPolicy = CellularRootPolicy(
        productUid = 10123,
        authority = MagiskRootAuthority.forTesting(process),
        process = process,
    )

    private class FakePolicyProcess : RootProcess {
        var ipv4Selector = false
        var ipv6Selector = false
        var ipv4Guard = false
        var ipv6Guard = false
        var ipv4LookupTable: String? = null
        val commands = mutableListOf<String>()

        override fun run(arguments: List<String>): RootProcessResult {
            val command = arguments.last()
            commands += command
            return when {
                command == "id -u" -> ok("0\n")
                command == "ip -4 rule show" -> ok(ipv4Rules())
                command == "ip -6 rule show" -> ok(ipv6Rules())

                command.startsWith("iptables -t mangle -C OUTPUT") ->
                    if (ipv4Selector) ok() else fail()
                command.startsWith("iptables -t mangle -A OUTPUT") -> {
                    ipv4Selector = true
                    ok()
                }
                command.startsWith("iptables -t mangle -D OUTPUT") -> {
                    if (ipv4Selector) {
                        ipv4Selector = false
                        ok()
                    } else {
                        fail()
                    }
                }

                command.startsWith("ip6tables -t mangle -C OUTPUT") ->
                    if (ipv6Selector) ok() else fail()
                command.startsWith("ip6tables -t mangle -A OUTPUT") -> {
                    ipv6Selector = true
                    ok()
                }
                command.startsWith("ip6tables -t mangle -D OUTPUT") -> {
                    if (ipv6Selector) {
                        ipv6Selector = false
                        ok()
                    } else {
                        fail()
                    }
                }

                command == "ip -4 rule add pref 9501 fwmark 0x200000/0x200000 unreachable" -> {
                    ipv4Guard = true
                    ok()
                }
                command == "ip -6 rule add pref 9501 fwmark 0x200000/0x200000 unreachable" -> {
                    ipv6Guard = true
                    ok()
                }
                command == "ip -4 rule del pref 9501 fwmark 0x200000/0x200000 unreachable" -> {
                    if (ipv4Guard) {
                        ipv4Guard = false
                        ok()
                    } else {
                        fail()
                    }
                }
                command == "ip -6 rule del pref 9501 fwmark 0x200000/0x200000 unreachable" -> {
                    if (ipv6Guard) {
                        ipv6Guard = false
                        ok()
                    } else {
                        fail()
                    }
                }

                command == "ip -4 route show table all dev rmnet_data0" -> ok(
                    "default via 10.0.0.1 dev rmnet_data0 table 1052 proto static\n" +
                        "10.0.0.0/30 dev rmnet_data0 table 1052 scope link\n",
                )
                command == "ip -4 route show table 1052 default dev rmnet_data0" ->
                    ok("default via 10.0.0.1 dev rmnet_data0\n")
                command == "ip -4 route get 1.1.1.1 mark 0x200000" ->
                    if (ipv4LookupTable == "1052") {
                        ok("1.1.1.1 via 10.0.0.1 dev rmnet_data0 table 1052\n")
                    } else {
                        fail("RTNETLINK answers: Network is unreachable\n")
                    }

                command == "ip -4 rule add pref 9500 fwmark 0x200000/0x200000 lookup 1052" -> {
                    ipv4LookupTable = "1052"
                    ok()
                }
                command == "ip -4 rule del pref 9500 fwmark 0x200000/0x200000 lookup 1052" -> {
                    if (ipv4LookupTable == "1052") {
                        ipv4LookupTable = null
                        ok()
                    } else {
                        fail()
                    }
                }

                else -> fail("unsupported test command: $command")
            }
        }

        private fun ipv4Rules(): String = buildString {
            append("0: from all lookup local\n")
            ipv4LookupTable?.let {
                append("9500: from all fwmark 0x200000/0x200000 lookup $it\n")
            }
            if (ipv4Guard) {
                append("9501: from all fwmark 0x200000/0x200000 unreachable\n")
            }
            append("32766: from all lookup main\n")
        }

        private fun ipv6Rules(): String = buildString {
            append("0: from all lookup local\n")
            if (ipv6Guard) {
                append("9501: from all fwmark 0x200000/0x200000 unreachable\n")
            }
            append("32766: from all lookup main\n")
        }

        private fun ok(stdout: String = ""): RootProcessResult = RootProcessResult(0, stdout)
        private fun fail(stdout: String = ""): RootProcessResult = RootProcessResult(1, stdout)
    }
}
