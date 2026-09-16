package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.ffi.NativeProxyRuntime
import com.mobileproxymish.ffi.RuntimeProcessFailure
import com.mobileproxymish.ffi.RuntimeProcessLifecycleController
import com.mobileproxymish.ffi.RuntimeProcessSnapshotView
import com.mobileproxymish.ffi.RuntimeProcessState
import com.mobileproxymish.ffi.startNativeProxyRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

private const val LOOPBACK_HEALTH_FAILURE_CONFIRMATIONS = 3

/** Runtime Lifecycle projection only; it does not own proxy protocol or cellular facts. */
sealed interface ProxyRuntimeSnapshot {
    data object Stopped : ProxyRuntimeSnapshot
    data object Starting : ProxyRuntimeSnapshot
    data object Running : ProxyRuntimeSnapshot

    data class Failed(
        val reason: RuntimeProcessFailure,
    ) : ProxyRuntimeSnapshot
}

/**
 * Non-secret read-only observation of the current in-process proxy generation.
 *
 * `privateBridge*` remains temporarily in this diagnostic record only to preserve the v1 readiness
 * and LAB schema across the L8 physical acceptance. No private bridge exists in the PRODUCT path:
 * the healthy bit is a compatibility projection of the direct native runtime.
 */
internal data class ProxyRuntimeDiagnosticObservation(
    val childAlive: Boolean,
    val privateBridgePort: Int?,
    val privateBridgeHealthy: Boolean,
    val credentialVersion: ULong?,
)

/** In-memory only external proxy credential material. */
internal class ProxyRuntimeCredentials(
    val username: String,
    val password: String,
) {
    override fun toString(): String = "ProxyRuntimeCredentials(<redacted>)"
}

/** Exact Credentials-owner version plus ephemeral derived material for one runtime start. */
internal class ProxyRuntimeCredentialSnapshot(
    val version: ULong,
    val credentials: ProxyRuntimeCredentials,
) {
    override fun toString(): String = "ProxyRuntimeCredentialSnapshot(version=$version,<redacted>)"
}

/** Narrow composition input; credential lifecycle and durable semantics remain in Rust. */
internal fun interface ProxyCredentialProvider {
    fun currentCredential(): ProxyRuntimeCredentialSnapshot?
}

/** Retained only for the existing unit contract until the v1 diagnostic compatibility field goes. */
internal fun confirmedLoopbackHealthFailure(consecutiveFailures: Int): Boolean =
    consecutiveFailures >= LOOPBACK_HEALTH_FAILURE_CONFIRMATIONS

/**
 * Thin Android lifecycle/composition adapter for the Rust Proxy Serving runtime.
 *
 * L8 topology:
 * canonical loopback Rust listeners -> direct root-policy-gated Cellular Egress connector.
 *
 * Android owns no proxy executor, accept/session thread, loopback health socket, private bridge,
 * private credential, PID or process reconciliation loop. Protocol/auth/relay are owned by Rust;
 * Cellular admission/DNS/routing remain owned by the existing Cellular runtime.
 */
