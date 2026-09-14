package com.mobileproxymish.app.cellular

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RootSessionBootstrapTest {
    @Test
    fun exactStaleOwnerJumpIsRemovedAndCurrentUidJumpIsPreserved() {
        val process = FakeBootstrapProcess(
            ipv4 = exactPolicy(ipv4 = true).toMutableList().apply {
                add("-A OUTPUT -m owner --uid-owner 11001 -j MISH_DEBUG_EGRESS_V1")
                add("-A OUTPUT -m owner --uid-owner 12002 -j MISH_DEBUG_EGRESS_V1")
            },
            ipv6 = exactPolicy(ipv4 = false).toMutableList().apply {
                add("-A OUTPUT -m owner --uid-owner 11001 -j MISH_DEBUG_EGRESS_V1")
            },
        )
        val bootstrap = MishRootSessionBootstrap(
            productUid = 12002,
            mishChain = "MISH_DEBUG_EGRESS_V1",
        )

        assertTrue(bootstrap.reconcile(process))
        assertFalse(process.ipv4.any { it.contains("--uid-owner 11001") })
        assertFalse(process.ipv6.any { it.contains("--uid-owner 11001") })
        assertTrue(process.ipv4.any { it.contains("--uid-owner 12002") })
        assertTrue(process.commands.none { it.contains(" -F ") || it.contains(" flush") })
    }

    @Test
    fun malformedChainWithExactStaleJumpIsNeverModified() {
        val stale = "-A OUTPUT -m owner --uid-owner 11001 -j MISH_DEBUG_EGRESS_V1"
        val process = FakeBootstrapProcess(
            ipv4 = mutableListOf(
                "-N MISH_DEBUG_EGRESS_V1",
                "-A MISH_DEBUG_EGRESS_V1 -j MARK --set-xmark 0xdead/0xdead",
                stale,
            ),
            ipv6 = mutableListOf(),
        )
        val bootstrap = MishRootSessionBootstrap(
            productUid = 12002,
            mishChain = "MISH_DEBUG_EGRESS_V1",
        )

        assertTrue(bootstrap.reconcile(process))
        assertTrue(process.ipv4.contains(stale))
        assertTrue(process.commands.none { it.contains(" -D OUTPUT ") })
    }

    @Test
    fun foreignReferenceToExactChainPreventsBootstrapMutation() {
        val stale = "-A OUTPUT -m owner --uid-owner 11001 -j MISH_DEBUG_EGRESS_V1"
        val process = FakeBootstrapProcess(
            ipv4 = exactPolicy(ipv4 = true).toMutableList().apply {
                add(stale)
                add("-A FORWARD -j MISH_DEBUG_EGRESS_V1")
            },
            ipv6 = mutableListOf(),
        )
        val bootstrap = MishRootSessionBootstrap(
            productUid = 12002,
            mishChain = "MISH_DEBUG_EGRESS_V1",
        )

        assertTrue(bootstrap.reconcile(process))
        assertTrue(process.ipv4.contains(stale))
        assertTrue(process.commands.none { it.contains(" -D OUTPUT ") })
    }

    @Test
    fun failedExactDeleteFailsClosedWithoutBroadCleanup() {
        val process = FakeBootstrapProcess(
            ipv4 = exactPolicy(ipv4 = true).toMutableList().apply {
                add("-A OUTPUT -m owner --uid-owner 11001 -j MISH_DEBUG_EGRESS_V1")
            },
            ipv6 = mutableListOf(),
            failDeletes = true,
        )
        val bootstrap = MishRootSessionBootstrap(
            productUid = 12002,
            mishChain = "MISH_DEBUG_EGRESS_V1",
        )

        assertFalse(bootstrap.reconcile(process))
        assertTrue(process.ipv4.any { it.contains("--uid-owner 11001") })
        assertTrue(process.commands.none { it.contains(" -F ") || it.contains(" flush") })
    }

    private fun exactPolicy(ipv4: Boolean): List<String> {
        val chain = "MISH_DEBUG_EGRESS_V1"
        val mark = "0x2000000"
        val loopback = if (ipv4) "127.0.0.0/8" else "::1/128"
        return listOf(
            "-N $chain",
            "-A $chain -d $loopback -j RETURN",
            "-A $chain -j CONNMARK --restore-mark --nfmask $mark --ctmask $mark",
            "-A $chain -m conntrack --ctstate NEW -j MARK --set-xmark $mark/$mark",
            "-A $chain -m conntrack --ctstate NEW -m mark --mark $mark/$mark " +
                "-j CONNMARK --save-mark --nfmask $mark --ctmask $mark",
        )
    }

    private class FakeBootstrapProcess(
        val ipv4: MutableList<String>,
        val ipv6: MutableList<String>,
        private val failDeletes: Boolean = false,
    ) : RootProcess {
        val commands = mutableListOf<String>()

        override fun run(arguments: List<String>): RootProcessResult {
            val command = arguments.last()
            commands += command
            return when {
                command == "iptables -t mangle -S" -> ok(ipv4)
                command == "ip6tables -t mangle -S" -> ok(ipv6)
                command.startsWith("iptables -t mangle -D OUTPUT ") ->
                    deleteExact(ipv4, command, "iptables")
                command.startsWith("ip6tables -t mangle -D OUTPUT ") ->
                    deleteExact(ipv6, command, "ip6tables")
                else -> RootProcessResult(1, "unsupported")
            }
        }

        private fun deleteExact(
            lines: MutableList<String>,
            command: String,
            binary: String,
        ): RootProcessResult {
            if (failDeletes) return RootProcessResult(1, "failed")
            val expectedLine = command.removePrefix("$binary -t mangle ")
                .replaceFirst("-D OUTPUT", "-A OUTPUT")
            return if (lines.remove(expectedLine)) {
                RootProcessResult(0, "")
            } else {
                RootProcessResult(1, "missing")
            }
        }

        private fun ok(lines: List<String>): RootProcessResult = RootProcessResult(
            exitCode = 0,
            stdout = lines.joinToString(separator = "\n", postfix = if (lines.isEmpty()) "" else "\n"),
        )
    }
}
