package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Test

class MangleOutputCollisionAuditTest {
    @Test
    fun inputOnlyOverlappingMarkIsNotCollisionAuthority() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Clean,
            "-A INPUT -j MARK --set-xmark 0x0/0x200000",
        )
    }

    @Test
    fun forwardOnlyOverlappingMarkIsNotCollisionAuthority() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Clean,
            "-A FORWARD -j CONNMARK --restore-mark --nfmask 0x200000 --ctmask 0x200000",
        )
    }

    @Test
    fun directOutputOverlapCollides() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Collision,
            "-A OUTPUT -j MARK --set-xmark 0x0/0x200000",
        )
    }

    @Test
    fun outputJumpIntoForeignChainMakesThatChainAuthoritative() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Collision,
            "-N FOREIGN_OUT",
            "-A OUTPUT -j FOREIGN_OUT",
            "-A FOREIGN_OUT -j MARK --set-xmark 0x0/0x200000",
        )
    }

    @Test
    fun nestedReachableChainOverlapCollides() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Collision,
            "-N OUTER",
            "-N INNER",
            "-A OUTPUT -j OUTER",
            "-A OUTER -g INNER",
            "-A INNER -m mark --mark 0x0/0x200000 -j RETURN",
        )
    }

    @Test
    fun unreachableForeignChainOverlapDoesNotCollide() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Clean,
            "-N INPUT_HELPER",
            "-A INPUT -j INPUT_HELPER",
            "-A INPUT_HELPER -j MARK --set-xmark 0x0/0x200000",
        )
    }

    @Test
    fun unreachableMalformedMarkSemanticsAreNotCollisionAuthority() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Clean,
            "-N INPUT_HELPER",
            "-A INPUT -j INPUT_HELPER",
            "-A INPUT_HELPER -j MARK --set-xmark not-a-mark",
        )
    }

    @Test
    fun reachableMalformedMarkSemanticsFailClosed() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Ambiguous,
            "-A OUTPUT -j MARK --set-xmark not-a-mark",
        )
    }

    @Test
    fun reachableChainCycleFailsClosed() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Ambiguous,
            "-N FIRST",
            "-N SECOND",
            "-A OUTPUT -j FIRST",
            "-A FIRST -j SECOND",
            "-A SECOND -j FIRST",
        )
    }

    @Test
    fun nonOverlappingReachableMaskRemainsClean() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Clean,
            "-A OUTPUT -j MARK --set-xmark 0x0/0x100000",
        )
    }

    @Test
    fun foreignMishIdentityReferenceCollidesEvenWhenUnreachable() {
        assertAudit(
            MangleOutputCollisionAudit.Result.Collision,
            "-A INPUT -j MISH_EGRESS_V1",
        )
    }

    @Test
    fun exactAllowedProductJumpAndChainAreTraversableWithoutSelfCollision() {
        val allowed = setOf(
            "-N MISH_EGRESS_V1",
            "-A OUTPUT -m owner --uid-owner 10123 -j MISH_EGRESS_V1",
            "-A MISH_EGRESS_V1 -j CONNMARK --restore-mark --nfmask 0x200000 --ctmask 0x200000",
        )
        val result = MangleOutputCollisionAudit.audit(
            lines = allowed.toList(),
            allowedProductLines = allowed,
            mishChain = "MISH_EGRESS_V1",
            candidateMark = 0x200000UL,
        )

        assertEquals(MangleOutputCollisionAudit.Result.Clean, result)
    }

    private fun assertAudit(
        expected: MangleOutputCollisionAudit.Result,
        vararg lines: String,
    ) {
        assertEquals(
            expected,
            MangleOutputCollisionAudit.audit(
                lines = lines.toList(),
                allowedProductLines = emptySet(),
                mishChain = "MISH_EGRESS_V1",
                candidateMark = 0x200000UL,
            ),
        )
    }
}
