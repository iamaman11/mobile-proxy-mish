package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CellularRootPolicyTest {
    @Test
    fun nonAdmittedOwnerBuildsExactFailClosedFlowPolicy() {
        val process = FakePolicyProcess()
        val policy = policy(process)

        val result = policy.reconcile(admitted = false, interfaceName = null)

        assertEquals(CellularRootPolicyResult.FailClosed(), result)
        assertTrue(process.ipv4Guard)
        assertTrue(process.ipv6Guard)
        assertNull(process.ipv4LookupTable)
        assertEquals(1, process.ipv4JumpCount)
        assertEquals(1, process.ipv6JumpCount)
        assertEquals(IPV4_CHAIN_RULES, process.ipv4ChainRules)
        assertEquals(IPV6_CHAIN_RULES, process.ipv6ChainRules)
    }

    @Test
    fun flowPolicyExcludesLoopbackAndPersistsOnlySelectedConnections() {
        val process = FakePolicyProcess()
        val policy = policy(process)

        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )

        assertEquals("-A $CHAIN -d 127.0.0.0/8 -j RETURN", process.ipv4ChainRules[0])
        assertEquals("-A $CHAIN -d ::1/128 -j RETURN", process.ipv6ChainRules[0])
        assertTrue(process.ipv4ChainRules[1].contains("CONNMARK --restore-mark"))
        assertTrue(process.ipv4ChainRules[2].contains("--ctstate NEW -j MARK"))
        assertTrue(process.ipv4ChainRules[3].contains("--ctstate NEW"))
        assertTrue(process.ipv4ChainRules[3].contains("CONNMARK --save-mark"))
        assertTrue(process.ipv4ChainRules[3].contains("--nfmask 0x200000 --ctmask 0x200000"))
    }

    @Test
    fun admittedOwnerInstallsValidatedCellularLookupAfterFailClosedBase() {
        val process = FakePolicyProcess()
        val policy = policy(process)

        val result = policy.reconcile(admitted = true, interfaceName = "rmnet_data0")

        assertEquals(CellularRootPolicyResult.Enforced, result)
        assertEquals("1052", process.ipv4LookupTable)
        assertTrue(process.ipv4Guard)
        assertTrue(process.ipv6Guard)
        val guardAdd = process.commands.indexOf(IPV4_GUARD_ADD)
        val jumpAdd = process.commands.indexOf(IPV4_JUMP_ADD)
        val lookupAdd = process.commands.indexOf(IPV4_LOOKUP_ADD)
        assertTrue(guardAdd >= 0)
        assertTrue(jumpAdd >= 0)
        assertTrue(lookupAdd >= 0)
        assertTrue(guardAdd < jumpAdd)
        assertTrue(jumpAdd < lookupAdd)
    }

    @Test
    fun ownerLossRemovesLookupButRetainsFlowMarkAndGuard() {
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
        assertEquals(IPV4_CHAIN_RULES, process.ipv4ChainRules)
        assertTrue(process.ipv4ChainRules.any { it.contains("CONNMARK --restore-mark") })
    }

    @Test
    fun repeatedReconcileIsIdempotentAndRediscoveriesCurrentTable() {
        val process = FakePolicyProcess()
        val policy = policy(process)

        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )
        val secondStart = process.commands.size
        assertEquals(
            CellularRootPolicyResult.Enforced,
            policy.reconcile(admitted = true, interfaceName = "rmnet_data0"),
        )

        assertEquals(1, process.ipv4JumpCount)
        assertEquals(1, process.ipv6JumpCount)
        assertEquals(IPV4_CHAIN_RULES, process.ipv4ChainRules)
        assertEquals(IPV6_CHAIN_RULES, process.ipv6ChainRules)
        val second = process.commands.drop(secondStart)
        assertTrue(second.indexOf(IPV4_LOOKUP_DELETE) >= 0)
        assertTrue(second.indexOf("ip -4 route show table all dev rmnet_data0") >= 0)
        assertTrue(second.indexOf(IPV4_LOOKUP_ADD) >= 0)
        assertTrue(
            second.indexOf(IPV4_LOOKUP_DELETE) <
                second.indexOf("ip -4 route show table all dev rmnet_data0"),
        )
    }

    @Test
    fun legacyNewOnlySelectorMigratesIntoNamedFlowPolicy() {
        val process = FakePolicyProcess().apply {
            legacyIpv4Selector = true
            legacyIpv6Selector = true
        }
        val policy = policy(process)

        val result = policy.reconcile(admitted = false, interfaceName = null)

        assertEquals(CellularRootPolicyResult.FailClosed(), result)
        assertFalse(process.legacyIpv4Selector)
        assertFalse(process.legacyIpv6Selector)
        assertEquals(1, process.ipv4JumpCount)
        assertEquals(1, process.ipv6JumpCount)
    }

    @Test
    fun foreignRpdbPriorityCollisionFailsClosedWithoutMutation() {
        val process = FakePolicyProcess().apply {
            foreignIpv4Rpdb += "9500: from all lookup main"
        }
        val policy = policy(process)

        val result = policy.reconcile(admitted = true, interfaceName = "rmnet_data0")

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.ReservedPolicyCollision),
            result,
        )
        assertFalse(process.ipv4Guard)
        assertEquals(0, process.ipv4JumpCount)
        assertNull(process.ipv4LookupTable)
    }

    @Test
    fun foreignReservedMarkCollisionFailsClosedWithoutDeletingIt() {
        val foreign = "-A OUTPUT -j MARK --set-xmark 0x200000/0x200000"
        val process = FakePolicyProcess().apply {
            foreignIpv4Mangle += foreign
        }
        val policy = policy(process)

        val result = policy.reconcile(admitted = false, interfaceName = null)

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.ReservedPolicyCollision),
            result,
        )
        assertTrue(process.foreignIpv4Mangle.contains(foreign))
        assertEquals(0, process.ipv4JumpCount)
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
    fun incompleteRpdbSnapshotFailsClosedInsteadOfLookingEmpty() {
        val process = FakePolicyProcess().apply {
            incompleteIpv4RuleReadAt = 2
        }
        val policy = policy(process)

        val result = policy.reconcile(admitted = false, interfaceName = null)

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.VerificationFailed),
            result,
        )
        assertFalse(process.ipv4Guard)
        assertEquals(0, process.ipv4JumpCount)
    }

    @Test
    fun intentionalCloseRemovesOnlyExactProductPolicy() {
        val process = FakePolicyProcess()
        val policy = policy(process)
        policy.reconcile(admitted = true, interfaceName = "rmnet_data0")

        policy.close()

        assertNull(process.ipv4LookupTable)
        assertFalse(process.ipv4Guard)
        assertFalse(process.ipv6Guard)
        assertFalse(process.ipv4ChainExists)
        assertFalse(process.ipv6ChainExists)
        assertEquals(0, process.ipv4JumpCount)
        assertEquals(0, process.ipv6JumpCount)
    }

    private fun policy(process: FakePolicyProcess): CellularRootPolicy = CellularRootPolicy(
        productUid = UID,
        authority = MagiskRootAuthority.forTesting(process),
        process = process,
    )

    private class FakePolicyProcess : RootProcess {
        var ipv4Guard = false
        var ipv6Guard = false
        var ipv4LookupTable: String? = null
        var ipv4ChainExists = false
        var ipv6ChainExists = false
        var ipv4JumpCount = 0
        var ipv6JumpCount = 0
        var legacyIpv4Selector = false
        var legacyIpv6Selector = false
        var incompleteIpv4RuleReadAt: Int? = null
        val ipv4ChainRules = mutableListOf<String>()
        val ipv6ChainRules = mutableListOf<String>()
        val foreignIpv4Rpdb = mutableListOf<String>()
        val foreignIpv6Rpdb = mutableListOf<String>()
        val foreignIpv4Mangle = mutableListOf<String>()
        val foreignIpv6Mangle = mutableListOf<String>()
        val commands = mutableListOf<String>()
        private var ipv4RuleReads = 0

        override fun run(arguments: List<String>): RootProcessResult {
            val command = arguments.last()
            commands += command
            return when {
                command == "id -u" -> ok("0\n")
                command == "ip -4 rule show" -> {
                    ipv4RuleReads += 1
                    RootProcessResult(
                        exitCode = 0,
                        stdout = ipv4Rules(),
                        outputComplete = ipv4RuleReads != incompleteIpv4RuleReadAt,
                    )
                }
                command == "ip -6 rule show" -> ok(ipv6Rules())
                command == "iptables -t mangle -S" -> ok(ipv4Mangle())
                command == "ip6tables -t mangle -S" -> ok(ipv6Mangle())

                command == "iptables -t mangle -N $CHAIN" -> createChain(ipv4 = true)
                command == "ip6tables -t mangle -N $CHAIN" -> createChain(ipv4 = false)
                command == "iptables -t mangle -F $CHAIN" -> flushChain(ipv4 = true)
                command == "ip6tables -t mangle -F $CHAIN" -> flushChain(ipv4 = false)
                command == "iptables -t mangle -X $CHAIN" -> deleteChain(ipv4 = true)
                command == "ip6tables -t mangle -X $CHAIN" -> deleteChain(ipv4 = false)

                command == IPV4_JUMP_ADD -> {
                    if (!ipv4ChainExists) fail() else { ipv4JumpCount += 1; ok() }
                }
                command == IPV6_JUMP_ADD -> {
                    if (!ipv6ChainExists) fail() else { ipv6JumpCount += 1; ok() }
                }
                command == IPV4_JUMP_DELETE -> {
                    if (ipv4JumpCount > 0) { ipv4JumpCount -= 1; ok() } else fail()
                }
                command == IPV6_JUMP_DELETE -> {
                    if (ipv6JumpCount > 0) { ipv6JumpCount -= 1; ok() } else fail()
                }

                command.startsWith("iptables -t mangle -A $CHAIN ") ->
                    appendChain(command, ipv4 = true)
                command.startsWith("ip6tables -t mangle -A $CHAIN ") ->
                    appendChain(command, ipv4 = false)

                command == LEGACY_IPV4_CHECK -> if (legacyIpv4Selector) ok() else fail()
                command == LEGACY_IPV6_CHECK -> if (legacyIpv6Selector) ok() else fail()
                command == LEGACY_IPV4_DELETE -> {
                    if (legacyIpv4Selector) { legacyIpv4Selector = false; ok() } else fail()
                }
                command == LEGACY_IPV6_DELETE -> {
                    if (legacyIpv6Selector) { legacyIpv6Selector = false; ok() } else fail()
                }

                command == IPV4_GUARD_ADD -> { ipv4Guard = true; ok() }
                command == IPV6_GUARD_ADD -> { ipv6Guard = true; ok() }
                command == IPV4_GUARD_DELETE -> {
                    if (ipv4Guard) { ipv4Guard = false; ok() } else fail()
                }
                command == IPV6_GUARD_DELETE -> {
                    if (ipv6Guard) { ipv6Guard = false; ok() } else fail()
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

                command == IPV4_LOOKUP_ADD -> { ipv4LookupTable = "1052"; ok() }
                command == IPV4_LOOKUP_DELETE -> {
                    if (ipv4LookupTable == "1052") { ipv4LookupTable = null; ok() } else fail()
                }
                else -> fail("unsupported test command: $command")
            }
        }

        private fun createChain(ipv4: Boolean): RootProcessResult {
            if (ipv4) {
                if (ipv4ChainExists) return fail()
                ipv4ChainExists = true
            } else {
                if (ipv6ChainExists) return fail()
                ipv6ChainExists = true
            }
            return ok()
        }

        private fun flushChain(ipv4: Boolean): RootProcessResult {
            if (ipv4) {
                if (!ipv4ChainExists) return fail()
                ipv4ChainRules.clear()
            } else {
                if (!ipv6ChainExists) return fail()
                ipv6ChainRules.clear()
            }
            return ok()
        }

        private fun deleteChain(ipv4: Boolean): RootProcessResult {
            if (ipv4) {
                if (!ipv4ChainExists || ipv4JumpCount != 0 || ipv4ChainRules.isNotEmpty()) return fail()
                ipv4ChainExists = false
            } else {
                if (!ipv6ChainExists || ipv6JumpCount != 0 || ipv6ChainRules.isNotEmpty()) return fail()
                ipv6ChainExists = false
            }
            return ok()
        }

        private fun appendChain(command: String, ipv4: Boolean): RootProcessResult {
            val prefix = if (ipv4) "iptables -t mangle " else "ip6tables -t mangle "
            val line = command.removePrefix(prefix)
            if (ipv4) {
                if (!ipv4ChainExists) return fail()
                ipv4ChainRules += line
            } else {
                if (!ipv6ChainExists) return fail()
                ipv6ChainRules += line
            }
            return ok()
        }

        private fun ipv4Rules(): String = buildString {
            append("0: from all lookup local\n")
            foreignIpv4Rpdb.forEach { append(it).append('\n') }
            ipv4LookupTable?.let {
                append("9500: from all fwmark 0x200000/0x200000 lookup $it\n")
            }
            if (ipv4Guard) append("9501: from all fwmark 0x200000/0x200000 unreachable\n")
            append("32766: from all lookup main\n")
        }

        private fun ipv6Rules(): String = buildString {
            append("0: from all lookup local\n")
            foreignIpv6Rpdb.forEach { append(it).append('\n') }
            if (ipv6Guard) append("9501: from all fwmark 0x200000/0x200000 unreachable\n")
            append("32766: from all lookup main\n")
        }

        private fun ipv4Mangle(): String = buildString {
            if (ipv4ChainExists) append("-N $CHAIN\n")
            repeat(ipv4JumpCount) { append(IPV4_JUMP_LINE).append('\n') }
            if (legacyIpv4Selector) append(LEGACY_IPV4_LINE).append('\n')
            ipv4ChainRules.forEach { append(it).append('\n') }
            foreignIpv4Mangle.forEach { append(it).append('\n') }
        }

        private fun ipv6Mangle(): String = buildString {
            if (ipv6ChainExists) append("-N $CHAIN\n")
            repeat(ipv6JumpCount) { append(IPV6_JUMP_LINE).append('\n') }
            if (legacyIpv6Selector) append(LEGACY_IPV6_LINE).append('\n')
            ipv6ChainRules.forEach { append(it).append('\n') }
            foreignIpv6Mangle.forEach { append(it).append('\n') }
        }

        private fun ok(stdout: String = ""): RootProcessResult = RootProcessResult(0, stdout)
        private fun fail(stdout: String = ""): RootProcessResult = RootProcessResult(1, stdout)
    }

    private companion object {
        const val UID = 10123
        const val CHAIN = "MISH_EGRESS_V1"
        const val IPV4_JUMP_LINE = "-A OUTPUT -m owner --uid-owner 10123 -j MISH_EGRESS_V1"
        const val IPV6_JUMP_LINE = IPV4_JUMP_LINE
        const val IPV4_JUMP_ADD = "iptables -t mangle $IPV4_JUMP_LINE"
        const val IPV6_JUMP_ADD = "ip6tables -t mangle $IPV6_JUMP_LINE"
        const val IPV4_JUMP_DELETE =
            "iptables -t mangle -D OUTPUT -m owner --uid-owner 10123 -j MISH_EGRESS_V1"
        const val IPV6_JUMP_DELETE =
            "ip6tables -t mangle -D OUTPUT -m owner --uid-owner 10123 -j MISH_EGRESS_V1"

        const val LEGACY_IPV4_LINE =
            "-A OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV6_LINE = LEGACY_IPV4_LINE
        const val LEGACY_IPV4_CHECK =
            "iptables -t mangle -C OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV6_CHECK =
            "ip6tables -t mangle -C OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV4_DELETE =
            "iptables -t mangle -D OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV6_DELETE =
            "ip6tables -t mangle -D OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"

        val IPV4_CHAIN_RULES = listOf(
            "-A $CHAIN -d 127.0.0.0/8 -j RETURN",
            "-A $CHAIN -j CONNMARK --restore-mark --nfmask 0x200000 --ctmask 0x200000",
            "-A $CHAIN -m conntrack --ctstate NEW -j MARK --set-xmark 0x200000/0x200000",
            "-A $CHAIN -m conntrack --ctstate NEW -m mark --mark 0x200000/0x200000 " +
                "-j CONNMARK --save-mark --nfmask 0x200000 --ctmask 0x200000",
        )
        val IPV6_CHAIN_RULES = listOf(
            "-A $CHAIN -d ::1/128 -j RETURN",
            "-A $CHAIN -j CONNMARK --restore-mark --nfmask 0x200000 --ctmask 0x200000",
            "-A $CHAIN -m conntrack --ctstate NEW -j MARK --set-xmark 0x200000/0x200000",
            "-A $CHAIN -m conntrack --ctstate NEW -m mark --mark 0x200000/0x200000 " +
                "-j CONNMARK --save-mark --nfmask 0x200000 --ctmask 0x200000",
        )

        const val IPV4_GUARD_ADD =
            "ip -4 rule add pref 9501 fwmark 0x200000/0x200000 unreachable"
        const val IPV6_GUARD_ADD =
            "ip -6 rule add pref 9501 fwmark 0x200000/0x200000 unreachable"
        const val IPV4_GUARD_DELETE =
            "ip -4 rule del pref 9501 fwmark 0x200000/0x200000 unreachable"
        const val IPV6_GUARD_DELETE =
            "ip -6 rule del pref 9501 fwmark 0x200000/0x200000 unreachable"
        const val IPV4_LOOKUP_ADD =
            "ip -4 rule add pref 9500 fwmark 0x200000/0x200000 lookup 1052"
        const val IPV4_LOOKUP_DELETE =
            "ip -4 rule del pref 9500 fwmark 0x200000/0x200000 lookup 1052"
    }
}