class ProxyRuntimeSupervisor internal constructor(
    context: Context,
    private val cellularRuntime: CellularRuntimeBridge,
    private val publicCredentials: ProxyCredentialProvider,
    private val onRecoverableUnexpectedFailure: (RuntimeProcessFailure) -> Unit = {},
) : Closeable {
    private val lifecycle = RuntimeProcessLifecycleController()
    private val mutableSnapshot = MutableStateFlow(projectLifecycle(lifecycle.snapshot()))
    private val closed = AtomicBoolean(false)
    private val lock = Any()
    private val migration = LegacySingBoxUpgradeMigration(context.applicationContext)
    private val monitorScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    private var nativeRuntime: NativeProxyRuntime? = null
    private var servingCredentialVersion: ULong? = null
    private var monitorJob: Job? = null
    private var stopping = false

    val snapshot: StateFlow<ProxyRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    internal fun diagnosticObservation(): ProxyRuntimeDiagnosticObservation = synchronized(lock) {
        val runtimeHealthy = nativeRuntime?.let {
            runCatching { it.isHealthy() }.getOrDefault(false)
        } == true
        ProxyRuntimeDiagnosticObservation(
            childAlive = runtimeHealthy,
            privateBridgePort = null,
            privateBridgeHealthy = runtimeHealthy,
            credentialVersion = servingCredentialVersion,
        )
    }

    fun start() {
        if (closed.get() || !lifecycle.requestStart()) return
        publishLifecycle()
        startBlocking()
    }

    private fun startBlocking() {
        synchronized(lock) {
            if (closed.get()) return

            val publicCredential = try {
                publicCredentials.currentCredential()
            } catch (_: Exception) {
                null
            }
            if (publicCredential == null) {
                failLifecycle(RuntimeProcessFailure.EXTERNAL_CREDENTIAL_UNAVAILABLE)
                return
            }

            if (!migration.runOnce()) {
                failLifecycle(RuntimeProcessFailure.STALE_PROCESS_IDENTITY_MISMATCH)
                return
            }

            val newRuntime = try {
                startNativeProxyRuntime(
                    cellular = cellularRuntime.nativeController(),
                    publicUsername = publicCredential.credentials.username,
                    publicPassword = publicCredential.credentials.password,
                    operationTimeoutMs = OUTBOUND_TIMEOUT_MS.toULong(),
                )
            } catch (_: LinkageError) {
                failLifecycle(RuntimeProcessFailure.NATIVE_RUNTIME_MISSING)
                return
            } catch (_: Exception) {
                failLifecycle(RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE)
                return
            }

            if (!runCatching { newRuntime.isHealthy() }.getOrDefault(false)) {
                runCatching { newRuntime.stop() }
                failLifecycle(RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE)
                return
            }
            if (closed.get()) {
                runCatching { newRuntime.stop() }
                stopLifecycle()
                return
            }

            nativeRuntime = newRuntime
            servingCredentialVersion = publicCredential.version
            stopping = false
            check(lifecycle.markRunning()) { "proxy runtime left STARTING before health publication" }
            publishLifecycle()
            startMonitor(newRuntime)
        }
    }

    private fun startMonitor(expectedRuntime: NativeProxyRuntime) {
        monitorJob?.cancel()
        monitorJob = monitorScope.launch {
            while (isActive && !closed.get()) {
                delay(HEALTH_POLL_MS)
                if (runCatching { expectedRuntime.isHealthy() }.getOrDefault(false)) continue

                synchronized(lock) {
                    if (!stopping && nativeRuntime === expectedRuntime) {
                        val clean = cleanupCurrentLocked(cancelMonitor = false)
                        val published = if (clean) {
                            RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE
                        } else {
                            RuntimeProcessFailure.CLEANUP_FAILED
                        }
                        failLifecycle(published)
                        if (published in RECOVERABLE_UNEXPECTED_FAILURES) {
                            onRecoverableUnexpectedFailure(published)
                        }
                    }
                }
                return@launch
            }
        }
    }

    private fun cleanupCurrentLocked(cancelMonitor: Boolean = true): Boolean {
        stopping = true
        if (cancelMonitor) {
            monitorJob?.cancel()
        }
        monitorJob = null
        val currentRuntime = nativeRuntime
        nativeRuntime = null
        servingCredentialVersion = null

        val clean = currentRuntime == null || runCatching { currentRuntime.stop() }.isSuccess
        stopping = false
        return clean
    }

    fun stop() {
        if (closed.get()) return
        val clean = synchronized(lock) { cleanupCurrentLocked() }
        if (clean) {
            stopLifecycle()
        } else {
            failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
        }
    }

    private fun publishLifecycle() {
        mutableSnapshot.value = projectLifecycle(lifecycle.snapshot())
    }

    private fun failLifecycle(reason: RuntimeProcessFailure) {
        lifecycle.markFailed(reason)
        publishLifecycle()
    }

    private fun stopLifecycle() {
        lifecycle.markStopped()
        publishLifecycle()
    }

    private fun projectLifecycle(view: RuntimeProcessSnapshotView): ProxyRuntimeSnapshot =
        when (view.state) {
            RuntimeProcessState.STOPPED -> ProxyRuntimeSnapshot.Stopped
            RuntimeProcessState.STARTING -> ProxyRuntimeSnapshot.Starting
            RuntimeProcessState.RUNNING -> ProxyRuntimeSnapshot.Running
            RuntimeProcessState.FAILED -> ProxyRuntimeSnapshot.Failed(
                checkNotNull(view.failure) { "failed proxy runtime must carry a typed reason" },
            )
        }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val clean = synchronized(lock) { cleanupCurrentLocked() }
        monitorScope.cancel()
        if (clean) {
            stopLifecycle()
        } else {
            failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
            throw IllegalStateException("native proxy runtime cleanup failed")
        }
    }

    private companion object {
        const val OUTBOUND_TIMEOUT_MS = 15_000L
        const val HEALTH_POLL_MS = 500L
        val RECOVERABLE_UNEXPECTED_FAILURES = setOf(
            RuntimeProcessFailure.HEALTH_CHECK_FAILED,
            RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE,
        )
    }
}
