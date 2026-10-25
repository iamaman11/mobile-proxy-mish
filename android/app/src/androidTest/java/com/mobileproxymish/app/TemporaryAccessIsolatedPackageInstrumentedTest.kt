package com.mobileproxymish.app

import android.content.ComponentName
import android.content.pm.PackageManager
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Before sensitive on-device tests, verify that this is a disposable, distinct UID
 * with automatic startup disabled. Never invoke these tests on the shipping package.
 */
class TemporaryAccessIsolatedPackageInstrumentedTest {
    @Test
    fun targetCannotReplaceOrAutoStartTheInstalledPrimaryProxy() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        assertTrue(BuildConfig.MISH_INSTRUMENTATION_ONLY)
        assertEquals("com.mobileproxymish.app.isolated.debug", BuildConfig.APPLICATION_ID)
        assertEquals(BuildConfig.APPLICATION_ID, context.packageName)
        assertFalse(context.packageName == "com.mobileproxymish.app.debug")

        val flags = PackageManager.MATCH_DISABLED_COMPONENTS
        val service = context.packageManager.getServiceInfo(
            ComponentName(context, ProxyRuntimeService::class.java), flags)
        val bootReceiver = context.packageManager.getReceiverInfo(
            ComponentName(context, ProxyRuntimeStartReceiver::class.java), flags)
        assertFalse(service.enabled)
        assertFalse(bootReceiver.enabled)
    }
}
