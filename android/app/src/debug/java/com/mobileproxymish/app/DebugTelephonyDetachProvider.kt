package com.mobileproxymish.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Process
import android.os.SystemClock
import android.telephony.PhoneStateListener
import android.telephony.ServiceState
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Base64
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executor
import org.json.JSONArray
import org.json.JSONObject

private const val MISH_TELEPHONY_DETACH_SCHEMA_V1 = "mish.debug.telephony-detach/v1"
private const val MISH_TELEPHONY_DETACH_START_V1 = "start_v1"
private const val MISH_TELEPHONY_DETACH_SNAPSHOT_V1 = "snapshot_v1"
private const val MISH_TELEPHONY_DETACH_STOP_V1 = "stop_v1"
private const val MISH_TELEPHONY_DETACH_PAYLOAD_B64 = "payload_b64"

private data class TelephonyDetachEvent(
    val elapsedRealtimeMs: Long,
    val state: Int,
    val stateName: String,
)

private data class TelephonyDetachCorrelation(
    val elapsedBeforeControlSnapshotMs: Long,
    val elapsedAfterControlSnapshotMs: Long,
    val controlState: String,
    val operationId: Long?,
    val operationAgeMs: Long?,
)

private object DebugTelephonyDetachObserver {
    private val lock = Any()
    private val directExecutor = Executor { command -> command.run() }
    private val events = mutableListOf<TelephonyDetachEvent>()

    private var telephonyManager: TelephonyManager? = null
    private var listener: PhoneStateListener? = null
    private var activeDataSubscriptionValid = false

    fun start(context: Context) {
        val subscriptionId = SubscriptionManager.getActiveDataSubscriptionId()
        check(subscriptionId != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
            "active data subscription is unavailable"
        }

        val baseManager = context.getSystemService(TelephonyManager::class.java)
            ?: error("TelephonyManager is unavailable")
        val scopedManager = baseManager.createForSubscriptionId(subscriptionId)

        lateinit var newListener: PhoneStateListener
        newListener = object : PhoneStateListener(directExecutor) {
            override fun onServiceStateChanged(serviceState: ServiceState?) {
                val state = serviceState?.state ?: return
                val event = TelephonyDetachEvent(
                    elapsedRealtimeMs = SystemClock.elapsedRealtime(),
                    state = state,
                    stateName = serviceStateName(state),
                )
                synchronized(lock) {
                    if (listener === newListener) {
                        events += event
                    }
                }
            }
        }

        synchronized(lock) {
            check(listener == null) { "telephony detach observer is already active" }
            events.clear()
            activeDataSubscriptionValid = true
            telephonyManager = scopedManager
            listener = newListener
        }

        try {
            scopedManager.listen(newListener, PhoneStateListener.LISTEN_SERVICE_STATE)
        } catch (failure: Throwable) {
            synchronized(lock) {
                if (listener === newListener) {
                    listener = null
                    telephonyManager = null
                    activeDataSubscriptionValid = false
                    events.clear()
                }
            }
            throw failure
        }
    }

    fun stop() {
        val managerAndListener = synchronized(lock) {
            val activeListener = listener ?: return
            val activeManager = telephonyManager
            listener = null
            telephonyManager = null
            activeManager to activeListener
        }
        managerAndListener.first?.listen(
            managerAndListener.second,
            PhoneStateListener.LISTEN_NONE,
        )
    }

    fun isActive(): Boolean = synchronized(lock) { listener != null }

    fun activeDataSubscriptionWasValid(): Boolean =
        synchronized(lock) { activeDataSubscriptionValid }

    fun eventSnapshot(): List<TelephonyDetachEvent> =
        synchronized(lock) { events.toList() }

    private fun serviceStateName(state: Int): String = when (state) {
        ServiceState.STATE_IN_SERVICE -> "IN_SERVICE"
        ServiceState.STATE_OUT_OF_SERVICE -> "OUT_OF_SERVICE"
        ServiceState.STATE_EMERGENCY_ONLY -> "EMERGENCY_ONLY"
        ServiceState.STATE_POWER_OFF -> "POWER_OFF"
        else -> "UNKNOWN"
    }
}

