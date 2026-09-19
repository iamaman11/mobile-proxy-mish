package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.MeshTransportBoundaryException
import com.mobileproxymish.ffi.NativeProductRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

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
 * Android owns only complete current-VPN observation and a presentation projection of the native
 * Mesh snapshot. Rust owns admission/epoch/capacity and combines Proxy + Readiness + Mesh owner
 * facts into ingress start/stop. No readiness or serving decision is relayed through Kotlin.
 */
internal class MeshIngressRuntimeBridge(
    context: Context,
    private val productRuntime: NativeProductRuntime,
) : Closeable {
    private val mutableSnapshot = MutableStateFlow(ownerSnapshotOrNull())
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val vpnObserver = AndroidVpnObserver(
        context = context,
        onObservation = ::onVpnObservation,
        onObservationUnavailable = ::onVpnObservationUnavailable,
    )
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
            vpnObserver.start()
        } catch (error: Exception) {
            started.set(false)
            failClosed()
            throw IllegalStateException("Mesh platform adapter could not start", error)
        }
    }

    fun stop() {
        if (closed.get() || !started.compareAndSet(true, false)) return
        var clean = runCatching(vpnObserver::stop).isSuccess
        clean = runCatching { productRuntime.invalidateMeshPlatformFact() }.isSuccess && clean
        if (!clean) {
            throw IllegalStateException("Mesh platform observation cleanup failed")
        }
    }

    private fun onVpnObservation(observation: AndroidMeshVpnObservation) {
        if (closed.get() || !started.get()) return
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

    private fun failClosed() {
        if (closed.get() || !started.get() || sequence == Long.MAX_VALUE) return
        sequence += 1
        runCatching {
            mutableSnapshot.value = productRuntime.observeMeshVpnAmbiguous(sequence.toULong())
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
        started.set(false)
        var clean = runCatching(vpnObserver::close).isSuccess
        clean = runCatching { productRuntime.invalidateMeshPlatformFact() }.isSuccess && clean
        if (!clean) {
            throw IllegalStateException("Mesh platform observation cleanup failed")
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
