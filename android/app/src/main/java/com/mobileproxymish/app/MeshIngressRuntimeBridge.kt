package com.mobileproxymish.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import com.mobileproxymish.ffi.MeshAdmissionState
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.MeshTransportController
import java.io.Closeable
import java.net.Inet4Address
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

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

/**
 * Android observation/composition adapter for the Rust Transport Reachability owner.
 *
 * Platform authority is current ConnectivityManager VPN Network cardinality plus each current
 * VPN's LinkProperties. Every callback schedules a fresh whole snapshot; callback deltas are never
 * admission truth. Rust consumes the raw unique-VPN IPv4 facts, applies the configured Mesh CIDR,
 * decides 0/1/>1 accepted addresses, owns admission epochs and owns exact-address listener/session
 * teardown. Android never infers Mesh from package presence, interface names, default routes or a
 * global NetworkInterface scan.
 */
internal class MeshIngressRuntimeBridge(
    context: Context,
    private val proxyRuntime: ProxyRuntimeSupervisor,
) : Closeable {
    private val connectivityManager = context.applicationContext
        .getSystemService(ConnectivityManager::class.java)
        ?: throw IllegalStateException("ConnectivityManager is unavailable")
    private val controller: MeshTransportController?
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val callbackRegistered = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-mesh-observer").apply { isDaemon = true }
    }
    private val vpnRequest = NetworkRequest.Builder()
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
        .build()

    private var sequence = 0L

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
    }

    fun start() {
        check(!closed.get()) { "Mesh ingress runtime is closed" }
        check(controller != null) { "Mesh transport owner is unavailable" }
        if (!started.compareAndSet(false, true)) return

        try {
            connectivityManager.registerNetworkCallback(vpnRequest, networkCallback)
            callbackRegistered.set(true)
            scheduleObservation()
        } catch (error: Exception) {
            started.set(false)
            if (callbackRegistered.compareAndSet(true, false)) {
                runCatching { connectivityManager.unregisterNetworkCallback(networkCallback) }
            }
            runCatching { controller.stopIngress() }
            throw IllegalStateException("Mesh VPN observer could not start", error)
        }
    }

    private fun scheduleObservation() {
        if (closed.get()) return
        try {
            executor.execute(::observeCurrentVpnSnapshot)
        } catch (_: RejectedExecutionException) {
            runCatching { controller?.stopIngress() }
        }
    }

    private fun observeCurrentVpnSnapshot() {
        val activeController = controller ?: return
        if (closed.get()) return
        if (sequence == Long.MAX_VALUE) {
            runCatching { activeController.stopIngress() }
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
            runCatching { activeController.stopIngress() }
            return
        } catch (_: Exception) {
            runCatching { activeController.stopIngress() }
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
    ) {
        try {
            val proxyReady = proxyRuntime.snapshot.value == ProxyRuntimeSnapshot.Running
            val epoch = view.admissionEpoch
            if (proxyReady && view.state == MeshAdmissionState.ADMITTED && epoch != null) {
                if (!view.ingressRunning || !activeController.ingressHealthy()) {
                    if (!activeController.startIngress(epoch)) {
                        activeController.stopIngress()
                    }
                }
            } else {
                activeController.stopIngress()
            }
        } catch (_: LinkageError) {
            runCatching { activeController.stopIngress() }
        } catch (_: Exception) {
            runCatching { activeController.stopIngress() }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        var clean = true
        if (callbackRegistered.compareAndSet(true, false)) {
            clean = runCatching {
                connectivityManager.unregisterNetworkCallback(networkCallback)
            }.isSuccess && clean
        }

        executor.shutdownNow()
        controller?.let { activeController ->
            clean = runCatching { activeController.stopIngress() }.isSuccess && clean
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