private fun captureTelephonyDetachCorrelation(
    app: MishApplication,
): TelephonyDetachCorrelation {
    val elapsedBefore = SystemClock.elapsedRealtime()
    val control = app.runtimeController.controlSnapshot()
    val elapsedAfter = SystemClock.elapsedRealtime()
    return TelephonyDetachCorrelation(
        elapsedBeforeControlSnapshotMs = elapsedBefore,
        elapsedAfterControlSnapshotMs = elapsedAfter,
        controlState = control.state.name,
        operationId = control.operationTiming.operationId?.toLong(),
        operationAgeMs = control.operationTiming.operationAgeMs?.toLong(),
    )
}

private fun renderTelephonyDetachSnapshot(
    app: MishApplication,
    correlation: TelephonyDetachCorrelation?,
): String {
    val eventSnapshot = DebugTelephonyDetachObserver.eventSnapshot()
    return JSONObject().apply {
        put("schema", MISH_TELEPHONY_DETACH_SCHEMA_V1)
        put("application_id", app.packageName)
        put("pid", Process.myPid())
        put("active", DebugTelephonyDetachObserver.isActive())
        put(
            "active_data_subscription_valid",
            DebugTelephonyDetachObserver.activeDataSubscriptionWasValid(),
        )
        put("event_count", eventSnapshot.size)
        put("events", JSONArray().apply {
            eventSnapshot.forEach { event ->
                put(JSONObject().apply {
                    put("elapsed_realtime_ms", event.elapsedRealtimeMs)
                    put("state", event.state)
                    put("state_name", event.stateName)
                })
            }
        })
        put("correlation", if (correlation == null) {
            JSONObject.NULL
        } else {
            JSONObject().apply {
                put(
                    "elapsed_before_control_snapshot_ms",
                    correlation.elapsedBeforeControlSnapshotMs,
                )
                put(
                    "elapsed_after_control_snapshot_ms",
                    correlation.elapsedAfterControlSnapshotMs,
                )
                put("control_state", correlation.controlState)
                put("operation_id", correlation.operationId ?: JSONObject.NULL)
                put("operation_age_ms", correlation.operationAgeMs ?: JSONObject.NULL)
            }
        })
        put("product_mutation_performed", false)
        put("radio_mutation_performed", false)
        put("rotation_triggered", false)
        put("raw_public_ip_persisted", false)
        put("subscription_id_persisted", false)
    }.toString()
}

/**
 * Debug-only typed Android telephony observer for one physical Device Lab experiment.
 *
 * It observes ServiceState only. It owns no PRODUCT transition, timer, retry, radio effect,
 * Rotation operation or public-IP decision. The provider is protected by DUMP in the debug
 * manifest and is absent from release builds.
 */
class DebugTelephonyDetachProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        require(
            method == MISH_TELEPHONY_DETACH_START_V1 ||
                method == MISH_TELEPHONY_DETACH_SNAPSHOT_V1 ||
                method == MISH_TELEPHONY_DETACH_STOP_V1,
        ) {
            "unsupported telephony detach diagnostic method"
        }
        require(arg == null && (extras == null || extras.isEmpty)) {
            "telephony detach diagnostic accepts no arguments"
        }

        val app = context?.applicationContext as? MishApplication
            ?: error("MishApplication is unavailable")

        val correlation = when (method) {
            MISH_TELEPHONY_DETACH_START_V1 -> {
                DebugTelephonyDetachObserver.start(app)
                null
            }
            MISH_TELEPHONY_DETACH_SNAPSHOT_V1 -> captureTelephonyDetachCorrelation(app)
            MISH_TELEPHONY_DETACH_STOP_V1 -> {
                DebugTelephonyDetachObserver.stop()
                captureTelephonyDetachCorrelation(app)
            }
            else -> error("unsupported telephony detach diagnostic method")
        }

        val json = renderTelephonyDetachSnapshot(app, correlation)
        val encoded = Base64.encodeToString(
            json.toByteArray(StandardCharsets.UTF_8),
            Base64.NO_WRAP,
        )
        return Bundle().apply {
            putString("schema", MISH_TELEPHONY_DETACH_SCHEMA_V1)
            putString(MISH_TELEPHONY_DETACH_PAYLOAD_B64, encoded)
        }
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = throw UnsupportedOperationException("query is not supported")

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? =
        throw UnsupportedOperationException("insert is not supported")

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException("delete is not supported")

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = throw UnsupportedOperationException("update is not supported")
}
