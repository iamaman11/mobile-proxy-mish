package com.mobileproxymish.app.cellular

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import java.io.Closeable
import java.util.concurrent.atomic.AtomicLong

/**
 * Thin Android adapter that observes cellular Network lifecycle/capabilities.
 *
 * It deliberately does not decide readiness. All policy remains in the Rust Cellular
 * Egress natural owner. The request itself is cellular-only, and every callback still
 * carries explicit capability bits for defense-in-depth validation by the owner.
 */
class CellularNetworkObserver(
    context: Context,
    private val sink: CellularObservationSink,
) : Closeable {
    private val connectivityManager = context.getSystemService(ConnectivityManager::class.java)
    private val sequence = AtomicLong(0)

    private val request = NetworkRequest.Builder()
        .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
        .build()

    private val callback = object : ConnectivityManager.NetworkCallback() {
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
            sink.onEvent(
                CellularNetworkEvent.Observed(
                    sequence = nextSequence(),
                    networkHandle = network.networkHandle,
                    isCellular = capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR),
                    hasInternet = capabilities.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_INTERNET,
                    ),
                    isValidated = capabilities.hasCapability(
                        NetworkCapabilities.NET_CAPABILITY_VALIDATED,
                    ),
                ),
            )
        }

        override fun onLost(network: Network) {
            sink.onEvent(
                CellularNetworkEvent.Lost(
                    sequence = nextSequence(),
                    networkHandle = network.networkHandle,
                ),
            )
        }
    }

    @Volatile
    private var registered = false

    @Synchronized
    fun start() {
        if (registered) {
            return
        }

        connectivityManager.registerNetworkCallback(request, callback)
        registered = true
    }

    @Synchronized
    override fun close() {
        if (!registered) {
            return
        }

        connectivityManager.unregisterNetworkCallback(callback)
        registered = false
    }

    private fun nextSequence(): Long = sequence.incrementAndGet()
}
