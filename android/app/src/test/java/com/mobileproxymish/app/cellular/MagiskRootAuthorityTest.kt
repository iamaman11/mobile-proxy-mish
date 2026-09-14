package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Test

class MagiskRootAuthorityTest {
    @Test
    fun readyRequiresRootAndRpdbRead() {
        val authority = MagiskRootAuthority.forTesting(
            FakeProcess(
                RootProcessResult(0, "0\n"),
                RootProcessResult(0, "0: from all lookup local\n"),
            ),
        )

        assertEquals(RootAuthorityStatus.Ready, authority.probe())
    }

    @Test
    fun readyIsCachedForSameRootSessionGeneration() {
        val process = FakeProcess(
            RootProcessResult(0, "0\n"),
            RootProcessResult(0, "0: from all lookup local\n"),
        ).apply { generation = 7L }
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        assertEquals(2, process.calls)
    }

    @Test
    fun newRootSessionGenerationRequiresFreshAuthorityProof() {
        val process = FakeProcess(
            RootProcessResult(0, "0\n"),
            RootProcessResult(0, "0: from all lookup local\n"),
            RootProcessResult(0, "0\n"),
            RootProcessResult(0, "0: from all lookup local\n"),
        ).apply { generation = 7L }
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        process.generation = 8L
        assertEquals(RootAuthorityStatus.Ready, authority.probe())
        assertEquals(4, process.calls)
    }

    @Test
    fun deniedDoesNotAttemptSecondCommand() {
        val process = FakeProcess(RootProcessResult(1, "denied"))
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Denied, authority.probe())
        assertEquals(1, process.calls)
    }

    @Test
    fun timeoutMeansInteractiveGrantRequired() {
        val authority = MagiskRootAuthority.forTesting(
            FakeProcess(RootProcessResult(-1, "", timedOut = true)),
        )

        assertEquals(RootAuthorityStatus.InteractiveGrantRequired, authority.probe())
    }

    @Test
    fun incompleteIdentityOutputNeverGrantsRootAuthority() {
        val process = FakeProcess(
            RootProcessResult(0, "0\n", outputComplete = false),
        )
        val authority = MagiskRootAuthority.forTesting(process)

        assertEquals(RootAuthorityStatus.Incomplete, authority.probe())
        assertEquals(1, process.calls)
    }

    @Test
    fun incompleteRpdbOutputNeverGrantsRootAuthority() {
        val authority = MagiskRootAuthority.forTesting(
            FakeProcess(
                RootProcessResult(0, "0\n"),
                RootProcessResult(
                    0,
                    "0: from all lookup local\n",
                    outputComplete = false,
                ),
            ),
        )

        assertEquals(RootAuthorityStatus.Incomplete, authority.probe())
    }

    private class FakeProcess(vararg results: RootProcessResult) : RootProcess {
        private val results = ArrayDeque(results.toList())
        var calls = 0
            private set
        var generation: Long? = null

        override fun run(arguments: List<String>): RootProcessResult {
            calls += 1
            return results.removeFirst()
        }

        override fun sessionGeneration(): Long? = generation
    }
}
