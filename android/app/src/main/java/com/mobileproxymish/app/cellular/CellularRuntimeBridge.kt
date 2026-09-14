package com.mobileproxymish.app.cellular

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Process
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.CellularBridgeRuntime
import com.mobileproxymish.ffi.CellularController
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

internal fun sameCellularOwnerGeneration(
    expected: CellularAdmissionView,
    current: CellularAdmissionView,
): Boolean = expected.lastSequence != null &&
    expected.lastSequence == current.lastSequence &&
    expected.state == current.state &&
    expected.admittedNetworkHandle == current.admittedNetworkHandle

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

    /**
     * Starts the private bridge from the exact same Rust Cellular Egress owner instance.
     * This is composition only: it neither copies nor mutates admission policy.
     */
    internal fun startPrivateBridge(
        username: String,
        password: String,
        operationTimeoutMs: ULong,
    ): CellularBridgeRuntime {
        check(!closed.get()) { "cellular runtime is closed" }
        val activeController = controller ?: error("Cellular Egress owner is unavailable")
        return activeController.startBridge(username, password, operationTimeoutMs)
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

    /**
     * Bounded composition gate for a dependent proxy generation. This reads the existing
     * Cellular Egress projection only: it neither creates an admission state nor authorizes a
     * route. An admitted OwnerSnapshot is published only after the same generation passed exact
     * root-policy reconciliation and Rust authorization.
     */
    internal fun awaitAuthorizedAdmission(timeoutMs: Long): Boolean {
        if (timeoutMs <= 0L || closed.get()) return false
        val deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs)
        while (!closed.get() && System.nanoTime() < deadline) {
            val admission = (mutableSnapshot.value as? CellularRuntimeSnapshot.OwnerSnapshot)
                ?.admission
            if (admission?.state == CellularAdmissionState.ADMITTED) return true
            Thread.sleep(AUTHORIZED_ADMISSION_POLL_MS)
        }
        return false
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

        val capturedInterface = interfaceName
        submitPolicyWork {
            if (!closed.get()) {
                reconcileOwnerGeneration(
                    activeController = activeController,
                    admission = admission,
                    interfaceName = capturedInterface,
                )
            }
        }
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

        if (policyResult is CellularRootPolicyResult.AuthorityUnavailable) {
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
                scheduleRootAuthorityRecovery(activeController)
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
            controller?.let(::scheduleRootAuthorityRecovery)
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
        val cleanup = try {
            // The lambda returns the cleanup fact.  Use Callable explicitly: the Runnable
            // overload returns a Future whose value is always null, which would turn a
            // successful exact cleanup into a false failure.
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
            throw IllegalStateException("exact PRODUCT root-policy cleanup failed")
        }
    }

    private companion object {
        const val AUTHORIZED_ADMISSION_POLL_MS = 100L
        const val CLOSE_TIMEOUT_SECONDS = 60L
        const val EFFECT_DRAIN_TIMEOUT_MS = 20_000L
    }
}
