package com.mobileproxymish.app.cellular

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Process
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.CellularController
import com.mobileproxymish.ffi.CellularDnsDiagnosticView
import com.mobileproxymish.ffi.PublicIpObservationView
import java.io.Closeable
import java.util.concurrent.Callable
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Adapter-boundary failure. None of these values becomes a Cellular Egress owner fact. */
sealed interface CellularBoundaryFailure {
    data object NativeLibraryUnavailable : CellularBoundaryFailure
    data object ForeignCallFailed : CellularBoundaryFailure
    data object RootAuthorityUnavailable : CellularBoundaryFailure
    data object RootPolicyReconcileFailed : CellularBoundaryFailure
    data object RootPolicyGenerationChanged : CellularBoundaryFailure
    data object RootPolicyCleanupFailed : CellularBoundaryFailure

    data class RootPolicyUnavailable(
        val failure: CellularRootPolicyFailure,
    ) : CellularBoundaryFailure
}

sealed interface CellularRuntimeSnapshot {
    data class OwnerSnapshot(
        val admission: CellularAdmissionView,
    ) : CellularRuntimeSnapshot

    data class BoundaryUnavailable(
        val reason: CellularBoundaryFailure,
    ) : CellularRuntimeSnapshot
}

internal class CellularInterfaceHints {
    private val byNetwork = mutableMapOf<ULong, String>()

    @Synchronized
    fun observed(networkHandle: ULong, interfaceName: String?) {
        if (interfaceName != null) {
            byNetwork[networkHandle] = interfaceName
        }
    }

    @Synchronized
    fun lost(networkHandle: ULong) {
        byNetwork.remove(networkHandle)
    }

    @Synchronized
    fun interfaceFor(admittedNetworkHandle: ULong?): String? =
        admittedNetworkHandle?.let(byNetwork::get)

    @Synchronized
    fun clear() {
        byNetwork.clear()
    }
}

internal data class CellularReconcileDiagnostic(
    val requested: Long,
    val executed: Long,
    val coalesced: Long,
    val pending: Boolean,
    val drainScheduled: Boolean,
)

internal data class CellularRootRecoveryDiagnostic(
    val pending: Boolean,
    val attemptsSinceReset: Int,
    val nextDelayMs: Long,
)

internal class LatestCellularReconcileQueue<T> {
    private var latest: T? = null
    private var drainScheduled = false
    private var requested = 0L
    private var executed = 0L
    private var coalesced = 0L

    /**
     * Publishes only the newest requested owner generation. Returns true only when the caller
     * must schedule the single drain task.
     */
    @Synchronized
    fun offer(value: T): Boolean {
        requested += 1
        if (latest != null) coalesced += 1
        latest = value
        if (drainScheduled) return false
        drainScheduled = true
        return true
    }

    @Synchronized
    fun takeLatest(): T? {
        val value = latest
        latest = null
        return value
    }

    /**
     * Completes one drain task. If a newer request arrived while it ran, atomically reserves
     * exactly one successor drain task.
     */
    @Synchronized
    fun finishDrain(): Boolean {
        drainScheduled = false
        if (latest == null) return false
        drainScheduled = true
        return true
    }

    @Synchronized
    fun recordExecuted() {
        executed += 1
    }

    @Synchronized
    fun cancelPending() {
        latest = null
    }

    @Synchronized
    fun diagnostic(): CellularReconcileDiagnostic = CellularReconcileDiagnostic(
        requested = requested,
        executed = executed,
        coalesced = coalesced,
        pending = latest != null,
        drainScheduled = drainScheduled,
    )
}

private data class CellularPolicyReconcileRequest(
    val controller: CellularController,
    val admission: CellularAdmissionView,
    val interfaceName: String?,
)

internal fun sameCellularOwnerGeneration(
    expected: CellularAdmissionView,
    current: CellularAdmissionView,
): Boolean = expected.lastSequence != null &&
    expected.lastSequence == current.lastSequence &&
    expected.state == current.state &&
    expected.admittedNetworkHandle == current.admittedNetworkHandle

/** Only transport/incomplete authority states are expected to recover without operator action. */
internal fun shouldRetryRootAuthority(status: RootAuthorityStatus): Boolean = when (status) {
    RootAuthorityStatus.Unavailable,
    RootAuthorityStatus.Incomplete,
    -> true

    RootAuthorityStatus.Ready,
    RootAuthorityStatus.InteractiveGrantRequired,
    RootAuthorityStatus.Denied,
    -> false
}

