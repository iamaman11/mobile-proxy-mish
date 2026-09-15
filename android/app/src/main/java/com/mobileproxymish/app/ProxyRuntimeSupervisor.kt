package com.mobileproxymish.app

import android.content.Context
import android.util.Base64
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.ffi.CellularBridgeRuntime
import com.mobileproxymish.ffi.NativeProxyRuntime
import com.mobileproxymish.ffi.RuntimeProcessFailure
import com.mobileproxymish.ffi.RuntimeProcessLifecycleController
import com.mobileproxymish.ffi.RuntimeProcessSnapshotView
import com.mobileproxymish.ffi.RuntimeProcessState
import com.mobileproxymish.ffi.proxyListenerPorts
import com.mobileproxymish.ffi.startNativeProxyRuntime
import java.io.Closeable
import java.net.InetSocketAddress
import java.net.Socket
import java.security.SecureRandom
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
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
 * Field names remain stable during the sing-box cutover so readiness/diagnostic consumers do not
 * gain a second migration contract. `childAlive` now means the native Rust listener runtime is
 * healthy; `privateBridgeHealthy` remains the temporary L7 Cellular bridge fact removed in L8.
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

private fun randomCredential(): String {
    val bytes = ByteArray(CREDENTIAL_BYTES)
    SECURE_RANDOM.nextBytes(bytes)
    return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}

/** A single local health timeout is not sufficient evidence that an owned listener died. */
internal fun confirmedLoopbackHealthFailure(consecutiveFailures: Int): Boolean =
    consecutiveFailures >= LOOPBACK_HEALTH_FAILURE_CONFIRMATIONS

/**
 * Android lifecycle/composition adapter for the in-process Rust Proxy Serving runtime.
 *
 * L7 topology:
 * canonical loopback Rust listeners -> temporary private Cellular bridge -> exact Cellular Egress.
 *
 * No proxy process, root launcher, PID file, `/proc` reconciliation, vendor config or Magisk call
 * exists in this adapter. Protocol/auth/relay are owned by `mish-proxy`; Cellular admission/DNS/
 * routing remain owned by the existing Cellular runtime. L8 removes the final private bridge hop.
 */
