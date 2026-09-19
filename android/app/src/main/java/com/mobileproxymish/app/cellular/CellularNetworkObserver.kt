package com.mobileproxymish.app.cellular

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.io.Closeable
import java.util.concurrent.atomic.AtomicLong

/**
 * Thin Android adapter that acquires and observes the direct cellular Network lifetime.
 *
 * It deliberately does not decide readiness. The request constrains the platform-side
 * acquisition to a non-VPN cellular Internet network; fresh capability bits are still
 * forwarded to the Rust Cellular Egress natural owner for admission. A transient Linux
 * interface hint is forwarded only so the root-policy adapter can realize an already
 * owner-admitted decision; it is never a second admission source.
 */
class CellularNetworkObserver(
    context: Context,
    private val sink: CellularObservationSink,
) : Closeable {
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)
    private val sequence = AtomicLong(0)
    private val eventLock = Any()
    private var lastObserved: ObservedFact? = null

    private val request = NetworkRequest.Builder()
        .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        .build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return
            emitObserved(network, capabilities, connectivityManager.getLinkProperties(network))
        }

        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            emitObserved(network, capabilities, connectivityManager.getLinkProperties(network))
        }

        override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
            val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return
            emitObserved(network, capabilities, linkProperties)
        }

        override fun onLost(network: Network) {
            emitLost(network)
        }
    }

    @Volatile
    private var requested = false

    @Synchronized
    fun start() {
        if (requested) {
            return
        }

        // requestNetwork is intentional: unlike registerNetworkCallback, this asks
        // Android to bring up/retain a matching background cellular Network. DEVICE-1
        // proved that merely re-enabling mobile data does not recreate that Network on
        // the fixed Samsung while another network/VPN remains active.
        connectivityManager.requestNetwork(request, callback)
        requested = true
    }

    /**
     * Read-only infrastructure fallback for the exact owner-selected Network handle.
     *
     * Android can transiently deliver a capability callback while a synchronous
     * getLinkProperties() observation still returns null. That must not turn a valid
     * owner-admitted Network into a permanently unresolved interface hint. This lookup
     * does not choose a network: it resolves LinkProperties only for the exact handle
     * already selected by the Rust owner.
     */
    internal fun interfaceNameFor(networkHandle: ULong): String? =
        connectivityManager.allNetworks
            .firstOrNull { network -> network.networkHandle.toULong() == networkHandle }
            ?.let(connectivityManager::getLinkProperties)
            ?.interfaceName

    /**
     * One bounded framework effect requested by the Rust rotation owner after airplane OFF.
     *
     * DEVICE-1 (Samsung/API 30) can retain a pending requestNetwork registration across the
     * airplane cycle without re-activating a general INTERNET PDP. Re-registering the exact same
     * request repairs that platform liveness defect. This method owns no retry, timing, admission,
     * readiness, or recovery policy.
     */
    @Synchronized
    fun rearm() {
        check(requested) { "Cellular request is not registered" }

        connectivityManager.unregisterNetworkCallback(callback)
        synchronized(eventLock) {
            lastObserved = null
        }
        requested = false

        connectivityManager.requestNetwork(request, callback)
        requested = true
    }

    @Synchronized
    override fun close() {
        if (!requested) {
            return
        }

        connectivityManager.unregisterNetworkCallback(callback)
        synchronized(eventLock) {
            // A later registration represents a fresh platform-observation session. The next
            // identical Android snapshot must be emitted again for the current native generation.
            lastObserved = null
        }
        requested = false
    }

    private fun emitObserved(
        network: Network,
        capabilities: NetworkCapabilities,
        linkProperties: LinkProperties?,
    ) {
        synchronized(eventLock) {
            val fact = ObservedFact(
                networkHandle = network.networkHandle,
                isCellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
                hasInternet = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET),
                isValidated = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                isNotVpn = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN),
                interfaceName = linkProperties?.interfaceName,
            )
            // Repeated identical Android snapshots carry no new cellular admission fact. If
            // emitted they can supersede a still-valid reconciliation generation, so collapse
            // only exact duplicates; semantic changes and every loss remain ordered.
            if (fact == lastObserved) return
            lastObserved = fact
            // Sequence allocation and sink submission are one atomic ordering boundary.
            // If Android invokes callbacks concurrently, executor enqueue order therefore
            // cannot invert owner sequence order and make a stale interface hint current.
            sink.onEvent(
                CellularNetworkEvent.Observed(
                    sequence = sequence.incrementAndGet(),
                    networkHandle = fact.networkHandle,
                    isCellular = fact.isCellular,
                    hasInternet = fact.hasInternet,
                    isValidated = fact.isValidated,
                    isNotVpn = fact.isNotVpn,
                    interfaceName = fact.interfaceName,
                ),
            )
        }
    }

    private fun emitLost(network: Network) {
        synchronized(eventLock) {
            if (lastObserved?.networkHandle == network.networkHandle) {
                lastObserved = null
            }
            sink.onEvent(
                CellularNetworkEvent.Lost(
                    sequence = sequence.incrementAndGet(),
                    networkHandle = network.networkHandle,
                ),
            )
        }
    }

    private data class ObservedFact(
        val networkHandle: Long,
        val isCellular: Boolean,
        val hasInternet: Boolean,
        val isValidated: Boolean,
        val isNotVpn: Boolean,
        val interfaceName: String?,
    )
}
