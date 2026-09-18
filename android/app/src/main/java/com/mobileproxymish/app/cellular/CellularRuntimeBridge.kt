package com.mobileproxymish.app.cellular

import android.content.Context
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.CellularDnsDiagnosticView
import com.mobileproxymish.ffi.CellularPolicyPublicationView
import com.mobileproxymish.ffi.NativeCellularPolicyObserver
import com.mobileproxymish.ffi.NativeProductRuntime
import com.mobileproxymish.ffi.PublicIpObservationView
import com.mobileproxymish.ffi.RootPolicyFailureView
import com.mobileproxymish.ffi.RootPolicyStateView
import java.io.Closeable
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
        val failure: RootPolicyFailureView,
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

internal data class CellularRootPolicyReconcileDiagnostic(
    val attempts: Long = 0,
    val totalExecutorCommands: Long = 0,
    val totalObservationCommands: Long = 0,
    val totalMutationCommands: Long = 0,
    val totalDuplicateObservations: Long = 0,
    val lastReconcileElapsedMs: Long = 0,
    val maxReconcileElapsedMs: Long = 0,
    val lastPolicyEffectElapsedMs: Long = 0,
    val maxPolicyEffectElapsedMs: Long = 0,
    val lastExecutorCommands: Int = 0,
    val lastObservationCommands: Int = 0,
    val lastMutationCommands: Int = 0,
    val lastDuplicateObservations: Int = 0,
    val lastIncompleteOrTimedOutCommands: Int = 0,
    val lastMutationFailures: Int = 0,
)

/**
 * Thin Android platform adapter around one stable native PRODUCT process handle.
 *
 * Rust owns Cellular admission/currentness, root-policy transaction/recovery and generation
 * coalescing. Android only observes ConnectivityManager, resolves LinkProperties for the exact
 * callback network handle when needed, forwards bounded native operations, and projects native facts.
 */
