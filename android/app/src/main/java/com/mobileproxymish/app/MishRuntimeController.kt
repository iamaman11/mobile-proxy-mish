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

/** Pure lifecycle decision used to keep failed cleanup fail-closed. */
internal data class RuntimeCleanupDisposition(
    val installFreshGenerationNow: Boolean,
    val requireFreshGenerationBeforeNextExplicitStart: Boolean,
    val restartNow: Boolean,
)

internal fun runtimeCleanupDisposition(
    clean: Boolean,
    restartRequested: Boolean,
): RuntimeCleanupDisposition = if (clean) {
    RuntimeCleanupDisposition(
        installFreshGenerationNow = true,
        requireFreshGenerationBeforeNextExplicitStart = false,
        restartNow = restartRequested,
    )
} else {
    RuntimeCleanupDisposition(
        installFreshGenerationNow = false,
        requireFreshGenerationBeforeNextExplicitStart = true,
        restartNow = false,
    )
}

/**
 * Process-local lifecycle composition for one foreground-service-owned runtime generation.
 *
 * Semantic ownership does not move here: Cellular Egress remains owned by the Rust cellular
 * owner, credentials lifecycle remains owned by the Rust credentials owner, and proxy protocol
 * auth remains owned by sing-box. This class only serializes lifecycle composition.
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
    private val externalCredentialStore = ExternalProxyCredentialStore(appContext)
    private val generation = MutableStateFlow(newGeneration())
    private val stopCallbacks = mutableListOf<(Boolean) -> Unit>()

    private var lifecycleState = LifecycleState.STOPPED
    private var restartAfterStop = false
    private var generationRequiresReplacement = false

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
     * successful stop is remembered. A failed cleanup explicitly suppresses automatic restart.
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
     * invoked only after proxy -> Cellular Egress/root-policy cleanup has completed or failed.
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
            // Executor rejection means cleanup never ran. Keep STOPPING as a terminal fail-closed
            // state for this controller instead of pretending a fresh generation is safe.
            restartAfterStop = false
            stopCallbacks.toList().also { stopCallbacks.clear() }
        }
        callbacks.forEach { callback -> runCatching { callback(false) } }
    }

    /**
     * Explicit rotation is accepted only from an exactly stopped, clean generation. This keeps
     * cutover atomic: no old sing-box generation remains active when the owner version changes.
     */
    internal fun rotateExternalCredentialWhileStopped(): Boolean =
        mutateExternalCredentialWhileStopped(externalCredentialStore::rotateWhileStopped)

    /** Revocation uses the same stopped-only cutover rule and never auto-restarts the runtime. */
    internal fun revokeExternalCredentialWhileStopped(): Boolean =
        mutateExternalCredentialWhileStopped(externalCredentialStore::revokeWhileStopped)

    private fun mutateExternalCredentialWhileStopped(mutation: () -> Boolean): Boolean =
        synchronized(lock) {
            if (lifecycleState != LifecycleState.STOPPED || generationRequiresReplacement) {
                return false
            }
            val current = generation.value
            if (!current.closeExact()) {
                generationRequiresReplacement = true
                return false
            }
            if (!mutation()) {
                generationRequiresReplacement = true
                return false
            }
            generation.value = newGeneration()
            true
        }

    private fun startBlocking() {
        val current = synchronized(lock) {
            if (generationRequiresReplacement) {
                // This replacement is allowed only because this task exists due to a later,
                // explicit start() after the failed-cleanup state transition.
                generation.value = newGeneration()
                generationRequiresReplacement = false
            }
            generation.value
        }
        val started = try {
            current.cellularRuntime.start()
            current.proxyRuntime.start()
            true
        } catch (_: Exception) {
            false
        }

        val cleanAfterFailedStart = if (started) true else current.closeExact()

        synchronized(lock) {
            when {
                started && lifecycleState == LifecycleState.STARTING -> {
                    lifecycleState = LifecycleState.RUNNING
                }

                !started && lifecycleState == LifecycleState.STARTING -> {
                    if (cleanAfterFailedStart) {
                        generation.value = newGeneration()
                        generationRequiresReplacement = false
                    } else {
                        generationRequiresReplacement = true
                    }
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
            val disposition = runtimeCleanupDisposition(
                clean = clean,
                restartRequested = restartAfterStop,
            )
            if (disposition.installFreshGenerationNow) {
                generation.value = newGeneration()
            }
            generationRequiresReplacement =
                disposition.requireFreshGenerationBeforeNextExplicitStart
            lifecycleState = LifecycleState.STOPPED
            restart = disposition.restartNow
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
        val proxyRuntime = ProxyRuntimeSupervisor(
            context = appContext,
            cellularRuntime = cellularRuntime,
            publicCredentials = externalCredentialStore,
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
