package com.mobileproxymish.app

import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.ffi.NativeProxyRuntime
import com.mobileproxymish.ffi.NativeProxyRuntimeObserver
import com.mobileproxymish.ffi.ProxyServingFailure
import com.mobileproxymish.ffi.ProxyServingLifecycleController
import com.mobileproxymish.ffi.ProxyServingSnapshotView
import com.mobileproxymish.ffi.ProxyServingState
import com.mobileproxymish.ffi.startNativeProxyRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Runtime Lifecycle projection only; it does not own proxy protocol or cellular facts. */
sealed interface ProxyRuntimeSnapshot {
    data object Stopped : ProxyRuntimeSnapshot
    data object Starting : ProxyRuntimeSnapshot
    data object Running : ProxyRuntimeSnapshot

    data class Failed(
        val reason: ProxyServingFailure,
    ) : ProxyRuntimeSnapshot
}

/** Non-secret read-only observation of the current in-process native serving generation. */
internal data class ProxyRuntimeDiagnosticObservation(
    val healthy: Boolean,
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

/**
 * Thin Android lifecycle/composition adapter for the Rust Proxy Serving runtime.
 *
 * Rust owns listener/session execution, health/fatal detection, terminal failure publication,
 * cancellation and bounded shutdown. Android supplies composition inputs, executes explicit
 * start/stop effects and projects typed Rust owner facts to StateFlow. There is no Android health
 * polling or runtime supervision loop.
 */
class ProxyRuntimeSupervisor internal constructor(
    private val cellularRuntime: CellularRuntimeBridge,
    private val publicCredentials: ProxyCredentialProvider,
    private val onFailureObserved: (ProxyServingFailure) -> Unit = {},
) : Closeable {
    private val lifecycle = ProxyServingLifecycleController()
    private val mutableSnapshot = MutableStateFlow(projectLifecycle(lifecycle.snapshot()))
    private val closed = AtomicBoolean(false)
    private val lock = Any()

    private var nativeRuntime: NativeProxyRuntime? = null
    private var servingCredentialVersion: ULong? = null
    private var nextRuntimeToken = 1L
    private var activeRuntimeToken: Long? = null

    val snapshot: StateFlow<ProxyRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    internal fun diagnosticObservation(): ProxyRuntimeDiagnosticObservation = synchronized(lock) {
        val runtimeHealthy = nativeRuntime?.let {
            runCatching { it.isHealthy() }.getOrDefault(false)
        } == true
        ProxyRuntimeDiagnosticObservation(
            healthy = runtimeHealthy,
            credentialVersion = servingCredentialVersion,
        )
    }

    fun start() {
        if (closed.get()) return
        if (synchronized(lock) { nativeRuntime != null }) return
        if (!lifecycle.requestStart()) return
        publishLifecycle()
        startBlocking()
    }

    private fun startBlocking() {
        val registration = synchronized(lock) {
            if (closed.get()) return

            val publicCredential = try {
                publicCredentials.currentCredential()
            } catch (_: Exception) {
                null
            }
            if (publicCredential == null) {
                failLifecycle(ProxyServingFailure.EXTERNAL_CREDENTIAL_UNAVAILABLE)
                return
            }

            val attempt = try {
                startNativeProxyRuntime(
                    cellular = cellularRuntime.nativeController(),
                    publicUsername = publicCredential.credentials.username,
                    publicPassword = publicCredential.credentials.password,
                    operationTimeoutMs = OUTBOUND_TIMEOUT_MS.toULong(),
                )
            } catch (_: LinkageError) {
                failLifecycle(ProxyServingFailure.NATIVE_RUNTIME_MISSING)
                return
            } catch (_: Exception) {
                // Expected PRODUCT failures are typed Rust data. This branch is FFI failure only.
                failLifecycle(ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE)
                return
            }

            val startFailure = attempt.failure()
            if (startFailure != null) {
                failLifecycle(startFailure)
                return
            }
            val newRuntime = attempt.runtime()
            if (newRuntime == null) {
                failLifecycle(ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE)
                return
            }

            if (closed.get()) {
                val stopFailure = stopFailure(newRuntime)
                if (stopFailure == null) {
                    stopLifecycle()
                } else {
                    failLifecycle(stopFailure)
                }
                return
            }

            val runtimeToken = nextRuntimeToken++
            nativeRuntime = newRuntime
            activeRuntimeToken = runtimeToken
            servingCredentialVersion = publicCredential.version
            check(lifecycle.markRunning()) { "proxy serving left STARTING before Rust publication" }
            publishLifecycle()
            RuntimeObserverRegistration(newRuntime, runtimeToken)
        }

        registerTerminalObserver(registration)
    }

    private fun registerTerminalObserver(registration: RuntimeObserverRegistration) {
        try {
            registration.runtime.observeTerminalFailure(
                object : NativeProxyRuntimeObserver {
                    override fun onTerminalFailure(failure: ProxyServingFailure) {
                        synchronized(lock) {
                            if (closed.get()) return
                            if (activeRuntimeToken != registration.token) return
                            if (nativeRuntime !== registration.runtime) return
                            failLifecycle(failure)
                        }
                    }
                },
            )
        } catch (_: Exception) {
            val failure = synchronized(lock) {
                if (activeRuntimeToken != registration.token) return
                if (nativeRuntime !== registration.runtime) return
                cleanupCurrentLocked() ?: ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE
            }
            failLifecycle(failure)
        }
    }

    private fun cleanupCurrentLocked(): ProxyServingFailure? {
        activeRuntimeToken = null
        val currentRuntime = nativeRuntime
        nativeRuntime = null
        servingCredentialVersion = null
        return currentRuntime?.let(::stopFailure)
    }

    private fun stopFailure(runtime: NativeProxyRuntime): ProxyServingFailure? = try {
        runtime.stop()
    } catch (_: Exception) {
        ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE
    }

    fun stop() {
        if (closed.get()) return
        val failure = synchronized(lock) { cleanupCurrentLocked() }
        if (failure == null) {
            stopLifecycle()
        } else {
            failLifecycle(failure)
        }
    }

    private fun publishLifecycle() {
        mutableSnapshot.value = projectLifecycle(lifecycle.snapshot())
    }

    /** Publish one typed owner fact; outer runtime decides recovery through Rust policy only. */
    private fun failLifecycle(reason: ProxyServingFailure) {
        lifecycle.markFailed(reason)
        publishLifecycle()
        onFailureObserved(reason)
    }

    private fun stopLifecycle() {
        lifecycle.markStopped()
        publishLifecycle()
    }

    private fun projectLifecycle(view: ProxyServingSnapshotView): ProxyRuntimeSnapshot =
        when (view.state) {
            ProxyServingState.STOPPED -> ProxyRuntimeSnapshot.Stopped
            ProxyServingState.STARTING -> ProxyRuntimeSnapshot.Starting
            ProxyServingState.RUNNING -> ProxyRuntimeSnapshot.Running
            ProxyServingState.FAILED -> ProxyRuntimeSnapshot.Failed(
                checkNotNull(view.failure) { "failed proxy serving must carry a typed reason" },
            )
        }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val failure = synchronized(lock) { cleanupCurrentLocked() }
        if (failure == null) {
            stopLifecycle()
        } else {
            failLifecycle(failure)
            throw IllegalStateException("native proxy runtime cleanup failed: $failure")
        }
    }

    private data class RuntimeObserverRegistration(
        val runtime: NativeProxyRuntime,
        val token: Long,
    )

    private companion object {
        const val OUTBOUND_TIMEOUT_MS = 15_000L
    }
}
