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

    @Synchronized
    override fun close() {
        if (!requested) {
            return
        }

        connectivityManager.unregisterNetworkCallback(callback)
        requested = false
    }

    private fun emitObserved(
        network: Network,
        capabilities: NetworkCapabilities,
        linkProperties: LinkProperties?,
    ) {
        synchronized(eventLock) {
            // Sequence allocation and sink submission are one atomic ordering boundary.
            // If Android invokes callbacks concurrently, executor enqueue order therefore
            // cannot invert owner sequence order and make a stale interface hint current.
            sink.onEvent(
                CellularNetworkEvent.Observed(
                    sequence = sequence.incrementAndGet(),
                    networkHandle = network.networkHandle,
                    isCellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
                    hasInternet = capabilities.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_INTERNET,
                    ),
                    isValidated = capabilities.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_VALIDATED,
                    ),
                    isNotVpn = capabilities.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_NOT_VPN,
                    ),
                    interfaceName = linkProperties?.interfaceName,
                ),
            )
        }
    }

    private fun emitLost(network: Network) {
        synchronized(eventLock) {
            sink.onEvent(
                CellularNetworkEvent.Lost(
                    sequence = sequence.incrementAndGet(),
                    networkHandle = network.networkHandle,
                ),
            )
        }
    }
}
