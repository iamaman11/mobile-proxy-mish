package com.mobileproxymish.app

import org.junit.Assert.assertEquals
import org.junit.Test

class ApplicationIdentityTest {
    @Test
    fun buildVariantUsesExpectedPackageIdentity() {
        val expected = if (BuildConfig.DEBUG) {
            "com.mobileproxymish.app.debug"
        } else {
            "com.mobileproxymish.app"
        }

        assertEquals(expected, BuildConfig.APPLICATION_ID)
    }
}
