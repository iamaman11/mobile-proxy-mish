package com.mobileproxymish.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.mobileproxymish.ffi.MeshAdmissionState
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.MeshTransportBoundaryException
import com.mobileproxymish.ffi.MeshTransportController
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.meshIngressServingAllowed
import java.io.Closeable
import java.net.Inet4Address
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

/** Complete Android platform fact supplied to the Rust Transport Reachability owner. */
internal sealed interface AndroidMeshVpnObservation {
    data object Absent : AndroidMeshVpnObservation

    data class UniqueVpn(
        val localIpv4: List<String>,
    ) : AndroidMeshVpnObservation

    data object AmbiguousVpn : AndroidMeshVpnObservation
}

/**
 * Pure cardinality projection only. Android does not filter the configured Mesh CIDR, normalize
 * addresses or choose an endpoint; it reports the raw IPv4 facts of exactly one current VPN.
 */
internal fun classifyMeshVpnNetworks(
    currentVpnLocalIpv4: List<List<String>>,
): AndroidMeshVpnObservation = when (currentVpnLocalIpv4.size) {
    0 -> AndroidMeshVpnObservation.Absent
    1 -> AndroidMeshVpnObservation.UniqueVpn(currentVpnLocalIpv4.single().toList())
    else -> AndroidMeshVpnObservation.AmbiguousVpn
}

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
 * Android observation/composition adapter for the Rust Transport Reachability owner.
 *
 * Platform authority is current ConnectivityManager VPN Network cardinality plus each current
 * VPN's LinkProperties. Every callback schedules a fresh whole snapshot; callback deltas are never
 * admission truth. Rust consumes the raw unique-VPN IPv4 facts, applies the configured Mesh CIDR,
 * decides 0/1/>1 accepted addresses, owns admission epochs, owns cross-owner serving eligibility,
 * and owns exact-address listener/session teardown. Android never infers Mesh from package
 * presence, interface names, default routes or a global NetworkInterface scan.
 */
