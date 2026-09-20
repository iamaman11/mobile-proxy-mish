package com.mobileproxymish.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
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

/** Pure cardinality projection. CIDR filtering and endpoint choice remain in Rust Transport. */
internal fun classifyMeshVpnNetworks(
    currentVpnLocalIpv4: List<List<String>>,
): AndroidMeshVpnObservation = when (currentVpnLocalIpv4.size) {
    0 -> AndroidMeshVpnObservation.Absent
    1 -> AndroidMeshVpnObservation.UniqueVpn(currentVpnLocalIpv4.single().toList())
    else -> AndroidMeshVpnObservation.AmbiguousVpn
}

/**
 * Android-only current-VPN observer.
 *
 * Callback deltas are never admission truth. Every platform callback schedules one fresh complete
 * ConnectivityManager snapshot, then reports only raw current VPN IPv4 facts to its consumer.
 */
internal class AndroidVpnObserver(
    context: Context,
    private val onObservation: (AndroidMeshVpnObservation) -> Unit,
    private val onObservationUnavailable: () -> Unit,
) : Closeable {
    private val connectivityManager = context
        .getSystemService(ConnectivityManager::class.java)
        ?: throw IllegalStateException("ConnectivityManager is unavailable")
    private val closed = AtomicBoolean(false)
    private val registered = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-mesh-vpn-observer").apply { isDaemon = true }
    }
    private val vpnRequest = NetworkRequest.Builder()
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_TRUSTED)
        .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        .addTransportType(NetworkCapabilities.TRANSPORT_VPN)
        .build()

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = scheduleSnapshot()

        override fun onLost(network: Network) = scheduleSnapshot()

        override fun onLosing(network: Network, maxMsToLive: Int) = scheduleSnapshot()

        override fun onCapabilitiesChanged(
            network: Network,
            networkCapabilities: NetworkCapabilities,
        ) = scheduleSnapshot()

        override fun onLinkPropertiesChanged(
            network: Network,
            linkProperties: LinkProperties,
        ) = scheduleSnapshot()
    }

    fun start() {
        check(!closed.get()) { "Android VPN observer is closed" }
        if (!registered.compareAndSet(false, true)) return
        try {
            connectivityManager.registerNetworkCallback(vpnRequest, networkCallback)
            scheduleSnapshot()
        } catch (error: Exception) {
            registered.set(false)
            throw IllegalStateException("Mesh VPN observer could not start", error)
        }
    }

    fun refresh() = scheduleSnapshot()

    private fun scheduleSnapshot() {
        if (closed.get()) return
        try {
            executor.execute {
                if (closed.get()) return@execute
                val observation = try {
                    currentVpnObservation()
                } catch (_: Exception) {
                    AndroidMeshVpnObservation.AmbiguousVpn
                }
                onObservation(observation)
            }
        } catch (_: RejectedExecutionException) {
            if (!closed.get()) onObservationUnavailable()
        }
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

    @Synchronized
    fun stop() {
        if (closed.get() || !registered.compareAndSet(true, false)) return
        connectivityManager.unregisterNetworkCallback(networkCallback)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        var clean = runCatching {
            if (registered.compareAndSet(true, false)) {
                connectivityManager.unregisterNetworkCallback(networkCallback)
            }
        }.isSuccess
        executor.shutdownNow()
        clean = try {
            executor.awaitTermination(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS) && clean
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        check(clean) { "Android VPN observer cleanup failed" }
    }

    private companion object {
        const val CLOSE_TIMEOUT_SECONDS = 6L
    }
}
