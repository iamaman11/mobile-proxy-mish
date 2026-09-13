package com.mobileproxymish.app

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Test

/**
 * Retained DEVICE-1 diagnostic: projects only typed owner state after a normal runtime restart.
 * It never prints endpoints, credentials, network handles, routes, DNS answers or process IDs.
 */
class RuntimeReadinessInstrumentedTest {
    @Test
    fun emitsTypedRestartReadinessProjection() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val app = context.applicationContext as MishApplication
        val proxy = app.runtimeController.proxySnapshot.value
        val readiness = app.runtimeController.readinessSnapshot.value

        println("MISH_RESTART_PROXY=${proxy.javaClass.simpleName}")
        println("MISH_RESTART_READINESS=$readiness")
    }
}
