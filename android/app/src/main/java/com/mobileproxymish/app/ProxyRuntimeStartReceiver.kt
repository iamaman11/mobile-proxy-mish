package com.mobileproxymish.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Narrow system-broadcast adapter for restoring the foreground runtime after reboot/update.
 * User force-stop semantics remain Android-owned: force-stop prevents automatic relaunch until
 * the user explicitly starts the app again.
 */
class ProxyRuntimeStartReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            -> ProxyRuntimeService.requestStart(context)
        }
    }
}