class ProxyRuntimeSupervisor internal constructor(
    @Suppress("UNUSED_PARAMETER") context: Context,
    private val cellularRuntime: CellularRuntimeBridge,
    private val publicCredentials: ProxyCredentialProvider,
    private val onRecoverableUnexpectedFailure: (RuntimeProcessFailure) -> Unit = {},
) : Closeable {
    private val lifecycle = RuntimeProcessLifecycleController()
    private val mutableSnapshot = MutableStateFlow(projectLifecycle(lifecycle.snapshot()))
    private val closed = AtomicBoolean(false)
    private val lock = Any()
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-proxy-runtime").apply { isDaemon = true }
    }

    private var nativeRuntime: NativeProxyRuntime? = null
    private var bridge: CellularBridgeRuntime? = null
    private var servingCredentialVersion: ULong? = null
    private var monitor: Thread? = null
    private var stopping = false

    val snapshot: StateFlow<ProxyRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    internal fun diagnosticObservation(): ProxyRuntimeDiagnosticObservation = synchronized(lock) {
        val currentRuntime = nativeRuntime
        val currentBridge = bridge
        val runtimeHealthy = currentRuntime?.let {
            runCatching { it.isHealthy() }.getOrDefault(false)
        } == true
        ProxyRuntimeDiagnosticObservation(
            childAlive = runtimeHealthy,
            privateBridgePort = runCatching { currentBridge?.port()?.toInt() }.getOrNull(),
            privateBridgeHealthy = currentBridge?.let {
                runCatching { it.isHealthy() }.getOrDefault(false)
            } == true,
            credentialVersion = servingCredentialVersion,
        )
    }

    fun start() {
        if (closed.get() || !lifecycle.requestStart()) return
        publishLifecycle()
        try {
            executor.execute(::startBlocking)
        } catch (_: RejectedExecutionException) {
            failLifecycle(RuntimeProcessFailure.CHILD_EXECUTOR_REJECTED)
        }
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

            if (!cellularRuntime.awaitAuthorizedAdmission(AUTHORIZED_ADMISSION_TIMEOUT_MS)) {
                failLifecycle(RuntimeProcessFailure.PRIVATE_BRIDGE_UNAVAILABLE)
                return
            }

            val privateUsername = randomCredential()
            val privatePassword = randomCredential()
            val newBridge = try {
                cellularRuntime.startPrivateBridge(
                    username = privateUsername,
                    password = privatePassword,
                    operationTimeoutMs = OUTBOUND_TIMEOUT_MS.toULong(),
                )
            } catch (_: Exception) {
                failLifecycle(RuntimeProcessFailure.PRIVATE_BRIDGE_UNAVAILABLE)
                return
            }

            val newRuntime = try {
                startNativeProxyRuntime(
                    bridge = newBridge,
                    publicUsername = publicCredential.credentials.username,
                    publicPassword = publicCredential.credentials.password,
                    privateUsername = privateUsername,
                    privatePassword = privatePassword,
                    operationTimeoutMs = OUTBOUND_TIMEOUT_MS.toULong(),
                )
            } catch (_: LinkageError) {
                runCatching { newBridge.stop() }
                failLifecycle(RuntimeProcessFailure.NATIVE_RUNTIME_MISSING)
                return
            } catch (_: Exception) {
                runCatching { newBridge.stop() }
                failLifecycle(RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE)
                return
            }

            val healthFailure = waitForHealthy(newRuntime, newBridge)
            if (healthFailure != null) {
                runCatching { newRuntime.stop() }
                runCatching { newBridge.stop() }
                failLifecycle(healthFailure)
                return
            }

            if (closed.get()) {
                runCatching { newRuntime.stop() }
                runCatching { newBridge.stop() }
                stopLifecycle()
                return
            }

            nativeRuntime = newRuntime
            bridge = newBridge
            servingCredentialVersion = publicCredential.version
            stopping = false
            check(lifecycle.markRunning()) { "proxy runtime left STARTING before health publication" }
            publishLifecycle()
            startMonitor(newRuntime, newBridge)
        }
    }

    private fun startMonitor(
        expectedRuntime: NativeProxyRuntime,
        expectedBridge: CellularBridgeRuntime,
    ) {
        val thread = Thread({
            var consecutiveLoopbackFailures = 0
            while (!closed.get()) {
                val reason = when {
                    !runCatching { expectedBridge.isHealthy() }.getOrDefault(false) ->
                        RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY
                    !runCatching { expectedRuntime.isHealthy() }.getOrDefault(false) ->
                        RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE
                    canonicalLoopbackListenersReachable() -> {
                        consecutiveLoopbackFailures = 0
                        null
                    }
                    else -> {
                        consecutiveLoopbackFailures += 1
                        if (confirmedLoopbackHealthFailure(consecutiveLoopbackFailures)) {
                            RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE
                        } else {
                            null
                        }
                    }
                }
                if (reason != null) {
                    try {
                        executor.execute {
                            synchronized(lock) {
                                if (!stopping && nativeRuntime === expectedRuntime) {
                                    val cleanupOk = cleanupCurrentLocked()
                                    val published = if (cleanupOk) reason else RuntimeProcessFailure.CLEANUP_FAILED
                                    failLifecycle(published)
                                    if (published in RECOVERABLE_UNEXPECTED_FAILURES) {
                                        onRecoverableUnexpectedFailure(published)
                                    }
                                }
                            }
                        }
                    } catch (_: RejectedExecutionException) {
                        // close() already owns terminal cleanup.
                    }
                    return@Thread
                }
                try {
                    Thread.sleep(HEALTH_POLL_MS)
                } catch (_: InterruptedException) {
                    return@Thread
                }
            }
        }, "mish-proxy-runtime-monitor")
        thread.isDaemon = true
        monitor = thread
        thread.start()
    }

    private fun waitForHealthy(
        runtime: NativeProxyRuntime,
        privateBridge: CellularBridgeRuntime,
    ): RuntimeProcessFailure? {
        val publicPorts = try {
            proxyListenerPorts().map { it.toInt() }
        } catch (_: LinkageError) {
            return RuntimeProcessFailure.LISTENER_CONTRACT_UNAVAILABLE
        } catch (_: Exception) {
            return RuntimeProcessFailure.LISTENER_CONTRACT_UNAVAILABLE
        }
        if (publicPorts.isEmpty()) return RuntimeProcessFailure.LISTENER_CONTRACT_UNAVAILABLE

        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(START_HEALTH_TIMEOUT_SECONDS)
        while (System.nanoTime() < deadline) {
            if (!runCatching { privateBridge.isHealthy() }.getOrDefault(false)) {
                return RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY
            }
            if (!runCatching { runtime.isHealthy() }.getOrDefault(false)) {
                return RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE
            }
            if (publicPorts.all(::canConnectLoopback)) return null
            Thread.sleep(HEALTH_RETRY_MS)
        }
        return RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE
    }

    private fun canConnectLoopback(port: Int): Boolean = try {
        Socket().use { socket ->
            socket.connect(InetSocketAddress(LOOPBACK, port), HEALTH_CONNECT_TIMEOUT_MS)
        }
        true
    } catch (_: Exception) {
        false
    }

    private fun canonicalLoopbackListenersReachable(): Boolean = try {
        proxyListenerPorts().map { it.toInt() }.all(::canConnectLoopback)
    } catch (_: Exception) {
        false
    }

    private fun cleanupCurrentLocked(): Boolean {
        stopping = true
        val currentRuntime = nativeRuntime
        val currentBridge = bridge
        nativeRuntime = null
        bridge = null
        servingCredentialVersion = null

        var clean = true
        if (currentRuntime != null && runCatching { currentRuntime.stop() }.isFailure) clean = false
        if (currentBridge != null && runCatching { currentBridge.stop() }.isFailure) clean = false
        stopping = false
        return clean
    }

    fun stop() {
        if (closed.get()) return
        try {
            executor.execute {
                val clean = synchronized(lock) { cleanupCurrentLocked() }
                if (clean) {
                    stopLifecycle()
                } else {
                    failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
                }
            }
        } catch (_: RejectedExecutionException) {
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
        val cleanup = try {
            executor.submit(Callable {
                synchronized(lock) {
                    cleanupCurrentLocked()
                }
            })
        } catch (_: RejectedExecutionException) {
            null
        }
        val clean = try {
            cleanup?.get(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS) == true
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        } catch (_: Exception) {
            false
        }
        executor.shutdownNow()
        monitor?.interrupt()
        if (clean) {
            stopLifecycle()
        } else {
            failLifecycle(RuntimeProcessFailure.CLEANUP_FAILED)
        }
    }

    private companion object {
        const val LOOPBACK = "127.0.0.1"
        const val OUTBOUND_TIMEOUT_MS = 15_000L
        const val AUTHORIZED_ADMISSION_TIMEOUT_MS = 30_000L
        const val START_HEALTH_TIMEOUT_SECONDS = 5L
        const val HEALTH_RETRY_MS = 100L
        const val HEALTH_POLL_MS = 500L
        const val HEALTH_CONNECT_TIMEOUT_MS = 250
        const val CLOSE_TIMEOUT_SECONDS = 25L
        const val CREDENTIAL_BYTES = 24
        val SECURE_RANDOM = SecureRandom()
        val RECOVERABLE_UNEXPECTED_FAILURES = setOf(
            RuntimeProcessFailure.HEALTH_CHECK_FAILED,
            RuntimeProcessFailure.LOOPBACK_LISTENER_UNAVAILABLE,
            RuntimeProcessFailure.PRIVATE_BRIDGE_UNHEALTHY,
        )
    }
}
