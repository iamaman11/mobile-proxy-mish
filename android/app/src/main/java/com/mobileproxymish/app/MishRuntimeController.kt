package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn

/** Runs both cleanup effects in dependency order and reports whether both completed cleanly. */
internal fun closeRuntimeGenerationExact(
    closeProxy: () -> Unit,
    closeCellular: () -> Unit,
): Boolean {
    var clean = true
    if (runCatching(closeProxy).isFailure) clean = false
    if (runCatching(closeCellular).isFailure) clean = false
    return clean
}

/**
 * Process-local lifecycle composition for one foreground-service-owned runtime generation.
 *
 * Semantic ownership does not move here: Cellular Egress remains owned by the Rust cellular
 * owner and proxy protocol/auth remains owned by sing-box. This class only makes start/stop
 * restartable inside one Android process so a destroyed Service never leaves the application
 * pointing at permanently closed runtime objects.
 */
class MishRuntimeController internal constructor(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val lock = Any()
    private val lifecycleExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-runtime-lifecycle").apply { isDaemon = true }
    }
    private val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val generation = MutableStateFlow(newGeneration())
    private val stopCallbacks = mutableListOf<(Boolean) -> Unit>()

    private var lifecycleState = LifecycleState.STOPPED
    private var restartAfterStop = false

    @OptIn(ExperimentalCoroutinesApi::class)
    val cellularSnapshot: StateFlow<CellularRuntimeSnapshot> = generation
        .flatMapLatest { it.cellularRuntime.snapshot }
        .stateIn(
            scope = observationScope,
            started = SharingStarted.Eagerly,
            initialValue = generation.value.cellularRuntime.snapshot.value,
        )

    @OptIn(ExperimentalCoroutinesApi::class)
    val proxySnapshot: StateFlow<ProxyRuntimeSnapshot> = generation
        .flatMapLatest { it.proxyRuntime.snapshot }
        .stateIn(
            scope = observationScope,
            started = SharingStarted.Eagerly,
            initialValue = ProxyRuntimeSnapshot.Stopped,
        )

    internal val currentCellularRuntime: CellularRuntimeBridge
        get() = generation.value.cellularRuntime

    internal val currentProxyRuntime: ProxyRuntimeSupervisor
        get() = generation.value.proxyRuntime

    val isRunning: Boolean
        get() = synchronized(lock) { lifecycleState != LifecycleState.STOPPED }

    /**
     * Requests one serialized start. Duplicate starts are idempotent; a start racing with a
     * stop is remembered and begins only after exact cleanup installed a fresh generation.
     */
    fun start(): Boolean {
        val shouldSubmit = synchronized(lock) {
            when (lifecycleState) {
                LifecycleState.RUNNING,
                LifecycleState.STARTING,
                -> return true

                LifecycleState.STOPPING -> {
                    restartAfterStop = true
                    return true
                }

                LifecycleState.STOPPED -> {
                    lifecycleState = LifecycleState.STARTING
                    true
                }
            }
        }

        if (!shouldSubmit || submit(::startBlocking)) return true
        synchronized(lock) {
            if (lifecycleState == LifecycleState.STARTING) {
                lifecycleState = LifecycleState.STOPPED
            }
        }
        return false
    }

    /**
     * Requests exact stop without blocking the Android main thread. The completion callback is
     * invoked after proxy -> Cellular Egress/root-policy cleanup and fresh-generation install.
     */
    fun stop(onComplete: (Boolean) -> Unit = {}) {
        var completeImmediately: Boolean? = null
        val shouldSubmit = synchronized(lock) {
            when (lifecycleState) {
                LifecycleState.STOPPED -> {
                    completeImmediately = true
                    false
                }

                LifecycleState.STOPPING -> {
                    stopCallbacks += onComplete
                    false
                }

                LifecycleState.STARTING,
                LifecycleState.RUNNING,
                -> {
                    lifecycleState = LifecycleState.STOPPING
                    stopCallbacks += onComplete
                    true
                }
            }
        }

        completeImmediately?.let {
            onComplete(it)
            return
        }
        if (!shouldSubmit) return
        if (submit(::stopBlocking)) return

        val callbacks = synchronized(lock) {
            lifecycleState = LifecycleState.STOPPED
            restartAfterStop = false
            stopCallbacks.toList().also { stopCallbacks.clear() }
        }
        callbacks.forEach { callback -> runCatching { callback(false) } }
    }

    private fun startBlocking() {
        val current = synchronized(lock) { generation.value }
        val started = try {
            current.cellularRuntime.start()
            current.proxyRuntime.start()
            true
        } catch (_: Exception) {
            false
        }

        if (!started) current.closeExact()

        synchronized(lock) {
            when {
                started && lifecycleState == LifecycleState.STARTING -> {
                    lifecycleState = LifecycleState.RUNNING
                }

                !started && lifecycleState == LifecycleState.STARTING -> {
                    generation.value = newGeneration()
                    lifecycleState = LifecycleState.STOPPED
                }

                // STOPPING is handled by the stop task already queued after this one.
                else -> Unit
            }
        }
    }

    private fun stopBlocking() {
        val current = synchronized(lock) { generation.value }
        val clean = current.closeExact()

        val restart: Boolean
        val callbacks: List<(Boolean) -> Unit>
        synchronized(lock) {
            generation.value = newGeneration()
            lifecycleState = LifecycleState.STOPPED
            restart = restartAfterStop
            restartAfterStop = false
            callbacks = stopCallbacks.toList()
            stopCallbacks.clear()
        }

        callbacks.forEach { callback -> runCatching { callback(clean) } }
        if (restart) start()
    }

    private fun submit(block: () -> Unit): Boolean = try {
        lifecycleExecutor.execute(block)
        true
    } catch (_: RejectedExecutionException) {
        false
    }

    private fun newGeneration(): RuntimeGeneration {
        val cellularRuntime = CellularRuntimeBridge(appContext)
        val credentials = ProxyRuntimeCredentials.generate()
        val proxyRuntime = ProxyRuntimeSupervisor(
            context = appContext,
            cellularRuntime = cellularRuntime,
            publicCredentials = credentials,
        )
        return RuntimeGeneration(cellularRuntime, proxyRuntime)
    }

    private data class RuntimeGeneration(
        val cellularRuntime: CellularRuntimeBridge,
        val proxyRuntime: ProxyRuntimeSupervisor,
    ) {
        fun closeExact(): Boolean = closeRuntimeGenerationExact(
            closeProxy = proxyRuntime::close,
            closeCellular = cellularRuntime::close,
        )
    }

    private enum class LifecycleState {
        STOPPED,
        STARTING,
        RUNNING,
        STOPPING,
    }
}