class CellularRuntimeBridge(
    context: Context,
    private val productRuntime: NativeProductRuntime,
) : CellularObservationSink, Closeable {
    private val observer = CellularNetworkObserver(context.applicationContext, this)
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val mutableSnapshot = MutableStateFlow(initialSnapshot())

    val snapshot: StateFlow<CellularRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    init {
        try {
            productRuntime.observeCellularPolicy(
                object : NativeCellularPolicyObserver {
                    override fun onCellularPolicyPublication(
                        publication: CellularPolicyPublicationView,
                    ) {
                        if (!closed.get()) {
                            mutableSnapshot.value = projectPublication(publication)
                        }
                    }
                },
            )
        } catch (_: LinkageError) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
        } catch (_: Exception) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
        }
    }

    /** Read-only process-wide native DNS execution facts; no Android-side accounting is kept. */
    internal fun dnsDiagnosticObservation(): CellularDnsDiagnosticView? = try {
        productRuntime.dnsDiagnosticSnapshot()
    } catch (_: LinkageError) {
        null
    } catch (_: Exception) {
        null
    }

    internal fun reconcileDiagnosticObservation(): CellularReconcileDiagnostic = try {
        productRuntime.cellularReconcileDiagnostic().let { view ->
            CellularReconcileDiagnostic(
                requested = view.requested.toLong(),
                executed = view.executed.toLong(),
                coalesced = view.coalesced.toLong(),
                pending = view.pending,
                drainScheduled = view.drainScheduled,
            )
        }
    } catch (_: Throwable) {
        CellularReconcileDiagnostic(0, 0, 0, pending = false, drainScheduled = false)
    }

    internal fun rootPolicyReconcileDiagnosticObservation(): CellularRootPolicyReconcileDiagnostic =
        try {
            productRuntime.rootPolicyReconcileDiagnostic().let { view ->
                CellularRootPolicyReconcileDiagnostic(
                    attempts = view.attempts.toLong(),
                    totalExecutorCommands = view.totalExecutorCommands.toLong(),
                    totalObservationCommands = view.totalObservationCommands.toLong(),
                    totalMutationCommands = view.totalMutationCommands.toLong(),
                    totalDuplicateObservations = view.totalDuplicateObservations.toLong(),
                    lastReconcileElapsedMs = view.lastReconcileElapsedMs.toLong(),
                    maxReconcileElapsedMs = view.maxReconcileElapsedMs.toLong(),
                    lastPolicyEffectElapsedMs = view.lastPolicyEffectElapsedMs.toLong(),
                    maxPolicyEffectElapsedMs = view.maxPolicyEffectElapsedMs.toLong(),
                    lastExecutorCommands = view.lastExecutorCommands.coerceAtMost(Int.MAX_VALUE.toULong()).toInt(),
                    lastObservationCommands = view.lastObservationCommands.coerceAtMost(Int.MAX_VALUE.toULong()).toInt(),
                    lastMutationCommands = view.lastMutationCommands.coerceAtMost(Int.MAX_VALUE.toULong()).toInt(),
                    lastDuplicateObservations = view.lastDuplicateObservations.coerceAtMost(Int.MAX_VALUE.toULong()).toInt(),
                    lastIncompleteOrTimedOutCommands =
                        view.lastIncompleteOrTimedOutCommands.coerceAtMost(Int.MAX_VALUE.toULong()).toInt(),
                    lastMutationFailures = view.lastMutationFailures.coerceAtMost(Int.MAX_VALUE.toULong()).toInt(),
                )
            }
        } catch (_: Throwable) {
            CellularRootPolicyReconcileDiagnostic()
        }

    internal fun rootRecoveryDiagnosticObservation(): CellularRootRecoveryDiagnostic = try {
        productRuntime.rootRecoveryDiagnostic().let { view ->
            CellularRootRecoveryDiagnostic(
                pending = view.pending,
                attemptsSinceReset = view.attemptsSinceReset.coerceAtMost(Int.MAX_VALUE.toUInt()).toInt(),
                nextDelayMs = view.nextDelayMs.toLong(),
            )
        }
    } catch (_: Throwable) {
        CellularRootRecoveryDiagnostic(
            pending = false,
            attemptsSinceReset = 0,
            nextDelayMs = 0,
        )
    }

    /**
     * One synchronous bounded public-egress observation. Rust/Tokio owns owner-bound DNS,
     * TCP/TLS/HTTPS, deadline/currentness and final IP parsing; Android receives only the result.
     */
    internal fun observePublicEgressIp(
        timeoutMs: Long = PUBLIC_IP_OBSERVATION_TIMEOUT_MS,
    ): PublicIpObservationView {
        check(!closed.get()) { "cellular runtime is closed" }
        return productRuntime.observePublicEgressIp(timeoutMs.toULong())
    }

    fun start() {
        if (closed.get() || !started.compareAndSet(false, true)) return

        try {
            observer.start()
            if (closed.get()) observer.close()
        } catch (error: LinkageError) {
            started.set(false)
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
            throw error
        } catch (error: Exception) {
            started.set(false)
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
            throw IllegalStateException("Cellular platform observer could not start", error)
        }
    }

    fun stop() {
        if (closed.get() || !started.compareAndSet(true, false)) return
        observer.close()
        productRuntime.invalidateCellularPlatformFacts()
    }

    override fun onEvent(event: CellularNetworkEvent) {
        if (closed.get() || !started.get()) return

        try {
            when (event) {
                is CellularNetworkEvent.Observed -> {
                    val exactInterface = event.interfaceName ?: try {
                        observer.interfaceNameFor(event.networkHandle.toULong())
                    } catch (_: Exception) {
                        null
                    }
                    productRuntime.observeNetwork(
                        sequence = event.sequence.toULong(),
                        networkHandle = event.networkHandle.toULong(),
                        isCellular = event.isCellular,
                        hasInternet = event.hasInternet,
                        isValidated = event.isValidated,
                        isNotVpn = event.isNotVpn,
                        interfaceName = exactInterface,
                    )
                }

                is CellularNetworkEvent.Lost -> productRuntime.networkLost(
                    sequence = event.sequence.toULong(),
                    networkHandle = event.networkHandle.toULong(),
                )
            }
        } catch (_: LinkageError) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
        } catch (_: Exception) {
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
        }
    }

    private fun initialSnapshot(): CellularRuntimeSnapshot = try {
        CellularRuntimeSnapshot.OwnerSnapshot(productRuntime.admissionSnapshot())
    } catch (_: LinkageError) {
        CellularRuntimeSnapshot.BoundaryUnavailable(
            CellularBoundaryFailure.NativeLibraryUnavailable,
        )
    } catch (_: Exception) {
        CellularRuntimeSnapshot.BoundaryUnavailable(
            CellularBoundaryFailure.ForeignCallFailed,
        )
    }

    private fun projectPublication(
        publication: CellularPolicyPublicationView,
    ): CellularRuntimeSnapshot = when (publication.state) {
        RootPolicyStateView.ENFORCED ->
            CellularRuntimeSnapshot.OwnerSnapshot(publication.admission)

        RootPolicyStateView.FAIL_CLOSED -> {
            if (publication.admission.state != CellularAdmissionState.ADMITTED &&
                publication.failure == null
            ) {
                CellularRuntimeSnapshot.OwnerSnapshot(publication.admission)
            } else {
                CellularRuntimeSnapshot.BoundaryUnavailable(
                    publication.failure?.let(CellularBoundaryFailure::RootPolicyUnavailable)
                        ?: CellularBoundaryFailure.RootPolicyReconcileFailed,
                )
            }
        }

        RootPolicyStateView.AUTHORITY_UNAVAILABLE ->
            CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.RootAuthorityUnavailable,
            )
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        started.set(false)
        observer.close()
        productRuntime.invalidateCellularPlatformFacts()
    }

    private companion object {
        const val PUBLIC_IP_OBSERVATION_TIMEOUT_MS = 15_000L
    }
}
