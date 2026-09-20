package com.mobileproxymish.app

import android.app.Application
import android.content.Context
import com.mobileproxymish.app.cellular.CellularRuntimeBridge

/**
 * Android process composition root.
 *
 * Android attaches the Application before installing this process' ContentProviders. The one
 * process-local controller is therefore created exactly once during attachBaseContext(), before
 * any diagnostics provider can observe it. The foreground service still owns requested runtime
 * lifetime; this Application owns only process composition.
 */
class MishApplication : Application() {
    @Volatile
    private var runtimeControllerRef: MishRuntimeController? = null

    /**
     * Read-only access to the already-created process controller.
     *
     * This getter deliberately never creates PRODUCT state. A caller outside Android's normal
     * Application attach ordering fails closed instead of becoming an alternate runtime bootstrap.
     */
    val runtimeController: MishRuntimeController
        get() = checkNotNull(runtimeControllerRef) {
            "MishRuntimeController is unavailable before Application attach"
        }

    /** Stable process adapter access retained only for narrow physical instrumentation. */
    val cellularRuntime: CellularRuntimeBridge
        get() = runtimeController.currentCellularRuntime

    /** Stable native Proxy projection retained only for narrow physical instrumentation. */
    val proxyRuntime: ProxyRuntimeSupervisor
        get() = runtimeController.currentProxyRuntime

    override fun attachBaseContext(base: Context) {
        super.attachBaseContext(base)
        check(runtimeControllerRef == null) {
            "MishRuntimeController process composition was initialized more than once"
        }
        runtimeControllerRef = MishRuntimeController(this)
    }

    override fun onCreate() {
        super.onCreate()

        // Preserve the existing product expectation that an explicitly launched application
        // requests proxy availability. Modern Android may reject a background FGS start; that
        // failure is intentionally fail-closed and MainActivity requests it again from foreground.
        ProxyRuntimeService.requestStart(this)
    }
}
