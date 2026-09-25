package com.mobileproxymish.app

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.telephony.PhoneStateListener
import android.telephony.ServiceState
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import android.util.Base64
import java.nio.charset.StandardCharsets
import org.json.JSONArray
import org.json.JSONObject

private const val TELEPHONY_DIAGNOSTICS_SCHEMA_V1 = "mish.debug.telephony-service-state/v1"
private const val METHOD_START = "telephony_service_state_start_v1"
private const val METHOD_SNAPSHOT = "telephony_service_state_snapshot_v1"
private const val METHOD_STOP = "telephony_service_state_stop_v1"
private const val RESULT_PAYLOAD_B64 = "payload_b64"
private const val MAX_EVENTS = 32

private data class TelephonyServiceStateEvent(
    val sequence: Long,
    val state: String,
    val operationId: Long?,
    val operationAgeMs: Long?,
)

/**
 * Debug-only typed telephony observation for DEVICE-1 physical characterization.
 *
 * This provider never owns PRODUCT state or transitions. It only subscribes to Android's
 * ServiceState callback and samples the existing Rust CONTROL operation clock through the
 * read-only native snapshot so the platform event can be correlated to one remote Rotation.
 */
@Suppress("DEPRECATION")
class DebugTelephonyServiceStateProvider : ContentProvider() {
    private val lock = Any()
    private val events = ArrayList<TelephonyServiceStateEvent>(MAX_EVENTS)
    private var nextSequence = 1L
    private var droppedEvents = 0L
    private var recording = false
    private var telephonyManager: TelephonyManager? = null
    private var listener: PhoneStateListener? = null

    override fun onCreate(): Boolean = true

    override fun call(method: String, arg: String?, extras: Bundle?): Bundle {
        require(arg == null && (extras == null || extras.isEmpty)) {
            "telephony diagnostics accepts no arguments"
        }
        val app = context?.applicationContext as? MishApplication
            ?: error("MishApplication is unavailable")
        return when (method) {
            METHOD_START -> start(app)
            METHOD_SNAPSHOT -> renderBundle(app, "SNAPSHOT")
            METHOD_STOP -> stop(app)
            else -> error("unsupported telephony diagnostics method")
        }
    }

    private fun start(app: MishApplication): Bundle {
        val context = requireNotNull(context)
        val subscriptionId = SubscriptionManager.getActiveDataSubscriptionId()
        require(subscriptionId != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
            "active data subscription is unavailable"
        }
        val baseManager = requireNotNull(context.getSystemService(TelephonyManager::class.java))
        val manager = baseManager.createForSubscriptionId(subscriptionId)
        val newListener = object : PhoneStateListener(context.mainExecutor) {
            override fun onServiceStateChanged(serviceState: ServiceState) {
                val control = app.runtimeController.controlSnapshot()
                val event = TelephonyServiceStateEvent(
                    sequence = synchronized(lock) { nextSequence++ },
                    state = serviceStateName(serviceState.state),
                    operationId = control.operationTiming.operationId?.toLong(),
                    operationAgeMs = control.operationTiming.operationAgeMs?.toLong(),
                )
                synchronized(lock) {
                    if (!recording) return
                    if (events.size < MAX_EVENTS) {
                        events.add(event)
                    } else {
                        droppedEvents++
                    }
                }
            }
        }

        synchronized(lock) {
            check(!recording) { "telephony diagnostics already active" }
            events.clear()
            nextSequence = 1L
            droppedEvents = 0L
            recording = true
            telephonyManager = manager
            listener = newListener
        }

        try {
            manager.listen(newListener, PhoneStateListener.LISTEN_SERVICE_STATE)
        } catch (error: Throwable) {
            synchronized(lock) {
                recording = false
                telephonyManager = null
                listener = null
                events.clear()
            }
            throw error
        }
        return renderBundle(app, "STARTED")
    }

    private fun stop(app: MishApplication): Bundle {
        val pair = synchronized(lock) {
            recording = false
            val current = telephonyManager to listener
            telephonyManager = null
            listener = null
            current
        }
        val manager = pair.first
        val currentListener = pair.second
        if (manager != null && currentListener != null) {
            manager.listen(currentListener, PhoneStateListener.LISTEN_NONE)
        }
        return renderBundle(app, "STOPPED")
    }

    private fun renderBundle(app: MishApplication, status: String): Bundle {
        val control = app.runtimeController.controlSnapshot()
        val snapshot = synchronized(lock) {
            Triple(events.toList(), droppedEvents, recording)
        }
        val json = JSONObject().apply {
            put("schema", TELEPHONY_DIAGNOSTICS_SCHEMA_V1)
            put("status", status)
            put("application_id", app.packageName)
            put("active", snapshot.third)
            put("active_data_subscription_selected", true)
            put("event_count", snapshot.first.size)
            put("dropped_events", snapshot.second)
            put(
                "snapshot_operation_id",
                control.operationTiming.operationId?.toLong() ?: JSONObject.NULL,
            )
            put(
                "snapshot_operation_age_ms",
                control.operationTiming.operationAgeMs?.toLong() ?: JSONObject.NULL,
            )
            put(
                "last_terminal_result",
                control.lastTerminalResult?.name ?: JSONObject.NULL,
            )
            put("events", JSONArray().apply {
                snapshot.first.forEach { event ->
                    put(JSONObject().apply {
                        put("sequence", event.sequence)
                        put("state", event.state)
                        put("operation_id", event.operationId ?: JSONObject.NULL)
                        put("operation_age_ms", event.operationAgeMs ?: JSONObject.NULL)
                    })
                }
            })
            put("raw_subscription_id_persisted", false)
            put("operator_identity_persisted", false)
            put("cell_identity_persisted", false)
            put("mutation_performed", false)
        }.toString()
        val encoded = Base64.encodeToString(
            json.toByteArray(StandardCharsets.UTF_8),
            Base64.NO_WRAP,
        )
        return Bundle().apply {
            putString("schema", TELEPHONY_DIAGNOSTICS_SCHEMA_V1)
            putString(RESULT_PAYLOAD_B64, encoded)
        }
    }

    private fun serviceStateName(state: Int): String = when (state) {
        ServiceState.STATE_IN_SERVICE -> "IN_SERVICE"
        ServiceState.STATE_OUT_OF_SERVICE -> "OUT_OF_SERVICE"
        ServiceState.STATE_EMERGENCY_ONLY -> "EMERGENCY_ONLY"
        ServiceState.STATE_POWER_OFF -> "POWER_OFF"
        else -> "UNKNOWN"
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}
