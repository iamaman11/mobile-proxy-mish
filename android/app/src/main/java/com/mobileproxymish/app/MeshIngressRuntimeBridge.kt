package com.mobileproxymish.app

import com.mobileproxymish.ffi.MeshAdmissionState
import com.mobileproxymish.ffi.MeshTransportController
import java.io.Closeable
import java.net.Inet4Address
import java.net.NetworkInterface
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android observation/composition adapter for the Rust Transport Reachability owner.
 *
 * This class does not choose a Mesh endpoint. It reports all locally assigned IPv4 addresses to
 * the Rust owner, which alone filters the deployment-approved Mesh CIDR, requires uniqueness,
 * creates admission epochs and owns exact-address listeners. The adapter also gates listener
 * start on the existing loopback proxy generation being healthy.
 */
internal class MeshIngressRuntimeBridge(
    private val proxyRuntime: ProxyRuntimeSupervisor,
) : Closeable {
    private val controller: MeshTransportController?
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val executor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-mesh-observer").apply { isDaemon = true }
    }

    private var sequence = 0L

    init {
        controller = try {
            MeshTransportController(
                DEPLOYMENT_ACCEPTED_MESH_NETWORK,
                DEPLOYMENT_ACCEPTED_MESH_PREFIX.toUByte(),
            )
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
            executor.execute(::monitorLoop)
        } catch (error: RejectedExecutionException) {
            started.set(false)
            throw IllegalStateException("Mesh observer could not start", error)
        }
    }

    private fun monitorLoop() {
        val activeController = controller ?: return
        while (!closed.get() && !Thread.currentThread().isInterrupted) {
            if (sequence == Long.MAX_VALUE) {
                runCatching { activeController.stopIngress() }
                return
            }
            sequence += 1

            val view = try {
                activeController.observeLocalIpv4(
                    sequence = sequence.toULong(),
                    localIpv4 = localIpv4Addresses(),
                )
            } catch (_: LinkageError) {
                runCatching { activeController.stopIngress() }
                return
            } catch (_: Exception) {
                // Observation/boundary uncertainty is fail-closed, but remains recoverable on the
                // next poll rather than requiring a process restart.
                runCatching { activeController.stopIngress() }
                sleepPoll()
                continue
            }

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
                return
            } catch (_: Exception) {
                runCatching { activeController.stopIngress() }
            }

            sleepPoll()
        }
        runCatching { activeController.stopIngress() }
    }

    private fun localIpv4Addresses(): List<String> {
        return try {
            val result = linkedSetOf<String>()
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return emptyList()
            while (interfaces.hasMoreElements()) {
                val networkInterface = interfaces.nextElement()
                val addresses = networkInterface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement()
                    if (address is Inet4Address) {
                        address.hostAddress?.let(result::add)
                    }
                }
            }
            result.toList()
        } catch (_: Exception) {
            // Empty observation revokes admission in the Rust owner and therefore closes ingress.
            emptyList()
        }
    }

    private fun sleepPoll() {
        try {
            Thread.sleep(MESH_OBSERVATION_POLL_MS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        executor.shutdownNow()

        var clean = true
        val activeController = controller
        if (activeController != null) {
            clean = try {
                activeController.stopIngress()
            } catch (_: Exception) {
                false
            } && clean
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
        // Account/device contract physically re-verified before Stage C implementation. This is
        // an admission range only; the Rust owner still binds one exact currently observed IP.
        const val DEPLOYMENT_ACCEPTED_MESH_NETWORK = "100.96.0.0"
        const val DEPLOYMENT_ACCEPTED_MESH_PREFIX = 12
        const val MESH_OBSERVATION_POLL_MS = 250L
        const val MESH_CLOSE_TIMEOUT_SECONDS = 6L
    }
}
