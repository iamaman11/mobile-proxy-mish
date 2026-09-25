package com.mobileproxymish.app.cellular

import android.content.Context
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.CellularAdmissionView
import com.mobileproxymish.ffi.CellularNetworkObservationInput
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
    private val observer = CellularNetworkObserver(context, this)
    private val radioPowerObserver = CellularRadioPowerObserver(context) {
        // A callback outside a live Rotation is intentionally a no-op in Rust.
        runCatching { productRuntime.observeRadioPowerOff() }
    }
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

    /** Android framework effect only; Rust owns if/when a rotation requests this once. */
    internal fun rearmNetworkRequest(): Boolean {
        if (closed.get() || !started.get()) return false
        return runCatching {
            observer.rearm()
            true
        }.getOrDefault(false)
    }

    fun start() {
        if (closed.get() || !started.compareAndSet(false, true)) return

        try {
            observer.start()
            radioPowerObserver.start()
            if (closed.get()) {
                radioPowerObserver.close()
                observer.close()
            }
        } catch (error: LinkageError) {
            started.set(false)
            cleanupPlatformObservation()
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.NativeLibraryUnavailable,
            )
            throw error
        } catch (error: Exception) {
            started.set(false)
            cleanupPlatformObservation()
            mutableSnapshot.value = CellularRuntimeSnapshot.BoundaryUnavailable(
                CellularBoundaryFailure.ForeignCallFailed,
            )
            throw IllegalStateException("Cellular platform observer could not start", error)
        }
    }

    fun stop() {
        if (closed.get() || !started.compareAndSet(true, false)) return
        if (!cleanupPlatformObservation()) {
            throw IllegalStateException("Cellular platform observation cleanup failed")
        }
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
                        CellularNetworkObservationInput(
                            sequence = event.sequence.toULong(),
                            networkHandle = event.networkHandle.toULong(),
                            isCellular = event.isCellular,
                            hasInternet = event.hasInternet,
                            isValidated = event.isValidated,
                            isNotVpn = event.isNotVpn,
                            interfaceName = exactInterface,
                        ),
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
        if (!cleanupPlatformObservation()) {
            throw IllegalStateException("Cellular platform observation cleanup failed")
        }
    }

    /**
     * Android owns observer registration mechanics only. Native platform facts are invalidated
     * whenever this observation session ends, including partial start failure after a network
     * callback may already have reached Rust.
     */
    private fun cleanupPlatformObservation(): Boolean {
        var clean = runCatching(radioPowerObserver::close).isSuccess
        clean = runCatching(observer::close).isSuccess && clean
        clean = runCatching { productRuntime.invalidateCellularPlatformFacts() }.isSuccess && clean
        return clean
    }

    private companion object {
        const val PUBLIC_IP_OBSERVATION_TIMEOUT_MS = 15_000L
    }
}
