package com.mobileproxymish.app

import android.app.Activity
import android.os.Bundle
import android.util.Log

/**
 * Debug-only zero-input H acceptance seam for the normal Android Service start request.
 *
 * It owns no recovery, retry, timing or network policy. It exercises the same production
 * ProxyRuntimeService.requestStart() boundary used by normal application lifecycle delivery.
 */
class DebugRuntimeStartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val accepted = ProxyRuntimeService.requestStart(this)
        Log.i(TAG, "accepted=" + accepted)
        finish()
    }

    private companion object {
        const val TAG = "MishRuntimeStartAcceptance"
    }
}
