package com.mobileproxymish.app

import android.app.Activity
import android.os.Bundle
import android.util.Log

/**
 * Debug-only zero-input U5 physical-acceptance trigger.
 *
 * ADB may launch this Activity, but it never issues an airplane/root/network command itself.
 * It delegates exactly one request to the Rust-owned PRODUCT rotation operation and exits.
 * Release manifests exclude it.
 */
class DebugRotationActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val runtime = (application as MishApplication).runtimeController
        runCatching(runtime::startPublicIpRotation)
            .onSuccess { operationId ->
                Log.i(TAG, "accepted=true operation_id=" + operationId)
            }
            .onFailure { error ->
                Log.e(TAG, "accepted=false failure=" + error::class.java.simpleName)
            }
        finish()
    }

    private companion object {
        const val TAG = "MishRotationAcceptance"
    }
}
