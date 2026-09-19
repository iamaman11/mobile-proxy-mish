package com.mobileproxymish.app

import android.app.Activity
import android.os.Bundle
import android.util.Log

/**
 * Debug-only zero-input H acceptance seam for the normal PRODUCT stop path.
 *
 * It owns no recovery/platform policy. Rust drains the active rotation and restores airplane OFF
 * before the shared root session is shut down.
 */
class DebugRuntimeStopActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val runtime = (application as MishApplication).runtimeController
        val stopped = runtime.stop()
        Log.i(TAG, "stopped=" + stopped)
        finish()
    }

    private companion object {
        const val TAG = "MishRuntimeStopAcceptance"
    }
}
