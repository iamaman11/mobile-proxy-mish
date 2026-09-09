package com.mobileproxymish.app

import android.app.Application
import com.mobileproxymish.app.cellular.CellularRuntimeBridge

/**
 * Android composition root for one application-process generation.
 *
 * It owns wiring/lifetime only. Cellular policy remains in the Rust natural owner, and
 * this process-scoped lifetime is not a claim of final background-runtime readiness.
 */
class MishApplication : Application() {
    lateinit var cellularRuntime: CellularRuntimeBridge
        private set

    override fun onCreate() {
        super.onCreate()
        cellularRuntime = CellularRuntimeBridge(this).also(CellularRuntimeBridge::start)
    }
}
