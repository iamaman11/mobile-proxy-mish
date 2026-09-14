package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Test

class RootAuthorityRecoveryBackoffTest {
    @Test
    fun retryCadenceIsBoundedAndCapsAtOneMinute() {
        val backoff = RootAuthorityRecoveryBackoff()

        assertEquals(1_000L, backoff.nextDelayMs())
        assertEquals(5_000L, backoff.nextDelayMs())
        assertEquals(15_000L, backoff.nextDelayMs())
        assertEquals(30_000L, backoff.nextDelayMs())
        assertEquals(60_000L, backoff.nextDelayMs())
        assertEquals(60_000L, backoff.nextDelayMs())
    }

    @Test
    fun provenRecoveryResetsCadenceToFirstAttempt() {
        val backoff = RootAuthorityRecoveryBackoff()

        backoff.nextDelayMs()
        backoff.nextDelayMs()
        backoff.nextDelayMs()
        backoff.reset()

        assertEquals(1_000L, backoff.nextDelayMs())
    }

    @Test
    fun helperNeverEscapesBoundedCadence() {
        assertEquals(1_000L, rootAuthorityRecoveryDelayMs(-1))
        assertEquals(60_000L, rootAuthorityRecoveryDelayMs(Int.MAX_VALUE))
    }
}
