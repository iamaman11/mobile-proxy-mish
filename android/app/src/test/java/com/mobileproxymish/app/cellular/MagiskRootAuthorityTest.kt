package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class MagiskRootAuthorityTest {
    @Test
    fun readyRequiresRootAndRpdbRead() {
        val process = FakeProcess(
            RootCommandResult(0, "0\n"),
            RootCommandResult(0, "0: from all lookup local\n"),
        )
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        assertTrue(process.effects.all { it is RootObservation })
    }

    @Test
    fun readyIsCachedForSameRootSessionGeneration() {
        val process = FakeProcess(
            RootCommandResult(0, "0\n"),
            RootCommandResult(0, "0: from all lookup local\n"),
        ).apply { generation = 7L }
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        assertEquals(2, process.calls)
    }

    @Test
    fun newRootSessionGenerationRequiresFreshAuthorityProof() {
        val process = FakeProcess(
            RootCommandResult(0, "0\n"),
            RootCommandResult(0, "0: from all lookup local\n"),
            RootCommandResult(0, "0\n"),
            RootCommandResult(0, "0: from all lookup local\n"),
        ).apply { generation = 7L }
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        process.generation = 8L
        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        assertEquals(4, process.calls)
    }

    @Test
    fun deniedIsTerminalForCurrentAppProcess() {
        val process = FakeProcess(RootCommandResult(1, "denied"))
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Denied, authority.probe())
        assertEquals(RootAuthorityStatus.Denied, authority.probe())
        assertEquals(1, process.calls)
    }

    @Test
    fun provenNonZeroDenialIsTerminalEvenWhenOutputWasTruncated() {
        val process = FakeProcess(
            RootCommandResult(
                exitCode = 1,
                stdout = "",
                outputComplete = false,
            ),
        )
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Denied, authority.probe())
        assertEquals(RootAuthorityStatus.Denied, authority.probe())
        assertEquals(1, process.calls)
    }

    @Test
    fun unansweredInteractiveGrantIsTerminalForCurrentAppProcess() {
        val process = FakeProcess(RootCommandResult(-1, "", timedOut = true))
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.InteractiveGrantRequired, authority.probe())
        assertEquals(RootAuthorityStatus.InteractiveGrantRequired, authority.probe())
        assertEquals(1, process.calls)
    }

    @Test
    fun onlyTransientAuthorityStatesAreAutomaticallyRetried() {
        assertTrue(shouldRetryRootAuthority(RootAuthorityStatus.Unavailable))
        assertTrue(shouldRetryRootAuthority(RootAuthorityStatus.Incomplete))
        assertFalse(shouldRetryRootAuthority(RootAuthorityStatus.Ready))
        assertFalse(shouldRetryRootAuthority(RootAuthorityStatus.Denied))
        assertFalse(shouldRetryRootAuthority(RootAuthorityStatus.InteractiveGrantRequired))
    }

    @Test
    fun prematureNonZeroSuExitPreservesDenialEvidence() {
        assertEquals(
            RootCommandResult(
                exitCode = 1,
                stdout = "permission denied\n",
            ),
            SuProcess.prematureExitResult(
                exitCode = 1,
                stdout = "permission denied\n",
                outputComplete = true,
            ),
        )
    }

    @Test
    fun prematureZeroSuExitNeverClaimsCommandCompletion() {
        assertEquals(
            RootCommandResult(
                exitCode = -1,
                stdout = "",
                outputComplete = false,
            ),
            SuProcess.prematureExitResult(
                exitCode = 0,
                stdout = "0\n",
                outputComplete = true,
            ),
        )
    }

    @Test
    fun incompleteIdentityOutputNeverGrantsRootAuthority() {
        val process = FakeProcess(
            RootCommandResult(0, "0\n", outputComplete = false),
        )
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Incomplete, authority.probe())
        assertEquals(1, process.calls)
    }

    @Test
    fun incompleteRpdbOutputNeverGrantsRootAuthority() {
        val authority = MagiskRootAuthority.forTesting(
            FakeProcess(
                RootCommandResult(0, "0\n"),
                RootCommandResult(
                    0,
                    "0: from all lookup local\n",
                    outputComplete = false,
                ),
            ),
        )

        assertEquals(RootAuthorityStatus.Incomplete, authority.probe())
    }

    private class FakeProcess(vararg results: RootCommandResult) : RootCommandTransport {
        private val results = ArrayDeque(results.toList())
        var calls = 0
            private set
        var generation: Long? = null

        val effects = mutableListOf<RootEffect>()

        override fun execute(effect: RootEffect): RootCommandResult {
            calls += 1
            effects += effect
            return results.removeFirst()
        }

        override fun sessionGeneration(): Long? = generation
    }
}
