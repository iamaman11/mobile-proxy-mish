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

    private class FakeProcess(vararg results: RootProcessResult) : RootProcess {
        private val results = ArrayDeque(results.toList())
        var calls = 0
            private set

        override fun run(arguments: List<String>): RootProcessResult {
            calls += 1
            return results.removeFirst()
        }
    }
}
