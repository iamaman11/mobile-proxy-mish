package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.ffi.MeshAdmissionState
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.MeshTransportBoundaryException
import com.mobileproxymish.ffi.MeshTransportController
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.meshIngressServingAllowed
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

/**
 * Thin Android composition adapter for the Rust Transport Reachability owner.
 *
 * `AndroidVpnObserver` owns current ConnectivityManager observation only. Rust consumes its raw VPN
 * IPv4 facts, applies configured Mesh CIDR/cardinality policy, owns admission epochs and decides
 * cross-owner serving eligibility. This adapter sequences observations and realizes the exact
 * ingress start/stop effect; it owns no parallel Mesh admission or readiness state machine.
 */
internal class MeshIngressRuntimeBridge(
    context: Context,
    private val proxyRuntime: ProxyRuntimeSupervisor,
) : Closeable {
    private val controller: MeshTransportController? = try {
        MeshTransportController()
    } catch (_: LinkageError) {
        null
    } catch (_: Exception) {
        null
    }
    private val mutableSnapshot = MutableStateFlow(controller?.let(::ownerSnapshotOrNull))
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val ingressLock = Any()
    private val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val vpnObserver = AndroidVpnObserver(
        context = context,
        onObservation = ::onVpnObservation,
        onObservationUnavailable = ::onVpnObservationUnavailable,
    )
    private var proxyObservationJob: Job? = null
    private var readinessObservationJob: Job? = null
    private var egressReadiness: StateFlow<ProductReadinessState>? = null
    @Volatile
    private var lastIngressFailure = MeshIngressDiagnosticFailure.NONE
    private var sequence = 0L

    val snapshot: StateFlow<MeshAdmissionView?>
        get() = mutableSnapshot.asStateFlow()

    internal fun diagnosticIngressFailure(): MeshIngressDiagnosticFailure = lastIngressFailure

    /** Read the live session count from the Rust Transport owner; Android keeps no parallel counter. */
    internal fun diagnosticActiveSessions(): ULong? {
        val activeController = controller ?: return null
        return try {
            activeController.admissionSnapshot().activeSessions
        } catch (_: LinkageError) {
            null
        } catch (_: Exception) {
            null
        }
    }

    fun start() {
        check(!closed.get()) { "Mesh ingress runtime is closed" }
        check(controller != null) { "Mesh transport owner is unavailable" }
        if (!started.compareAndSet(false, true)) return

        try {
            proxyObservationJob = proxyRuntime.snapshot
                .onEach { vpnObserver.refresh() }
                .launchIn(observationScope)
            egressReadiness?.let { readiness ->
                readinessObservationJob = readiness
                    .onEach { vpnObserver.refresh() }
                    .launchIn(observationScope)
            }
            vpnObserver.start()
        } catch (error: Exception) {
            started.set(false)
            proxyObservationJob?.cancel()
            proxyObservationJob = null
            readinessObservationJob?.cancel()
            readinessObservationJob = null
            stopIngressFailClosed(controller)
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
        val activeController = controller ?: return
        if (closed.get()) return
        if (sequence == Long.MAX_VALUE) {
            stopIngressFailClosed(activeController)
            return
        }
        sequence += 1

        val view = try {
            when (observation) {
                AndroidMeshVpnObservation.Absent ->
                    activeController.observeVpnAbsent(sequence.toULong())

                is AndroidMeshVpnObservation.UniqueVpn ->
                    activeController.observeUniqueVpn(
                        sequence = sequence.toULong(),
                        localIpv4 = observation.localIpv4,
                    )

                AndroidMeshVpnObservation.AmbiguousVpn ->
                    activeController.observeVpnAmbiguous(sequence.toULong())
            }
        } catch (_: LinkageError) {
            stopIngressFailClosed(activeController)
            return
        } catch (_: Exception) {
            stopIngressFailClosed(activeController)
            return
        }

        reconcileIngress(activeController, view)
    }

    private fun onVpnObservationUnavailable() {
        stopIngressFailClosed(controller)
    }

    private fun reconcileIngress(
        activeController: MeshTransportController,
        view: MeshAdmissionView,
    ) = synchronized(ingressLock) {
        if (closed.get()) {
            runCatching { activeController.stopIngress() }
            mutableSnapshot.value = ownerSnapshotOrNull(activeController)
            return@synchronized
        }

        try {
            val epoch = view.admissionEpoch
            if (meshIngressServingAllowed(
                    proxyRunning = proxyRuntime.snapshot.value == ProxyRuntimeSnapshot.Running,
                    readiness = egressReadiness?.value ?: ProductReadinessState.UNKNOWN,
                    meshAdmitted = view.state == MeshAdmissionState.ADMITTED,
                    admissionEpochPresent = epoch != null,
                )
            ) {
                val processRuntime = proxyRuntime.currentNativeRuntimeHandle()
                if (processRuntime == null) {
                    lastIngressFailure = MeshIngressDiagnosticFailure.UNAVAILABLE
                    activeController.stopIngress()
                } else if (!view.ingressRunning || !activeController.ingressHealthy()) {
                    if (!activeController.startIngress(requireNotNull(epoch), processRuntime)) {
                        lastIngressFailure = MeshIngressDiagnosticFailure.START_REJECTED
                        activeController.stopIngress()
                    } else {
                        lastIngressFailure = MeshIngressDiagnosticFailure.NONE
                    }
                }
            } else {
                activeController.stopIngress()
                lastIngressFailure = MeshIngressDiagnosticFailure.NONE
            }
        } catch (_: LinkageError) {
            lastIngressFailure = MeshIngressDiagnosticFailure.OWNER_UNAVAILABLE
            runCatching { activeController.stopIngress() }
        } catch (error: MeshTransportBoundaryException) {
            lastIngressFailure = when (error) {
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
            runCatching { activeController.stopIngress() }
        } catch (_: Exception) {
            lastIngressFailure = MeshIngressDiagnosticFailure.OTHER
            runCatching { activeController.stopIngress() }
        }
        mutableSnapshot.value = ownerSnapshotOrNull(activeController)
    }

    private fun stopIngressFailClosed(activeController: MeshTransportController?) {
        if (activeController == null) {
            mutableSnapshot.value = null
            return
        }
        synchronized(ingressLock) {
            runCatching { activeController.stopIngress() }
            mutableSnapshot.value = ownerSnapshotOrNull(activeController)
        }
    }

    private fun ownerSnapshotOrNull(activeController: MeshTransportController): MeshAdmissionView? =
        try {
            activeController.admissionSnapshot()
        } catch (_: LinkageError) {
            null
        } catch (_: Exception) {
            null
        }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        proxyObservationJob?.cancel()
        proxyObservationJob = null
        readinessObservationJob?.cancel()
        readinessObservationJob = null
        observationScope.cancel()

        var clean = runCatching(vpnObserver::close).isSuccess
        synchronized(ingressLock) {
            controller?.let { activeController ->
                clean = runCatching { activeController.stopIngress() }.isSuccess && clean
                mutableSnapshot.value = ownerSnapshotOrNull(activeController)
            } ?: run {
                mutableSnapshot.value = null
            }
        }
        if (!clean) {
            throw IllegalStateException("Mesh ingress cleanup failed")
        }
    }
}
