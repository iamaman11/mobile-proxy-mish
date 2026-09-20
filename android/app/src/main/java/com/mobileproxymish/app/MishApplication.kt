package com.mobileproxymish.app

import android.app.Application
import com.mobileproxymish.app.cellular.CellularRuntimeBridge

/**
 * Android composition root.
 *
 * The foreground service owns runtime lifetime. This Application only owns the restartable
 * process-local controller and never relies on Application.onTerminate(), which production
 * Android does not call when a process is killed.
 */
class MishApplication : Application() {
    /**
     * Android installs ContentProviders before Application.onCreate(). Diagnostics can therefore
     * race normal process startup. Synchronized lazy construction gives every process component
     * the same one controller without introducing a second desired-running or lifecycle owner.
     */
    val runtimeController: MishRuntimeController by lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
        MishRuntimeController(this)
    }

    /** Stable process adapter access retained only for narrow physical instrumentation. */
    val cellularRuntime: CellularRuntimeBridge
        get() = runtimeController.currentCellularRuntime

    /** Stable native Proxy projection retained only for narrow physical instrumentation. */
    val proxyRuntime: ProxyRuntimeSupervisor
        get() = runtimeController.currentProxyRuntime

    override fun onCreate() {
        super.onCreate()

        // Materialize the one process controller before requesting Service delivery. A diagnostics
        // provider call may have materialized the same lazy instance slightly earlier.
        runtimeController

        // Preserve the existing product expectation that an explicitly launched application
        // requests proxy availability. Modern Android may reject a background FGS start; that
        // failure is intentionally fail-closed and MainActivity requests it again from foreground.
        ProxyRuntimeService.requestStart(this)
    }
}
