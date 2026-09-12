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
    lateinit var runtimeController: MishRuntimeController
        private set

    /** Current generation access is retained only for narrow physical instrumentation. */
    val cellularRuntime: CellularRuntimeBridge
        get() = runtimeController.currentCellularRuntime

    /** Current generation access is retained only for narrow physical instrumentation. */
    val proxyRuntime: ProxyRuntimeSupervisor
        get() = runtimeController.currentProxyRuntime

    override fun onCreate() {
        super.onCreate()
        runtimeController = MishRuntimeController(this)

        // Preserve the existing product expectation that an explicitly launched application
        // requests proxy availability. Modern Android may reject a background FGS start; that
        // failure is intentionally fail-closed and MainActivity requests it again from foreground.
        ProxyRuntimeService.requestStart(this)
    }
}
