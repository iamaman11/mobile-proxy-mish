package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CellularRootPolicyReachabilityTest {
    @Test
    fun inputAndForwardOnlyOverlapsAreOutsideOutputCollisionAuthority() {
        val lines = listOf(
            "-A INPUT -j MARK --set-xmark 0x200000/0x200000",
            "-A FORWARD -j CONNMARK --restore-mark --nfmask 0x200000 --ctmask 0x200000",
        )

        assertFalse(audit(lines, FIRST_MARK))
    }

    @Test
    fun directOutputOverlapCollides() {
        assertTrue(
            audit(
                listOf("-A OUTPUT -j MARK --set-xmark 0x0/0x200000"),
                FIRST_MARK,
            ),
        )
    }

    @Test
    fun outputReachableForeignChainOverlapCollides() {
        val lines = listOf(
            "-N FOREIGN_OUT",
            "-A OUTPUT -j FOREIGN_OUT",
            "-A FOREIGN_OUT -j MARK --set-xmark 0x200000/0x200000",
        )

        assertTrue(audit(lines, FIRST_MARK))
    }

    @Test
    fun nestedReachableChainOverlapCollides() {
        val lines = listOf(
            "-N FOREIGN_A",
            "-N FOREIGN_B",
            "-A OUTPUT --goto FOREIGN_A",
            "-A FOREIGN_A -j FOREIGN_B",
            "-A FOREIGN_B -j CONNMARK --save-mark --nfmask 0x200000 --ctmask 0x200000",
        )

        assertTrue(audit(lines, FIRST_MARK))
    }

    @Test
    fun unreachableForeignChainOverlapDoesNotCollide() {
        val lines = listOf(
            "-N UNUSED",
            "-A INPUT -j UNUSED",
            "-A UNUSED -j MARK --set-xmark 0x200000/0x200000",
        )

        assertFalse(audit(lines, FIRST_MARK))
    }

    @Test
    fun reachableMalformedMarkSemanticsFailClosed() {
        val lines = listOf("-A OUTPUT -j MARK --set-xmark not-a-mark")

        assertTrue(audit(lines, FIRST_MARK))
    }

    @Test
    fun reachableAmbiguousChainTransferFailsClosed() {
        val lines = listOf("-A OUTPUT -j")

        assertTrue(audit(lines, FIRST_MARK))
    }

    @Test
    fun connmarkDefaultMasksCollideBecauseTheyTouchAllBits() {
        val lines = listOf("-A OUTPUT -j CONNMARK --restore-mark")

        assertTrue(audit(lines, FIRST_MARK))
    }

    @Test
    fun overlappingRuleCanRejectFirstCandidateWhileLeavingSecondClean() {
        val lines = listOf("-A OUTPUT -j MARK --set-xmark 0x0/0x200000")

        assertTrue(audit(lines, FIRST_MARK))
        assertFalse(audit(lines, SECOND_MARK))
    }

    @Test
    fun unexpectedForeignReferenceToOwnedChainFailsClosedEvenWhenInputOnly() {
        val lines = listOf(
            "-N $OWNED_CHAIN",
            "-A INPUT -j $OWNED_CHAIN",
        )
        val allowed = setOf("-N $OWNED_CHAIN")

        assertTrue(
            OutputReachableMangleAudit.hasReservedCollision(
                lines = lines,
                allowedProductLines = allowed,
                reservedMark = FIRST_MARK,
                ownedChain = OWNED_CHAIN,
            ),
        )
    }

    @Test
    fun fullRpdbMarkMaskOverlapStillFailsAllCandidatesClosed() {
        val process = RpdbCollisionProcess()
        val policy = CellularRootPolicy(
            productUid = UID,
            authority = MagiskRootAuthority.forTesting(process),
            process = process,
        )

        assertEquals(
            CellularRootPolicyResult.FailClosed(CellularRootPolicyFailure.ReservedPolicyCollision),
            policy.reconcile(admitted = false, interfaceName = null),
        )
        assertFalse(process.commands.any { it.contains(" rule add ") || it.contains(" -N ") })
    }

    private fun audit(lines: List<String>, mark: ULong): Boolean =
        OutputReachableMangleAudit.hasReservedCollision(
            lines = lines,
            allowedProductLines = emptySet(),
            reservedMark = mark,
            ownedChain = OWNED_CHAIN,
        )

    private class RpdbCollisionProcess : RootProcess {
        val commands = mutableListOf<String>()

        override fun run(arguments: List<String>): RootProcessResult {
            val command = arguments.last()
            commands += command
            return when (command) {
                "id -u" -> ok("0\n")
                "ip -4 rule show" -> ok(
                    "0: from all lookup local\n" +
                        "12000: from all fwmark 0x0/0x1e00000 lookup main\n" +
                        "32766: from all lookup main\n",
                )
                "ip -6 rule show" -> ok("0: from all lookup local\n32766: from all lookup main\n")
                "iptables -t mangle -S", "ip6tables -t mangle -S" -> ok()
                else -> RootProcessResult(1, "unexpected mutation: $command")
            }
        }

        private fun ok(stdout: String = ""): RootProcessResult = RootProcessResult(0, stdout)
    }

    private companion object {
        const val UID = 10123
        const val OWNED_CHAIN = "MISH_EGRESS_V1"
        const val FIRST_MARK = 0x200000UL
        const val SECOND_MARK = 0x400000UL
    }
}
