package com.mobileproxymish.app

import android.content.Context
import android.content.pm.ApplicationInfo
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.NativeProductRuntime
import com.mobileproxymish.ffi.NativeReadinessObserver
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
internal data class RuntimeRecoveryDiagnosticObservation(
    val runtimeGeneration: ULong,
    val proxyRecoveryPending: Boolean,
    val proxyRecoveryAttemptsScheduled: Int,
    val proxyRecoveryNextDelayMs: Long,
)

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
 * Rust owns start/stop/restart/generation-replacement and proxy recovery policy. This class only
 * serializes Android effects, executes the runtime-requested delay, stores platform callback
 * closures, and publishes owner projections from the currently installed runtime generation.
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
        .flatMapLatest { it.readinessState }
        .stateIn(
            scope = observationScope,
            started = SharingStarted.Eagerly,
            initialValue = generation.value.readinessState.value,
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

    internal val currentProductRuntime: NativeProductRuntime
        get() = generation.value.productRuntime

    internal val currentMeshRuntime: MeshIngressRuntimeBridge
        get() = generation.value.meshRuntime

    /** Read-only bounded snapshot for the permission-gated Windows provisioning transaction. */
    internal fun currentExternalCredentialProvisioningSnapshot(): ExternalProxyCredentialSnapshot? =
        externalCredentialStore.currentProvisioningSnapshot()

    internal fun recoveryDiagnosticObservation(): RuntimeRecoveryDiagnosticObservation =
        synchronized(lock) {
            val proxy = generation.value.productRuntime.proxyRuntimeSnapshot()
            RuntimeRecoveryDiagnosticObservation(
                runtimeGeneration = lifecycle.generation(),
                proxyRecoveryPending = proxy.recoveryPending,
                proxyRecoveryAttemptsScheduled = proxy.recoveryAttemptsSinceSuccess.toInt(),
                proxyRecoveryNextDelayMs = proxy.recoveryNextDelayMs.toLong(),
            )
        }

    val isRunning: Boolean
        get() = synchronized(lock) { lifecycle.state() != RuntimeLifecycleState.STOPPED }

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
            lifecycle.stopSubmissionFailed()
            stopCallbacks.toList().also { stopCallbacks.clear() }
        }
        callbacks.forEach { callback -> runCatching { callback(false) } }
    }

    internal fun rotateExternalCredentialWhileStopped(): Boolean =
        mutateExternalCredentialWhileStopped(externalCredentialStore::rotateWhileStopped)

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
        val debugIsolation = appContext.packageName.endsWith(".debug") &&
            (appContext.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
        val productRuntime = NativeProductRuntime(
            appContext.applicationInfo.uid.toUInt(),
            debugIsolation,
            runtimeGeneration,
        )
        try {
            val cellularRuntime = CellularRuntimeBridge(appContext, productRuntime)
            val proxyRuntime = ProxyRuntimeSupervisor(
                productRuntime = productRuntime,
                publicCredentials = externalCredentialStore,
            )
            val meshRuntime = MeshIngressRuntimeBridge(
                context = appContext,
                productRuntime = productRuntime,
            )
            val readinessState = MutableStateFlow(productRuntime.readinessSnapshot())
            productRuntime.observeReadiness(
                object : NativeReadinessObserver {
                    override fun onReadiness(readiness: ProductReadinessState) {
                        readinessState.value = readiness
                    }
                },
            )
            return RuntimeGeneration(
                productRuntime = productRuntime,
                cellularRuntime = cellularRuntime,
                proxyRuntime = proxyRuntime,
                meshRuntime = meshRuntime,
                readinessState = readinessState,
            )
        } catch (failure: Throwable) {
            runCatching { productRuntime.shutdown() }
            throw failure
        }
    }

    private data class RuntimeGeneration(
        val productRuntime: NativeProductRuntime,
        val cellularRuntime: CellularRuntimeBridge,
        val proxyRuntime: ProxyRuntimeSupervisor,
        val meshRuntime: MeshIngressRuntimeBridge,
        val readinessState: MutableStateFlow<ProductReadinessState>,
    ) {
        fun closeExact(): Boolean {
            var clean = closeRuntimeGenerationExact(
                closeMesh = meshRuntime::close,
                closeProxy = proxyRuntime::close,
                closeCellular = cellularRuntime::close,
            )
            clean = runCatching { productRuntime.shutdown() }.isSuccess && clean
            return clean
        }
    }
}
