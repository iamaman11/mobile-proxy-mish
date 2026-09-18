package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.MeshTransportBoundaryException
import com.mobileproxymish.ffi.NativeProductRuntime
import com.mobileproxymish.ffi.ProductReadinessState
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

/** Safe, endpoint-free diagnostic classification of the last ingress realization attempt. */
internal enum class MeshIngressDiagnosticFailure {
    NONE,
    START_REJECTED,
    BIND_FAILED,
    UNAVAILABLE,
    SHUTDOWN_FAILED,
    OWNER_UNAVAILABLE,
    OTHER,
}

internal data class MeshSessionDiagnosticObservation(
    val activeSessions: ULong,
    val capacityRejects: ULong,
)

/**
 * Android observation/projection adapter for Rust-owned Mesh composition.
 *
 * Android owns only complete current-VPN observation. Rust owns Mesh admission/epoch/capacity and
 * combines current Proxy + Readiness + Mesh owner facts into ingress start/stop. Until readiness
 * scheduling moves native in the next U5 slice, this adapter forwards only the terminal Rust-owned
 * readiness projection; it never evaluates the serving predicate itself.
 */
internal class MeshIngressRuntimeBridge(
    context: Context,
    private val productRuntime: NativeProductRuntime,
) : Closeable {
    private val mutableSnapshot = MutableStateFlow(ownerSnapshotOrNull())
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val vpnObserver = AndroidVpnObserver(
        context = context,
        onObservation = ::onVpnObservation,
        onObservationUnavailable = ::onVpnObservationUnavailable,
    )
    private var readinessObservationJob: Job? = null
    private var egressReadiness: StateFlow<ProductReadinessState>? = null
    @Volatile
    private var lastIngressFailure = MeshIngressDiagnosticFailure.NONE
    private var sequence = 0L

    val snapshot: StateFlow<MeshAdmissionView?>
        get() = mutableSnapshot.asStateFlow()

    internal fun diagnosticIngressFailure(): MeshIngressDiagnosticFailure = lastIngressFailure

    /** Read one live capacity observation from Rust; Android keeps no parallel counters. */
    internal fun diagnosticSessionObservation(): MeshSessionDiagnosticObservation? =
        ownerSnapshotOrNull()?.let { owner ->
            MeshSessionDiagnosticObservation(
                activeSessions = owner.activeSessions,
                capacityRejects = owner.capacityRejects,
            )
        }

    fun start() {
        check(!closed.get()) { "Mesh ingress runtime is closed" }
        if (!started.compareAndSet(false, true)) return

        try {
            val readiness = egressReadiness
            applyReadiness(readiness?.value ?: ProductReadinessState.UNKNOWN)
            if (readiness != null) {
                readinessObservationJob = readiness
                    .onEach(::applyReadiness)
                    .launchIn(observationScope)
            }
            vpnObserver.start()
        } catch (error: Exception) {
            started.set(false)
            readinessObservationJob?.cancel()
            readinessObservationJob = null
            failClosed()
            throw IllegalStateException("Mesh platform adapter could not start", error)
        }
    }

    /** Installs the existing terminal readiness projection before this generation starts. */
    fun requireEgressReadiness(readiness: StateFlow<ProductReadinessState>) {
        check(!started.get()) { "Mesh ingress readiness must be installed before start" }
        check(egressReadiness == null) { "Mesh ingress readiness is already installed" }
        egressReadiness = readiness
    }

    private fun onVpnObservation(observation: AndroidMeshVpnObservation) {
        if (closed.get()) return
        if (sequence == Long.MAX_VALUE) {
            failClosed()
            return
        }
        sequence += 1

        try {
            mutableSnapshot.value = when (observation) {
                AndroidMeshVpnObservation.Absent ->
                    productRuntime.observeMeshVpnAbsent(sequence.toULong())

                is AndroidMeshVpnObservation.UniqueVpn ->
                    productRuntime.observeMeshUniqueVpn(
                        sequence = sequence.toULong(),
                        localIpv4 = observation.localIpv4,
                    )

                AndroidMeshVpnObservation.AmbiguousVpn ->
                    productRuntime.observeMeshVpnAmbiguous(sequence.toULong())
            }
            lastIngressFailure = MeshIngressDiagnosticFailure.NONE
        } catch (error: MeshTransportBoundaryException) {
            lastIngressFailure = classifyBoundaryFailure(error)
            failClosed()
        } catch (_: LinkageError) {
            lastIngressFailure = MeshIngressDiagnosticFailure.OWNER_UNAVAILABLE
            failClosed()
        } catch (_: Exception) {
            lastIngressFailure = MeshIngressDiagnosticFailure.OTHER
            failClosed()
        }
    }

    private fun onVpnObservationUnavailable() {
        // A missing complete Android snapshot is itself an ambiguous current-VPN observation.
        onVpnObservation(AndroidMeshVpnObservation.AmbiguousVpn)
    }

    private fun applyReadiness(readiness: ProductReadinessState) {
        if (closed.get()) return
        try {
            mutableSnapshot.value =
                productRuntime.setMeshReadinessReady(readiness == ProductReadinessState.READY)
            lastIngressFailure = MeshIngressDiagnosticFailure.NONE
        } catch (error: MeshTransportBoundaryException) {
            lastIngressFailure = classifyBoundaryFailure(error)
            failClosed()
        } catch (_: LinkageError) {
            lastIngressFailure = MeshIngressDiagnosticFailure.OWNER_UNAVAILABLE
            failClosed()
        } catch (_: Exception) {
            lastIngressFailure = MeshIngressDiagnosticFailure.OTHER
            failClosed()
        }
    }

    private fun failClosed() {
        runCatching {
            mutableSnapshot.value = productRuntime.setMeshReadinessReady(false)
        }
    }

    private fun ownerSnapshotOrNull(): MeshAdmissionView? = try {
        productRuntime.meshAdmissionSnapshot()
    } catch (_: LinkageError) {
        null
    } catch (_: Exception) {
        null
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        readinessObservationJob?.cancel()
        readinessObservationJob = null
        observationScope.cancel()

        var clean = runCatching(vpnObserver::close).isSuccess
        clean = runCatching {
            mutableSnapshot.value = productRuntime.setMeshReadinessReady(false)
        }.isSuccess && clean

        if (!clean) {
            throw IllegalStateException("Mesh ingress cleanup failed")
        }
    }
}

private fun classifyBoundaryFailure(
    error: MeshTransportBoundaryException,
): MeshIngressDiagnosticFailure = when (error) {
    is MeshTransportBoundaryException.IngressBindFailed ->
        MeshIngressDiagnosticFailure.BIND_FAILED
    is MeshTransportBoundaryException.IngressShutdownFailed ->
        MeshIngressDiagnosticFailure.SHUTDOWN_FAILED
    is MeshTransportBoundaryException.IngressUnavailable ->
        MeshIngressDiagnosticFailure.UNAVAILABLE
    is MeshTransportBoundaryException.OwnerUnavailable ->
        MeshIngressDiagnosticFailure.OWNER_UNAVAILABLE
    else -> MeshIngressDiagnosticFailure.OTHER
}
