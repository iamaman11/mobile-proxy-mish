package com.mobileproxymish.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64

/**
 * DUMP-permission-only read of the public control identity for one-time backend enrollment.
 *
 * The response contains only the stable device id and public SPKI. It never exposes the Android
 * Keystore private key, proxy credentials, manager token or control session material.
 */
class ControlIdentityProvisioningReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!isOrderedBroadcast) return
        if (intent.action != ACTION_READ) {
            setResult(RESULT_INVALID_REQUEST, null, null)
            return
        }

        val app = context.applicationContext as? MishApplication
        val snapshot = app?.runtimeController?.currentControlIdentityProvisioningSnapshot()
        if (snapshot == null) {
            setResult(RESULT_IDENTITY_UNAVAILABLE, null, null)
            return
        }

        val spki = Base64.encodeToString(snapshot.publicKeySpki, Base64.NO_WRAP)
        setResult(
            RESULT_OK,
            "mish-control-identity-v1:${snapshot.deviceId}:$spki",
            null,
        )
    }

    companion object {
        const val ACTION_READ = "com.mobileproxymish.app.action.READ_CONTROL_IDENTITY_V1"
        const val RESULT_OK = 1
        const val RESULT_INVALID_REQUEST = 20
        const val RESULT_IDENTITY_UNAVAILABLE = 21
    }
}

internal data class ControlIdentityProvisioningSnapshot(
    val deviceId: String,
    val publicKeySpki: ByteArray,
)
