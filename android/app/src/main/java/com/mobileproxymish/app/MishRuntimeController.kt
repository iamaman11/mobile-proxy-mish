package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn

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
    private val closed = AtomicBoolean(false)
    private val running = AtomicBoolean(false)
    private val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val generation = kotlinx.coroutines.flow.MutableStateFlow(newGeneration())

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
        get() = running.get()

    /** Starts exactly one current generation. Duplicate starts are intentionally idempotent. */
    fun start(): Boolean = synchronized(lock) {
        if (closed.get() || !running.compareAndSet(false, true)) return false
        val current = generation.value
        try {
            current.cellularRuntime.start()
            current.proxyRuntime.start()
            true
        } catch (_: Exception) {
            running.set(false)
            current.closeExact()
            if (!closed.get()) generation.value = newGeneration()
            false
        }
    }

    /**
     * Stops the current generation in dependency order and installs a fresh stopped generation.
     * This makes Service destroy -> recreate deterministic without depending on process death.
     */
    fun stop(): Boolean {
        val current = synchronized(lock) {
            if (closed.get()) return false
            if (!running.compareAndSet(true, false)) return true
            generation.value
        }

        val clean = current.closeExact()
        synchronized(lock) {
            if (!closed.get()) generation.value = newGeneration()
        }
        return clean
    }

    /** Process teardown helper for tests/controlled shutdown; production correctness uses Service. */
    internal fun closeProcessGeneration(): Boolean {
        val current = synchronized(lock) {
            if (!closed.compareAndSet(false, true)) return true
            running.set(false)
            generation.value
        }
        val clean = current.closeExact()
        observationScope.cancel()
        return clean
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
        fun closeExact(): Boolean {
            var clean = true
            if (runCatching { proxyRuntime.close() }.isFailure) clean = false
            if (runCatching { cellularRuntime.close() }.isFailure) clean = false
            return clean
        }
    }
}
