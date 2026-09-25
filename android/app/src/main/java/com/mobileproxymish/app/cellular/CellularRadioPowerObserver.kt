package com.mobileproxymish.app.cellular

import android.content.Context
import android.telephony.PhoneStateListener
import android.telephony.ServiceState
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import java.io.Closeable
import java.util.concurrent.Executor

/**
 * Thin Android telephony boundary for the one positive radio-power fact used by Rust Rotation.
 *
 * This class owns no Rotation phase, timeout, dwell, recovery or currentness decision.
 * It only subscribes to the configured data subscription and forwards STATE_POWER_OFF. Rust
 * decides whether the callback belongs to an active operation and whether any transition follows.
 */
@Suppress("DEPRECATION")
internal class CellularRadioPowerObserver(
    context: Context,
    private val onRadioPowerOff: () -> Unit,
) : Closeable {
    private val baseManager = context.getSystemService(TelephonyManager::class.java)
        ?: error("TelephonyManager is unavailable")
    private val directExecutor = Executor { command -> command.run() }

    private var scopedManager: TelephonyManager? = null
    private var listener: PhoneStateListener? = null

    @Synchronized
    fun start() {
        if (listener != null) return

        val activeDataSubscriptionId = SubscriptionManager.getActiveDataSubscriptionId()
        val subscriptionId = if (
            activeDataSubscriptionId != SubscriptionManager.INVALID_SUBSCRIPTION_ID
        ) {
            activeDataSubscriptionId
        } else {
            SubscriptionManager.getDefaultDataSubscriptionId()
        }
        check(subscriptionId != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
            "data subscription is unavailable"
        }

        val manager = baseManager.createForSubscriptionId(subscriptionId)
        lateinit var newListener: PhoneStateListener
        newListener = object : PhoneStateListener(directExecutor) {
            override fun onServiceStateChanged(serviceState: ServiceState?) {
                if (serviceState?.state != ServiceState.STATE_POWER_OFF) return

                val current = synchronized(this@CellularRadioPowerObserver) {
                    listener === newListener
                }
                if (current) {
                    onRadioPowerOff()
                }
            }
        }

        scopedManager = manager
        listener = newListener
        try {
            manager.listen(newListener, PhoneStateListener.LISTEN_SERVICE_STATE)
        } catch (failure: Throwable) {
            if (listener === newListener) {
                listener = null
                scopedManager = null
            }
            throw failure
        }
    }

    @Synchronized
    override fun close() {
        val activeListener = listener ?: return
        val activeManager = scopedManager
        listener = null
        scopedManager = null
        activeManager?.listen(activeListener, PhoneStateListener.LISTEN_NONE)
    }
}
