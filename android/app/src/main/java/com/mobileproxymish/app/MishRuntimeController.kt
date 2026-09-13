package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.ProductReadinessState
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

    @OptIn(ExperimentalCoroutinesApi::class)
    val readinessSnapshot: StateFlow<ProductReadinessState> = generation
        .flatMapLatest { it.readinessRuntime.state }
        .stateIn(
            scope = observationScope,
            started = SharingStarted.Eagerly,
            initialValue = generation.value.readinessRuntime.state.value,
        )

    /** Read-only Transport Reachability projection for UI and retained device diagnostics. */
    @OptIn(ExperimentalCoroutinesApi::class)
    val meshSnapshot: StateFlow<MeshAdmissionView?> = generation
        .flatMapLatest { it.meshRuntime.snapshot }
        .stateIn(
            scope = observationScope,
            started = SharingStarted.Eagerly,
            initialValue = generation.value.meshRuntime.snapshot.value,
        )

    internal val currentCellularRuntime: CellularRuntimeBridge
        get() = generation.value.cellularRuntime

    internal val currentProxyRuntime: ProxyRuntimeSupervisor
        get() = generation.value.proxyRuntime

    internal val currentReadinessRuntime: ProductReadinessRuntime
        get() = generation.value.readinessRuntime

    internal val currentMeshRuntime: MeshIngressRuntimeBridge
        get() = generation.value.meshRuntime

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
     * after readiness probe -> Mesh ingress -> proxy -> Cellular Egress/root-policy cleanup has
     * completed or failed.
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
            // Credential cutover changes the effect generation. Rust must advance the exact owner
            // key before Android may install the new composition objects.
            if (!lifecycle.advanceStoppedGeneration()) {
                lifecycle.markStoppedGenerationDirty()
                return false
            }
            generation.value = newGeneration()
            true
        }

    private fun startBlocking() {
        val current = synchronized(lock) {
            val replacementRequired = lifecycle.generationRequiresReplacement()
            if (replacementRequired && !lifecycle.takeGenerationReplacementForStart()) {
                null
            } else {
                if (replacementRequired) {
                    // Replacement was authorized and its generation key advanced atomically in
                    // Rust before the fresh Android effects become visible.
                    generation.value = newGeneration()
                }
                generation.value
            }
        }
        if (current == null) {
            synchronized(lock) {
                lifecycle.completeStart(
                    started = false,
                    cleanAfterFailedStart = false,
                )
            }
            return
        }

        val started = try {
            current.cellularRuntime.start()
            current.proxyRuntime.start()
            // The Mesh adapter observes proxy lifecycle and realizes ingress only after the proxy
            // reaches its Rust-owned RUNNING state.
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
        val runtimeGeneration = lifecycle.generation()
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
        val readinessRuntime = ProductReadinessRuntime(
            runtimeGeneration = runtimeGeneration,
            cellularRuntime = cellularRuntime,
            proxyRuntime = proxyRuntime,
            meshRuntime = meshRuntime,
            credentialStore = externalCredentialStore,
        )
        // Private egress readiness is proved through the loopback proxy before any public Mesh
        // listener may serve. This closes the restart window where a listener existed before the
        // cellular policy, scoped DNS and TLS probe had been verified.
        meshRuntime.requireEgressReadiness(readinessRuntime.state)
        return RuntimeGeneration(
            cellularRuntime = cellularRuntime,
            proxyRuntime = proxyRuntime,
            meshRuntime = meshRuntime,
            readinessRuntime = readinessRuntime,
        )
    }

    private data class RuntimeGeneration(
        val cellularRuntime: CellularRuntimeBridge,
        val proxyRuntime: ProxyRuntimeSupervisor,
        val meshRuntime: MeshIngressRuntimeBridge,
        val readinessRuntime: ProductReadinessRuntime,
    ) {
        fun closeExact(): Boolean {
            var clean = runCatching(readinessRuntime::close).isSuccess
            clean = closeRuntimeGenerationExact(
                closeMesh = meshRuntime::close,
                closeProxy = proxyRuntime::close,
                closeCellular = cellularRuntime::close,
            ) && clean
            return clean
        }
    }
}