/**
 * One process-generation bridge between Android observations, the Rust natural owner,
 * and the narrow root policy-routing adapter that realizes an already owner-admitted
 * decision. This class owns no cellular admission policy.
 */
class CellularRuntimeBridge(
    context: Context,
) : CellularObservationSink, Closeable {
    private val controller: CellularController?
    private val mutableSnapshot: MutableStateFlow<CellularRuntimeSnapshot>
    // Local diagnostic builds use a separate Android UID. Keep their root-policy objects in
    // an isolated namespace so they cannot claim, remove, or mask a release appliance's
    // fail-closed state during DEVICE-1 physical validation.
    private val rootPolicy = CellularRootPolicy(
        productUid = Process.myUid(),
        debugIsolation = context.packageName.endsWith(".debug") &&
            (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0,
    )
    private val interfaceHints = CellularInterfaceHints()
    private val observer = CellularNetworkObserver(context.applicationContext, this)
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val policyExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-cellular-policy").apply { isDaemon = true }
    }
    private val rootRecoveryScheduler = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "mish-root-authority-recovery").apply { isDaemon = true }
    }
    private val rootRecoveryPending = AtomicBoolean(false)
    private val rootRecoveryBackoff = RootAuthorityRecoveryBackoff()
    private val latestReconcile = LatestCellularReconcileQueue<CellularPolicyReconcileRequest>()

    val snapshot: StateFlow<CellularRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    init {
        var createdController: CellularController? = null
        val initialSnapshot = try {
            createdController = CellularController()
            CellularRuntimeSnapshot.OwnerSnapshot(createdController.admissionSnapshot())
        } catch (_: LinkageError) {
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
        } catch (_: Exception) {
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
        }

        controller = createdController
        mutableSnapshot = MutableStateFlow(initialSnapshot)
    }

    /** Exact FFI handle for composition with the native proxy runtime; no state is copied. */
    internal fun nativeController(): CellularController {
        check(!closed.get()) { "cellular runtime is closed" }
        return controller ?: error("Cellular Egress owner is unavailable")
    }

    /** Read-only process-wide native DNS execution facts; no Android-side accounting is kept. */
    internal fun dnsDiagnosticObservation(): CellularDnsDiagnosticView? = try {
        controller?.dnsDiagnosticSnapshot()
    } catch (_: LinkageError) {
        null
    } catch (_: Exception) {
        null
    }

    /**
     * One synchronous bounded public-egress observation. Rust remains the owner of endpoint,
     * generation/currentness, DNS authority, deadline and strict IP parsing; this bridge delegates
     * only the Android TLS/socket effect and keeps no duplicate public-IP state.
     */
    internal fun observePublicEgressIp(
        timeoutMs: Long = PUBLIC_IP_OBSERVATION_TIMEOUT_MS,
    ): PublicIpObservationView {
        check(!closed.get()) { "cellular runtime is closed" }
        val activeController = controller ?: error("Cellular Egress owner is unavailable")
        return PublicIpProbeEffect(activeController).observe(timeoutMs)
    }

    fun start() {
        if (controller == null || closed.get() || !started.compareAndSet(false, true)) return

        submitPolicyWork {
            if (closed.get()) return@submitPolicyWork

            mutableSnapshot.value = snapshotForFailClosed(
                preferredFailure = null,
                preserveOnCleanFailClosed = true,
            ) ?: mutableSnapshot.value

            if (!closed.get()) {
                observer.start()
                if (closed.get()) {
                    observer.close()
                }
            }
        }
    }

    override fun onEvent(event: CellularNetworkEvent) {
        if (closed.get()) return

        val activeController = controller ?: run {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
            return
        }

        val admission = try {
            when (event) {
                is CellularNetworkEvent.Observed -> interfaceHints.observed(
                    networkHandle = event.networkHandle.toULong(),
                    interfaceName = event.interfaceName,
                )

                is CellularNetworkEvent.Lost -> interfaceHints.lost(
                    networkHandle = event.networkHandle.toULong(),
                )
            }

            when (event) {
                is CellularNetworkEvent.Observed -> activeController.observeNetwork(
                    sequence = event.sequence.toULong(),
                    networkHandle = event.networkHandle.toULong(),
                    isCellular = event.isCellular,
                    hasInternet = event.hasInternet,
                    isValidated = event.isValidated,
                    isNotVpn = event.isNotVpn,
                )

                is CellularNetworkEvent.Lost -> activeController.networkLost(
                    sequence = event.sequence.toULong(),
                    networkHandle = event.networkHandle.toULong(),
                )
            }
        } catch (_: LinkageError) {
            enqueueOwnerBoundaryFailure(CellularBoundaryFailure.NativeLibraryUnavailable)
            return
        } catch (_: Exception) {
            enqueueOwnerBoundaryFailure(CellularBoundaryFailure.ForeignCallFailed)
            return
        }

        if (closed.get()) return

        val admittedHandle = admission.admittedNetworkHandle
        var interfaceName = interfaceHints.interfaceFor(admittedHandle)
        if (interfaceName == null && admittedHandle != null) {
            interfaceName = try {
                observer.interfaceNameFor(admittedHandle)
            } catch (_: Exception) {
                null
            }
            interfaceHints.observed(admittedHandle, interfaceName)
        }

        enqueueLatestReconcile(
            CellularPolicyReconcileRequest(
                controller = activeController,
                admission = admission,
                interfaceName = interfaceName,
            ),
        )
    }

    private fun enqueueLatestReconcile(request: CellularPolicyReconcileRequest) {
        if (closed.get()) return
        if (!latestReconcile.offer(request)) return
        submitPolicyWork(::drainLatestReconcile)
    }

    private fun drainLatestReconcile() {
        val request = latestReconcile.takeLatest()
        try {
            if (request != null && !closed.get()) {
                reconcileOwnerGeneration(
                    activeController = request.controller,
                    admission = request.admission,
                    interfaceName = request.interfaceName,
                )
                latestReconcile.recordExecuted()
            }
        } finally {
            val scheduleAgain = latestReconcile.finishDrain()
            if (closed.get()) {
                latestReconcile.cancelPending()
            } else if (scheduleAgain) {
                submitPolicyWork(::drainLatestReconcile)
            }
        }
    }

    internal fun reconcileDiagnosticObservation(): CellularReconcileDiagnostic =
        latestReconcile.diagnostic()

    internal fun rootPolicyReconcileDiagnosticObservation(): CellularRootPolicyReconcileDiagnostic =
        rootPolicy.reconcileDiagnosticObservation()

    internal fun rootRecoveryDiagnosticObservation(): CellularRootRecoveryDiagnostic {
        val backoff = rootRecoveryBackoff.diagnostic()
        return CellularRootRecoveryDiagnostic(
            pending = rootRecoveryPending.get(),
            attemptsSinceReset = backoff.attemptsSinceReset,
            nextDelayMs = backoff.nextDelayMs,
        )
    }

    private fun reconcileOwnerGeneration(
        activeController: CellularController,
        admission: CellularAdmissionView,
        interfaceName: String?,
    ) {
        val before = currentAdmissionOrNull(activeController)
        if (before == null) {
            mutableSnapshot.value = snapshotForFailClosed(
                preferredFailure = CellularBoundaryFailure.ForeignCallFailed,
            ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
            return
        }
        if (!sameCellularOwnerGeneration(admission, before)) {
            mutableSnapshot.value = snapshotForFailClosed(
                preferredFailure = CellularBoundaryFailure.RootPolicyGenerationChanged,
            ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyGenerationChanged,
            )
            return
        }

        val quiesced = try {
            activeController.awaitRootPolicyQuiesced(EFFECT_DRAIN_TIMEOUT_MS.toULong())
        } catch (_: LinkageError) {
            false
        } catch (_: Exception) {
            false
        }
        if (!quiesced) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyReconcileFailed,
            )
            return
        }

        val policyResult = rootPolicy.reconcile(
            admitted = admission.state == CellularAdmissionState.ADMITTED,
            interfaceName = interfaceName,
        )

        val after = currentAdmissionOrNull(activeController)
        if (after == null) {
            mutableSnapshot.value = snapshotForFailClosed(
                preferredFailure = CellularBoundaryFailure.ForeignCallFailed,
            ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
            return
        }
        if (!sameCellularOwnerGeneration(admission, after)) {
            mutableSnapshot.value = snapshotForFailClosed(
                preferredFailure = CellularBoundaryFailure.RootPolicyGenerationChanged,
            ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyGenerationChanged,
            )
            return
        }

        if (policyResult is CellularRootPolicyResult.AuthorityUnavailable &&
            shouldRetryRootAuthority(policyResult.status)
        ) {
            scheduleRootAuthorityRecovery(activeController)
        } else {
            resetRootAuthorityRecovery()
        }

        mutableSnapshot.value = when (policyResult) {
            CellularRootPolicyResult.Enforced -> {
                val sequence = admission.lastSequence
                val handle = admission.admittedNetworkHandle
                val authorized = if (sequence != null && handle != null) {
                    try {
                        activeController.authorizeRootPolicy(sequence, handle)
                    } catch (_: LinkageError) {
                        false
                    } catch (_: Exception) {
                        false
                    }
                } else {
                    false
                }
                if (authorized) {
                    CellularRuntimeSnapshot.OwnerSnapshot(admission)
                } else {
                    snapshotForFailClosed(
                        preferredFailure = CellularBoundaryFailure.RootPolicyGenerationChanged,
                    ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(
                        CellularBoundaryFailure.RootPolicyGenerationChanged,
                    )
                }
            }

            is CellularRootPolicyResult.FailClosed -> {
                if (admission.state != CellularAdmissionState.ADMITTED &&
                    policyResult.reason == null
                ) {
                    CellularRuntimeSnapshot.OwnerSnapshot(admission)
                } else {
                    CellularRuntimeSnapshot.BoundaryUnavailable(
                        policyResult.reason?.let {
                            CellularBoundaryFailure.RootPolicyUnavailable(it)
                        } ?: CellularBoundaryFailure.RootPolicyReconcileFailed,
                    )
                }
            }

            is CellularRootPolicyResult.AuthorityUnavailable ->
                CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.RootAuthorityUnavailable,
                )
        }
    }

    private fun scheduleRootAuthorityRecovery(activeController: CellularController) {
        if (closed.get() || !rootRecoveryPending.compareAndSet(false, true)) return
        val delayMs = rootRecoveryBackoff.nextDelayMs()
        try {
            rootRecoveryScheduler.schedule(
                {
                    val shouldRun = rootRecoveryPending.compareAndSet(true, false) && !closed.get()
                    if (shouldRun) {
                        submitPolicyWork {
                            if (!closed.get()) retryRootAuthority(activeController)
                        }
                    }
                },
                delayMs,
                TimeUnit.MILLISECONDS,
            )
        } catch (_: RejectedExecutionException) {
            rootRecoveryPending.set(false)
        }
    }

    private fun retryRootAuthority(activeController: CellularController) {
        val admission = currentAdmissionOrNull(activeController)
        if (admission == null) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
            return
        }

        // Before the first Android network observation there is no owner sequence to compare.
        // Recover only the fail-closed base in that state; never manufacture ADMITTED authority.
        if (admission.lastSequence == null) {
            retryInitialFailClosedBase(activeController, admission)
            return
        }

        val admittedHandle = admission.admittedNetworkHandle
        var interfaceName = interfaceHints.interfaceFor(admittedHandle)
        if (interfaceName == null && admittedHandle != null) {
            interfaceName = try {
                observer.interfaceNameFor(admittedHandle)
            } catch (_: Exception) {
                null
            }
            interfaceHints.observed(admittedHandle, interfaceName)
        }

        reconcileOwnerGeneration(
            activeController = activeController,
            admission = admission,
            interfaceName = interfaceName,
        )
    }

    private fun retryInitialFailClosedBase(
        activeController: CellularController,
        admission: CellularAdmissionView,
    ) {
        val quiesced = try {
            activeController.closeRootPolicyGate()
            activeController.awaitRootPolicyQuiesced(EFFECT_DRAIN_TIMEOUT_MS.toULong())
        } catch (_: Exception) {
            false
        } catch (_: LinkageError) {
            false
        }
        if (!quiesced) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyReconcileFailed,
            )
            return
        }

        val result = try {
            rootPolicy.failClosed()
        } catch (_: Exception) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyReconcileFailed,
            )
            return
        }

        mutableSnapshot.value = when (result) {
            is CellularRootPolicyResult.AuthorityUnavailable -> {
                if (shouldRetryRootAuthority(result.status)) {
                    scheduleRootAuthorityRecovery(activeController)
                } else {
                    resetRootAuthorityRecovery()
                }
                CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.RootAuthorityUnavailable,
                )
            }

            is CellularRootPolicyResult.FailClosed -> {
                resetRootAuthorityRecovery()
                result.reason?.let {
                    CellularRuntimeSnapshot.BoundaryUnavailable(
                        CellularBoundaryFailure.RootPolicyUnavailable(it),
                    )
                } ?: CellularRuntimeSnapshot.OwnerSnapshot(admission)
            }

            CellularRootPolicyResult.Enforced -> {
                resetRootAuthorityRecovery()
                CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.RootPolicyReconcileFailed,
                )
            }
        }
    }

    private fun resetRootAuthorityRecovery() {
        rootRecoveryPending.set(false)
        rootRecoveryBackoff.reset()
    }

    private fun currentAdmissionOrNull(
        activeController: CellularController,
    ): CellularAdmissionView? = try {
        activeController.admissionSnapshot()
    } catch (_: LinkageError) {
        null
    } catch (_: Exception) {
        null
    }

    private fun enqueueOwnerBoundaryFailure(failure: CellularBoundaryFailure) {
        submitPolicyWork {
            if (!closed.get()) {
                mutableSnapshot.value = snapshotForFailClosed(
                    preferredFailure = failure,
                ) ?: CellularRuntimeSnapshot.BoundaryUnavailable(failure)
            }
        }
    }

    private fun snapshotForFailClosed(
        preferredFailure: CellularBoundaryFailure?,
        preserveOnCleanFailClosed: Boolean = false,
    ): CellularRuntimeSnapshot? {
        val quiesced = try {
            controller?.closeRootPolicyGate()
            controller?.awaitRootPolicyQuiesced(EFFECT_DRAIN_TIMEOUT_MS.toULong()) ?: true
        } catch (_: Exception) {
            false
        } catch (_: LinkageError) {
            false
        }
        if (!quiesced) {
            return CellularRuntimeSnapshot.BoundaryUnavailable(
                preferredFailure ?: CellularBoundaryFailure.RootPolicyReconcileFailed,
            )
        }
        return when (val result = rootPolicy.failClosed()) {
            is CellularRootPolicyResult.AuthorityUnavailable -> {
                if (shouldRetryRootAuthority(result.status)) {
                    controller?.let(::scheduleRootAuthorityRecovery)
                } else {
                    resetRootAuthorityRecovery()
                }
                CellularRuntimeSnapshot.BoundaryUnavailable(
                    CellularBoundaryFailure.RootAuthorityUnavailable,
                )
            }

            is CellularRootPolicyResult.FailClosed -> {
                resetRootAuthorityRecovery()
                when {
                    result.reason != null -> CellularRuntimeSnapshot.BoundaryUnavailable(
                        CellularBoundaryFailure.RootPolicyUnavailable(result.reason),
                    )

                    preserveOnCleanFailClosed -> null
                    preferredFailure != null -> CellularRuntimeSnapshot.BoundaryUnavailable(preferredFailure)
                    else -> CellularRuntimeSnapshot.BoundaryUnavailable(
                        CellularBoundaryFailure.RootPolicyReconcileFailed,
                    )
                }
            }

            CellularRootPolicyResult.Enforced -> {
                resetRootAuthorityRecovery()
                preferredFailure?.let {
                    CellularRuntimeSnapshot.BoundaryUnavailable(it)
                }
            }
        }
    }

    private fun submitPolicyWork(block: () -> Unit) {
        try {
            policyExecutor.execute(block)
        } catch (_: RejectedExecutionException) {
            // close() owns executor shutdown. Work racing with closure is intentionally dropped.
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        rootRecoveryPending.set(false)
        rootRecoveryScheduler.shutdownNow()
        runCatching { controller?.closeRootPolicyGate() }
        observer.close()
        // No stale callback backlog is allowed to sit in front of exact teardown. At most the
        // currently executing policy effect may complete before the cleanup Callable.
        latestReconcile.cancelPending()
        val cleanup = try {
            // The lambda returns the cleanup fact. Use Callable explicitly: the Runnable overload
            // returns a Future whose value is always null, which would turn a successful exact
            // cleanup into a false failure.
            policyExecutor.submit(Callable {
                interfaceHints.clear()
                val quiesced = try {
                    controller?.awaitRootPolicyQuiesced(EFFECT_DRAIN_TIMEOUT_MS.toULong()) ?: true
                } catch (_: Exception) {
                    false
                } catch (_: LinkageError) {
                    false
                }
                quiesced && rootPolicy.cleanupExactOwnedRules()
            })
        } catch (_: RejectedExecutionException) {
            null
        }

        val cleanupSucceeded = if (cleanup == null) {
            false
        } else {
            try {
                cleanup.get(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS) == true
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                false
            } catch (_: Exception) {
                false
            }
        }

        policyExecutor.shutdownNow()

        if (!cleanupSucceeded) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyCleanupFailed,
            )
            val stage = rootPolicy.cleanupFailureStage()?.name ?: "UNKNOWN"
            throw IllegalStateException("exact PRODUCT root-policy cleanup failed stage=$stage")
        }
    }

    private companion object {
        const val CLOSE_TIMEOUT_SECONDS = 60L
        const val EFFECT_DRAIN_TIMEOUT_MS = 20_000L
        const val PUBLIC_IP_OBSERVATION_TIMEOUT_MS = 15_000L
    }
}
