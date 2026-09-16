package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.ProxyServingFailure
import com.mobileproxymish.ffi.RuntimeLifecycleController
import com.mobileproxymish.ffi.RuntimeLifecycleState
import com.mobileproxymish.ffi.RuntimeStartAction
import com.mobileproxymish.ffi.RuntimeStopAction
import com.mobileproxymish.ffi.proxyRecoveryDelayMs
import com.mobileproxymish.ffi.proxyServingFailureRecoverable
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
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
    private val recoveryScheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "mish-runtime-recovery-effect").apply { isDaemon = true }
    }
    private val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val externalCredentialStore = ExternalProxyCredentialStore(appContext)
    private val generation = MutableStateFlow(newGeneration())
    private val stopCallbacks = mutableListOf<(Boolean) -> Unit>()
    private val automaticRecoveryPending = AtomicBoolean(false)
    private val automaticRecoveryAttempts = AtomicInteger(0)

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

    /** Execute only the Rust-owned proxy recovery policy; the typed reason is already owner-owned. */
    private fun scheduleProxyRecoveryIfAllowed(reason: ProxyServingFailure) {
        if (!proxyServingFailureRecoverable(reason)) return
        if (!isRunning || !automaticRecoveryPending.compareAndSet(false, true)) return
        val attempt = automaticRecoveryAttempts.getAndIncrement().coerceAtLeast(0).toUInt()
        val delayMs = proxyRecoveryDelayMs(attempt).toLong()
        recoveryScheduler.schedule({
            if (!isRunning || proxySnapshot.value !is ProxyRuntimeSnapshot.Failed) {
                automaticRecoveryPending.set(false)
                return@schedule
            }
            stop { clean ->
                automaticRecoveryPending.set(false)
                if (clean) start()
            }
        }, delayMs, TimeUnit.MILLISECONDS)
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
            cellularRuntime = cellularRuntime,
            publicCredentials = externalCredentialStore,
            onFailureObserved = ::scheduleProxyRecoveryIfAllowed,
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
