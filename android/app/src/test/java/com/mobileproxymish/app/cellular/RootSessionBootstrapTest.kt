package com.mobileproxymish.app.cellular

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RootSessionBootstrapTest {
    @Test
    fun exactStaleOwnerJumpIsRemovedAndCurrentUidJumpIsPreserved() {
        val process = FakeBootstrapProcess(
            ipv4 = mutableListOf(
                "-A OUTPUT -m owner --uid-owner 11001 -j MISH_DEBUG_EGRESS_V1",
                "-A OUTPUT -m owner --uid-owner 12002 -j MISH_DEBUG_EGRESS_V1",
            ),
            ipv6 = mutableListOf(
                "-A OUTPUT -m owner --uid-owner 11001 -j MISH_DEBUG_EGRESS_V1",
            ),
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
    fun malformedOrForeignReferenceIsNeverDeletedByBootstrap() {
        val malformed = "-A OUTPUT -j MISH_DEBUG_EGRESS_V1"
        val process = FakeBootstrapProcess(
            ipv4 = mutableListOf(malformed),
            ipv6 = mutableListOf(),
        )
        val bootstrap = MishRootSessionBootstrap(
            productUid = 12002,
            mishChain = "MISH_DEBUG_EGRESS_V1",
        )

        assertTrue(bootstrap.reconcile(process))
        assertTrue(process.ipv4.contains(malformed))
        assertTrue(process.commands.none { it.contains(" -D OUTPUT ") })
    }

    @Test
    fun failedExactDeleteFailsClosedWithoutBroadCleanup() {
        val process = FakeBootstrapProcess(
            ipv4 = mutableListOf(
                "-A OUTPUT -m owner --uid-owner 11001 -j MISH_DEBUG_EGRESS_V1",
            ),
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
                command == "iptables -t mangle -S OUTPUT" -> ok(ipv4)
                command == "ip6tables -t mangle -S OUTPUT" -> ok(ipv6)
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
