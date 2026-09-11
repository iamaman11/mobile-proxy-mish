package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CellularRootPolicyTransitionTest {
    @Test
    fun detachedPartialChainIsCompletedBeforeOutputJumpCanReferenceIt() {
        val process = TransitionProcess().apply {
            ipv4ChainExists = true
            ipv4ChainRules += IPV4_CHAIN_RULES.take(2)
        }

        val result = policy(process).reconcile(admitted = false, interfaceName = null)

        assertEquals(CellularRootPolicyResult.FailClosed(), result)
        assertEquals(IPV4_CHAIN_RULES, process.ipv4ChainRules)
        assertEquals(IPV6_CHAIN_RULES, process.ipv6ChainRules)
        assertEquals(IPV4_CHAIN_RULES.size, process.ipv4RuleCountAtFirstJump)
        assertEquals(IPV6_CHAIN_RULES.size, process.ipv6RuleCountAtFirstJump)
        assertTrue(process.commands.indexOf(IPV4_FLUSH) < process.commands.indexOf(IPV4_JUMP_ADD))
        assertTrue(
            process.commands.indexOf("iptables -t mangle ${IPV4_CHAIN_RULES.last()}") <
                process.commands.indexOf(IPV4_JUMP_ADD),
        )
    }

    @Test
    fun referencedPartialVersionedChainFailsClosedWithoutLiveFlushOrRewrite() {
        val process = TransitionProcess().apply {
            ipv4ChainExists = true
            ipv4ChainRules += IPV4_CHAIN_RULES.take(2)
            ipv4JumpCount = 1
        }

        val result = policy(process).reconcile(admitted = false, interfaceName = null)

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.RuleMutationFailed),
            result,
        )
        assertEquals(1, process.ipv4JumpCount)
        assertEquals(IPV4_CHAIN_RULES.take(2), process.ipv4ChainRules)
        assertFalse(process.commands.contains(IPV4_FLUSH))
        assertFalse(process.commands.any { it.startsWith("iptables -t mangle -A $CHAIN ") })
    }

    @Test
    fun failedDetachedBuildNeverPublishesOutputJump() {
        val process = TransitionProcess().apply {
            failIpv4AppendAttempt = 3
        }

        val result = policy(process).reconcile(admitted = false, interfaceName = null)

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.RuleMutationFailed),
            result,
        )
        assertEquals(0, process.ipv4JumpCount)
        assertTrue(process.ipv4ChainExists)
        assertTrue(process.ipv4ChainRules.size < IPV4_CHAIN_RULES.size)
        assertFalse(process.commands.contains(IPV4_JUMP_ADD))
    }

    private fun policy(process: TransitionProcess): CellularRootPolicy = CellularRootPolicy(
        productUid = UID,
        authority = MagiskRootAuthority.forTesting(process),
        process = process,
    )

    private class TransitionProcess : RootProcess {
        var ipv4Guard = false
        var ipv6Guard = false
        var ipv4ChainExists = false
        var ipv6ChainExists = false
        var ipv4JumpCount = 0
        var ipv6JumpCount = 0
        var failIpv4AppendAttempt: Int? = null
        var ipv4RuleCountAtFirstJump: Int? = null
        var ipv6RuleCountAtFirstJump: Int? = null
        val ipv4ChainRules = mutableListOf<String>()
        val ipv6ChainRules = mutableListOf<String>()
        val commands = mutableListOf<String>()
        private var ipv4AppendAttempts = 0

        override fun run(arguments: List<String>): RootProcessResult {
            val command = arguments.last()
            commands += command
            return when {
                command == "id -u" -> ok("0\n")
                command == "ip -4 rule show" -> ok(ipv4Rules())
                command == "ip -6 rule show" -> ok(ipv6Rules())
                command == "iptables -t mangle -S" -> ok(ipv4Mangle())
                command == "ip6tables -t mangle -S" -> ok(ipv6Mangle())

                command == "iptables -t mangle -N $CHAIN" -> createChain(ipv4 = true)
                command == "ip6tables -t mangle -N $CHAIN" -> createChain(ipv4 = false)
                command == IPV4_FLUSH -> flushChain(ipv4 = true)
                command == IPV6_FLUSH -> flushChain(ipv4 = false)

                command == IPV4_JUMP_ADD -> {
                    if (!ipv4ChainExists) return fail()
                    if (ipv4RuleCountAtFirstJump == null) {
                        ipv4RuleCountAtFirstJump = ipv4ChainRules.size
                    }
                    ipv4JumpCount += 1
                    ok()
                }
                command == IPV6_JUMP_ADD -> {
                    if (!ipv6ChainExists) return fail()
                    if (ipv6RuleCountAtFirstJump == null) {
                        ipv6RuleCountAtFirstJump = ipv6ChainRules.size
                    }
                    ipv6JumpCount += 1
                    ok()
                }
                command == IPV4_JUMP_DELETE -> {
                    if (ipv4JumpCount == 0) fail() else {
                        ipv4JumpCount -= 1
                        ok()
                    }
                }
                command == IPV6_JUMP_DELETE -> {
                    if (ipv6JumpCount == 0) fail() else {
                        ipv6JumpCount -= 1
                        ok()
                    }
                }

                command.startsWith("iptables -t mangle -A $CHAIN ") -> appendIpv4(command)
                command.startsWith("ip6tables -t mangle -A $CHAIN ") -> appendIpv6(command)

                command == LEGACY_IPV4_CHECK || command == LEGACY_IPV6_CHECK -> fail()
                command == IPV4_GUARD_ADD -> {
                    ipv4Guard = true
                    ok()
                }
                command == IPV6_GUARD_ADD -> {
                    ipv6Guard = true
                    ok()
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
                if (!ipv4ChainExists || ipv4JumpCount != 0) return fail()
                ipv4ChainRules.clear()
            } else {
                if (!ipv6ChainExists || ipv6JumpCount != 0) return fail()
                ipv6ChainRules.clear()
            }
            return ok()
        }

        private fun appendIpv4(command: String): RootProcessResult {
            if (!ipv4ChainExists || ipv4JumpCount != 0) return fail()
            ipv4AppendAttempts += 1
            if (failIpv4AppendAttempt == ipv4AppendAttempts) return fail()
            ipv4ChainRules += command.removePrefix("iptables -t mangle ")
            return ok()
        }

        private fun appendIpv6(command: String): RootProcessResult {
            if (!ipv6ChainExists || ipv6JumpCount != 0) return fail()
            ipv6ChainRules += command.removePrefix("ip6tables -t mangle ")
            return ok()
        }

        private fun ipv4Rules(): String = buildString {
            append("0: from all lookup local\n")
            if (ipv4Guard) append("9501: from all fwmark 0x200000/0x200000 unreachable\n")
            append("32766: from all lookup main\n")
        }

        private fun ipv6Rules(): String = buildString {
            append("0: from all lookup local\n")
            if (ipv6Guard) append("9501: from all fwmark 0x200000/0x200000 unreachable\n")
            append("32766: from all lookup main\n")
        }

        private fun ipv4Mangle(): String = buildString {
            if (ipv4ChainExists) append("-N $CHAIN\n")
            repeat(ipv4JumpCount) { append(IPV4_JUMP_LINE).append('\n') }
            ipv4ChainRules.forEach { append(it).append('\n') }
        }

        private fun ipv6Mangle(): String = buildString {
            if (ipv6ChainExists) append("-N $CHAIN\n")
            repeat(ipv6JumpCount) { append(IPV6_JUMP_LINE).append('\n') }
            ipv6ChainRules.forEach { append(it).append('\n') }
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
        const val IPV4_FLUSH = "iptables -t mangle -F MISH_EGRESS_V1"
        const val IPV6_FLUSH = "ip6tables -t mangle -F MISH_EGRESS_V1"

        const val LEGACY_IPV4_CHECK =
            "iptables -t mangle -C OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
                "-j MARK --set-xmark 0x200000/0x200000"
        const val LEGACY_IPV6_CHECK =
            "ip6tables -t mangle -C OUTPUT -m owner --uid-owner 10123 -m conntrack --ctstate NEW " +
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
    }
}