internal class MeshIngressRuntimeBridge(
    context: Context,
    private val proxyRuntime: ProxyRuntimeSupervisor,
) : Closeable {
    private val connectivityManager = context.applicationContext
        .getSystemService(ConnectivityManager::class.java)
        ?: throw IllegalStateException("ConnectivityManager is unavailable")
    private val controller: MeshTransportController?
    private val mutableSnapshot = MutableStateFlow<MeshAdmissionView?>(null)
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val callbackRegistered = AtomicBoolean(false)
    private val ingressLock = Any()
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-mesh-observer").apply { isDaemon = true }
    }
    private val proxyObservationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var proxyObservationJob: Job? = null
    private var readinessObservationJob: Job? = null
    private var egressReadiness: StateFlow<ProductReadinessState>? = null
    @Volatile
    private var lastIngressFailure = MeshIngressDiagnosticFailure.NONE
    private val vpnRequest = NetworkRequest.Builder()
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
        .build()

    private var sequence = 0L

    val snapshot: StateFlow<MeshAdmissionView?>
        get() = mutableSnapshot.asStateFlow()

    internal fun diagnosticIngressFailure(): MeshIngressDiagnosticFailure = lastIngressFailure

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = scheduleObservation()

        override fun onLost(network: Network) = scheduleObservation()

        override fun onLosing(network: Network, maxMsToLive: Int) = scheduleObservation()

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) = scheduleObservation()

        override fun onLinkPropertiesChanged(
            network: Network,
            linkProperties: LinkProperties,
        ) = scheduleObservation()
    }

    init {
        controller = try {
            MeshTransportController()
        } catch (_: LinkageError) {
            null
        } catch (_: Exception) {
            null
        }
        mutableSnapshot.value = controller?.let(::ownerSnapshotOrNull)
    }

    fun start() {
        check(!closed.get()) { "Mesh ingress runtime is closed" }
        check(controller != null) { "Mesh transport owner is unavailable" }
        if (!started.compareAndSet(false, true)) return

        try {
            connectivityManager.registerNetworkCallback(vpnRequest, networkCallback)
            callbackRegistered.set(true)
            // Proxy health is an input to ingress realization. Recompute the same complete current
            // VPN snapshot when proxy lifecycle changes so an endpoint observed during STARTING is
            // not stranded merely because no later ConnectivityManager callback arrives.
            proxyObservationJob = proxyRuntime.snapshot
                .onEach { scheduleObservation() }
                .launchIn(proxyObservationScope)
            egressReadiness?.let { readiness ->
                readinessObservationJob = readiness
                    .onEach { scheduleObservation() }
                    .launchIn(proxyObservationScope)
            }
            scheduleObservation()
        } catch (error: Exception) {
            started.set(false)
            proxyObservationJob?.cancel()
            proxyObservationJob = null
            readinessObservationJob?.cancel()
            readinessObservationJob = null
            if (callbackRegistered.compareAndSet(true, false)) {
                runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
            }
            stopIngressFailClosed(controller)
            throw IllegalStateException("Mesh VPN observer could not start", error)
        }
    }

    /**
     * Supplies the existing terminal readiness projection which gates public ingress serving.
     * The projection remains its Rust owner's truth: Transport only consumes it to decide whether
     * an already-admitted exact endpoint may accept clients. It is deliberately installed before
     * this bridge starts and cannot be replaced for a running generation.
     */
    fun requireEgressReadiness(readiness: StateFlow<ProductReadinessState>) {
        check(!started.get()) { "Mesh ingress readiness must be installed before start" }
        check(egressReadiness == null) { "Mesh ingress readiness is already installed" }
        egressReadiness = readiness
    }

    private fun scheduleObservation() {
        if (closed.get()) return
        try {
            executor.execute(::observeCurrentVpnSnapshot)
        } catch (_: RejectedExecutionException) {
            stopIngressFailClosed(controller)
        }
    }

    private fun observeCurrentVpnSnapshot() {
        val activeController = controller ?: return
        if (closed.get()) return
        if (sequence == Long.MAX_VALUE) {
            stopIngressFailClosed(activeController)
            return
        }
        sequence += 1

        val observation = try {
            currentVpnObservation()
        } catch (_: Exception) {
            // Platform snapshot uncertainty is fail-closed. Do not preserve a prior admitted
            // endpoint through an observation gap.
            AndroidMeshVpnObservation.AmbiguousVpn
        }

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

    private fun currentVpnObservation(): AndroidMeshVpnObservation {
        val currentVpns = mutableListOf<List<String>>()
        for (network in connectivityManager.allNetworks) {
            val capabilities = connectivityManager.getNetworkCapabilities(network)
                ?: return AndroidMeshVpnObservation.AmbiguousVpn
            if (!capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue

            val localIpv4 = connectivityManager.getLinkProperties(network)
                ?.linkAddresses
                ?.mapNotNull { linkAddress -> linkAddress.address as? Inet4Address }
                ?.mapNotNull { address -> address.hostAddress }
                .orEmpty()
            currentVpns += localIpv4
        }
        return classifyMeshVpnNetworks(currentVpns)
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
                if (!view.ingressRunning || !activeController.ingressHealthy()) {
                    if (!activeController.startIngress(requireNotNull(epoch))) {
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
        var clean = true
        if (callbackRegistered.compareAndSet(true, false)) {
            clean = runCatching {
                connectivityManager.unregisterNetworkCallback(networkCallback)
            }.isSuccess && clean
        }

        executor.shutdownNow()
        synchronized(ingressLock) {
            controller?.let { activeController ->
                clean = runCatching { activeController.stopIngress() }.isSuccess && clean
                mutableSnapshot.value = ownerSnapshotOrNull(activeController)
            } ?: run {
                mutableSnapshot.value = null
            }
        }

        clean = try {
            executor.awaitTermination(MESH_CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS) && clean
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        if (!clean) {
            throw IllegalStateException("Mesh ingress cleanup failed")
        }
    }

    private companion object {
        const val MESH_CLOSE_TIMEOUT_SECONDS = 6L
    }
}
