package com.mobileproxymish.app.cellular

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CellularInterfaceHintsTest {
    @Test
    fun ownerSelectedHandleUsesItsOwnInterfaceAfterUnrelatedObservation() {
        val hints = CellularInterfaceHints()
        hints.observed(11uL, "rmnet_data0")
        hints.observed(22uL, "rmnet_data1")

        assertEquals("rmnet_data0", hints.interfaceFor(11uL))
        assertEquals("rmnet_data1", hints.interfaceFor(22uL))
    }

    @Test
    fun losingSupersededHandleDoesNotRemoveCurrentInterface() {
        val hints = CellularInterfaceHints()
        hints.observed(11uL, "rmnet_data0")
        hints.observed(22uL, "rmnet_data1")

        hints.lost(11uL)

        assertNull(hints.interfaceFor(11uL))
        assertEquals("rmnet_data1", hints.interfaceFor(22uL))
    }

    @Test
    fun transientMissingLinkPropertiesDoesNotEraseExactHandleHint() {
        val hints = CellularInterfaceHints()
        hints.observed(11uL, "rmnet_data0")

        hints.observed(11uL, null)

        assertEquals("rmnet_data0", hints.interfaceFor(11uL))
    }

    @Test
    fun missingInitialInterfaceStillFailsClosedUntilResolved() {
        val hints = CellularInterfaceHints()

        hints.observed(11uL, null)

        assertNull(hints.interfaceFor(11uL))
    }

    @Test
    fun sameHandleCanMoveToNewObservedInterfaceWithoutCrossHandleReuse() {
        val hints = CellularInterfaceHints()
        hints.observed(11uL, "rmnet_data0")
        hints.observed(22uL, "rmnet_data1")

        hints.observed(11uL, "rmnet_data2")

        assertEquals("rmnet_data2", hints.interfaceFor(11uL))
        assertEquals("rmnet_data1", hints.interfaceFor(22uL))
    }
}
