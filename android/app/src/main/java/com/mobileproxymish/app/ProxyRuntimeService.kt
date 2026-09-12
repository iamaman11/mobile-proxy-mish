package com.mobileproxymish.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * User-visible Android lifecycle owner for the mobile-proxy runtime.
 *
 * The Service owns process-generation lifetime only. It does not own proxy protocol/auth,
 * Cellular Egress admission, root-policy semantics, Mesh state, or readiness truth.
 */
class ProxyRuntimeService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val app = application as? MishApplication
        if (app == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }

        if (intent?.action == ACTION_STOP) {
            app.runtimeController.stop {
                mainHandler.post {
                    // A start request may have raced with cleanup. In that case the controller
                    // owns a fresh generation and the foreground Service must remain alive.
                    if (!app.runtimeController.isRunning) {
                        stopSelfResult(startId)
                    }
                }
            }
            return START_NOT_STICKY
        }

        if (!app.runtimeController.start()) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        // System destruction is best-effort because Android may kill the process immediately.
        // A later Service restart performs fresh startup reconciliation before readiness.
        (application as? MishApplication)?.runtimeController?.stop()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.proxy_runtime_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.proxy_runtime_channel_description)
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0
        val launchPendingIntent = PendingIntent.getActivity(this, 0, launchIntent, pendingFlags)
        val stopPendingIntent = PendingIntent.getService(
            this,
            STOP_REQUEST_CODE,
            Intent(this, ProxyRuntimeService::class.java).setAction(ACTION_STOP),
            pendingFlags,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_proxy_runtime)
            .setContentTitle(getString(R.string.proxy_runtime_notification_title))
            .setContentText(getString(R.string.proxy_runtime_notification_text))
            .setContentIntent(launchPendingIntent)
            .addAction(
                Notification.Action.Builder(
                    null,
                    getString(R.string.proxy_runtime_stop_action),
                    stopPendingIntent,
                ).build(),
            )
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .build()
    }

    companion object {
        private const val ACTION_START = "com.mobileproxymish.app.action.RUNTIME_START"
        private const val ACTION_STOP = "com.mobileproxymish.app.action.RUNTIME_STOP"
        private const val CHANNEL_ID = "proxy_runtime"
        private const val NOTIFICATION_ID = 1108
        private const val STOP_REQUEST_CODE = 1109

        /** Best-effort start request. Failure is fail-closed: no runtime is started implicitly. */
        fun requestStart(context: Context): Boolean = requestCommand(context, ACTION_START)

        /** Normal stop keeps the foreground Service alive until exact cleanup completes. */
        fun requestStop(context: Context): Boolean = requestCommand(context, ACTION_STOP)

        private fun requestCommand(context: Context, action: String): Boolean {
            val intent = Intent(context, ProxyRuntimeService::class.java).setAction(action)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (_: IllegalStateException) {
                false
            } catch (_: SecurityException) {
                false
            }
        }
    }
}
