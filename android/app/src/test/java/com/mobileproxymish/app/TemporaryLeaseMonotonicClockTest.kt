package com.mobileproxymish.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TemporaryLeaseMonotonicClockTest {
    @Test
    fun sameBootMonotonicElapsedCannotBeExtendedByWallClockChange() {
        val anchor = TemporaryLeaseMonotonicClock.issue(4, 23_000, 1_800_000_000)
            ?: error("anchor")
        assertEquals(1_800_000_000uL, TemporaryLeaseMonotonicClock.observe(anchor, 4, 23_000))
        assertEquals(1_800_086_399uL,
            TemporaryLeaseMonotonicClock.observe(anchor, 4, 86_422_000))
        assertEquals(1_800_086_400uL,
            TemporaryLeaseMonotonicClock.observe(anchor, 4, 86_423_000))
        // Changing the wall clock never enters observe(): only kernel monotonic time matters.
    }

    @Test
    fun rebootAndClockCorruptionFailClosedWithoutRenewingLease() {
        val anchor = TemporaryLeaseMonotonicClock.issue(17, 200_000, 1_800_000_000)
            ?: error("anchor")
        assertNull(TemporaryLeaseMonotonicClock.observe(anchor, 18, 100_000))
        assertNull(TemporaryLeaseMonotonicClock.observe(anchor, 17, 199_999))
        assertNull(TemporaryLeaseMonotonicClock.observe(anchor, null, 210_000))
        assertNull(TemporaryLeaseMonotonicClock.observe(anchor, 17, 2_700_000_001L))
        assertNull(TemporaryLeaseMonotonicClock.issue(null, 10, 1_800_000_000))
        assertNull(TemporaryLeaseMonotonicClock.issue(1, 10, 0))
    }
}
