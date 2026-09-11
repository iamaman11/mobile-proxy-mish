package com.mobileproxymish.app.cellular

import android.content.Context
import android.os.Process
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.CellularController
import java.io.Closeable
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

/**
 * Read-only runtime projection crossing from the Rust owner toward Android consumers.
 *
 * `OwnerSnapshot` is the natural owner's typed projection after the infrastructure
 * mechanism has been reconciled for that exact owner generation. `BoundaryUnavailable`
 * represents adapter failure and therefore cannot be interpreted as admitted readiness.
 */
sealed interface CellularRuntimeSnapshot {
    data class OwnerSnapshot(
        val admission: CellularAdmissionView,
    ) : CellularRuntimeSnapshot

    data class BoundaryUnavailable(
        val reason: CellularBoundaryFailure,
    ) : CellularRuntimeSnapshot
}

/**
 * Transient Android infrastructure hints keyed by the exact platform Network handle.
 *
 * This is deliberately not a second owner or readiness state. The Rust owner still
 * decides which handle is admitted; this cache only lets the policy adapter retrieve
 * the interface hint belonging to that exact owner-selected handle after reordered,
 * unrelated, or superseded callbacks. Access is synchronized because callback-side
 * owner updates and executor-side shutdown cleanup intentionally run on different threads.
 */
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

/** Exact owner-generation comparison used only to reject stale infrastructure effects. */
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
 *
 * Owner mutation is deliberately fast and occurs synchronously in callback submission
 * order. Bounded root operations remain on one private serial executor. This allows a
 * newer Android observation to advance Rust owner currentness even while an older root
 * transaction is in flight, so stale platform effects can be detected and revoked.
 */
class CellularRuntimeBridge(
    context: Context,
) : CellularObservationSink, Closeable {
    private val controller: CellularController?
    private val mutableSnapshot: MutableStateFlow<CellularRuntimeSnapshot>
    private val rootPolicy = CellularRootPolicy(Process.myUid())
    private val interfaceHints = CellularInterfaceHints()
    private val observer = CellularNetworkObserver(context.applicationContext, this)
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val policyExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-cellular-policy").apply { isDaemon = true }
    }

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
     * Applies the semantic event to the Rust owner immediately in callback submission
     * order, then delegates only the bounded infrastructure effect to the root executor.
     */
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

        mutableSnapshot.value = when (policyResult) {
            CellularRootPolicyResult.Enforced ->
                CellularRuntimeSnapshot.OwnerSnapshot(admission)

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
    ): CellularRuntimeSnapshot? = when (val result = rootPolicy.failClosed()) {
        is CellularRootPolicyResult.AuthorityUnavailable ->
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootAuthorityUnavailable,
            )

        is CellularRootPolicyResult.FailClosed -> when {
            result.reason != null -> CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyUnavailable(result.reason),
            )

            preserveOnCleanFailClosed -> null
            preferredFailure != null -> CellularRuntimeSnapshot.BoundaryUnavailable(preferredFailure)
            else -> CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootPolicyReconcileFailed,
            )
        }

        CellularRootPolicyResult.Enforced -> preferredFailure?.let {
            CellularRuntimeSnapshot.BoundaryUnavailable(it)
        }
    }

    private fun submitPolicyWork(block: () -> Unit) {
        try {
            policyExecutor.execute(block)
        } catch (_: RejectedExecutionException) {
            // close() owns executor shutdown. Work racing with closure is intentionally
            // dropped because the observer is already being revoked and exact cleanup
            // is serialized as the final executor effect.
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        observer.close()
        val cleanup = try {
            policyExecutor.submit {
                interfaceHints.clear()
                rootPolicy.cleanupExactOwnedRules()
            }
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
        // Includes one potentially in-flight bounded root reconciliation plus the final
        // exact cleanup transaction. This is a shutdown-only path, never UI/callback work.
        const val CLOSE_TIMEOUT_SECONDS = 60L
    }
}
