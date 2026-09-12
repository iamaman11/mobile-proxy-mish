package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.RuntimeLifecycleController
import com.mobileproxymish.ffi.RuntimeLifecycleState
import com.mobileproxymish.ffi.RuntimeStartAction
import com.mobileproxymish.ffi.RuntimeStopAction
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

/** Runs every generation cleanup effect in dependency order and reports aggregate success. */
internal fun closeRuntimeGenerationExact(
    closeMesh: () -> Unit,
    closeProxy: () -> Unit,
    closeCellular: () -> Unit,
): Boolean {
    var clean = true
    if (runCatching(closeMesh).isFailure) clean = false
    if (runCatching(closeProxy).isFailure) clean = false
    if (runCatching(closeCellular).isFailure) clean = false
    return clean
}

/**
 * Android effect/composition adapter for the Rust Runtime Lifecycle natural owner.
 *
 * The Rust owner owns start/stop/restart/generation-replacement decisions. This class only
 * serializes Android/process effects, stores platform callback closures, and publishes owner
 * projections from the currently installed runtime generation.
 */
class MishRuntimeController internal constructor(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val lock = Any()
    private val lifecycle = RuntimeLifecycleController()
    private val lifecycleExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-runtime-lifecycle").apply { isDaemon = true }
    }
    private val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val externalCredentialStore = ExternalProxyCredentialStore(appContext)
    private val generation = MutableStateFlow(newGeneration())
    private val stopCallbacks = mutableListOf<(Boolean) -> Unit>()

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

    /** Read-only bounded snapshot for the permission-gated Windows provisioning transaction. */
    internal fun currentExternalCredentialProvisioningSnapshot(): ExternalProxyCredentialSnapshot? =
        externalCredentialStore.currentProvisioningSnapshot()

    val isRunning: Boolean
        get() = synchronized(lock) { lifecycle.state() != RuntimeLifecycleState.STOPPED }

    /**
     * Requests one serialized start through the Rust owner. Duplicate starts are idempotent and a
     * start racing with STOPPING is remembered by the owner, not by a parallel Kotlin state machine.
     */
    fun start(): Boolean {
        val action = synchronized(lock) { lifecycle.requestStart() }
        when (action) {
            RuntimeStartAction.ALREADY_ACTIVE,
            RuntimeStartAction.QUEUED_AFTER_STOP,
            -> return true

            RuntimeStartAction.START_NOW -> Unit
        }

        if (submit(::startBlocking)) return true
        synchronized(lock) { lifecycle.startSubmissionFailed() }
        return false
    }

    /**
     * Requests exact stop without blocking the Android main thread. Completion is published only
     * after Mesh ingress -> proxy -> Cellular Egress/root-policy cleanup has completed or failed.
     */
    fun stop(onComplete: (Boolean) -> Unit = {}) {
        var completeImmediately = false
        val action = synchronized(lock) {
            val requested = lifecycle.requestStop()
            when (requested) {
                RuntimeStopAction.ALREADY_STOPPED -> completeImmediately = true
                RuntimeStopAction.ALREADY_STOPPING -> stopCallbacks += onComplete
                RuntimeStopAction.STOP_NOW -> stopCallbacks += onComplete
            }
            requested
        }

        if (completeImmediately) {
            onComplete(true)
            return
        }
        if (action != RuntimeStopAction.STOP_NOW) return
        if (submit(::stopBlocking)) return

        val callbacks = synchronized(lock) {
            // Cleanup never ran. The Rust owner intentionally keeps STOPPING terminal/fail-closed.
            lifecycle.stopSubmissionFailed()
            stopCallbacks.toList().also { stopCallbacks.clear() }
        }
        callbacks.forEach { callback -> runCatching { callback(false) } }
    }

    /**
     * Explicit rotation is accepted only from an exactly stopped, clean owner generation.
     */
    internal fun rotateExternalCredentialWhileStopped(): Boolean =
        mutateExternalCredentialWhileStopped(externalCredentialStore::rotateWhileStopped)

    /** Revocation uses the same stopped-only cutover rule and never auto-restarts the runtime. */
    internal fun revokeExternalCredentialWhileStopped(): Boolean =
        mutateExternalCredentialWhileStopped(externalCredentialStore::revokeWhileStopped)

    private fun mutateExternalCredentialWhileStopped(mutation: () -> Boolean): Boolean =
        synchronized(lock) {
            if (!lifecycle.canMutateStoppedGeneration()) return false
            val current = generation.value
            if (!current.closeExact()) {
                lifecycle.markStoppedGenerationDirty()
                return false
            }
            if (!mutation()) {
                lifecycle.markStoppedGenerationDirty()
                return false
            }
            generation.value = newGeneration()
            true
        }

    private fun startBlocking() {
        val current = synchronized(lock) {
            if (lifecycle.takeGenerationReplacementForStart()) {
                // Replacement is authorized only by the later explicit start transition.
                generation.value = newGeneration()
            }
            generation.value
        }
        val started = try {
            current.cellularRuntime.start()
            current.proxyRuntime.start()
            // The Mesh adapter waits for proxyRuntime=Running before asking the Rust transport
            // owner to bind exact Mesh listeners.
            current.meshRuntime.start()
            true
        } catch (_: Exception) {
            false
        }

        val cleanAfterFailedStart = if (started) true else current.closeExact()

        synchronized(lock) {
            val completion = lifecycle.completeStart(
                started = started,
                cleanAfterFailedStart = cleanAfterFailedStart,
            )
            if (completion.installFreshGenerationNow) {
                generation.value = newGeneration()
            }
        }
    }

    private fun stopBlocking() {
        val current = synchronized(lock) { generation.value }
        val clean = current.closeExact()

        val restart: Boolean
        val callbacks: List<(Boolean) -> Unit>
        synchronized(lock) {
            val disposition = lifecycle.completeStop(clean)
            if (disposition.installFreshGenerationNow) {
                generation.value = newGeneration()
            }
            restart = disposition.restartNow
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
        val meshRuntime = MeshIngressRuntimeBridge(
            context = appContext,
            proxyRuntime = proxyRuntime,
        )
        return RuntimeGeneration(cellularRuntime, proxyRuntime, meshRuntime)
    }

    private data class RuntimeGeneration(
        val cellularRuntime: CellularRuntimeBridge,
        val proxyRuntime: ProxyRuntimeSupervisor,
        val meshRuntime: MeshIngressRuntimeBridge,
    ) {
        fun closeExact(): Boolean = closeRuntimeGenerationExact(
            closeMesh = meshRuntime::close,
            closeProxy = proxyRuntime::close,
            closeCellular = cellularRuntime::close,
        )
    }
}
