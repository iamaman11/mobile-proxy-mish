package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.ffi.MeshTransportBoundaryException
import com.mobileproxymish.ffi.NativeProductRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Android observation/projection adapter for Rust-owned Mesh composition.
 *
 * Android owns only complete current-VPN observation. Rust owns admission/epoch/capacity and
 * the current presentation projection, and combines Proxy + Readiness + Mesh owner
 * facts into ingress start/stop. No readiness or serving decision is relayed through Kotlin.
 */
internal class MeshIngressRuntimeBridge(
    context: Context,
    private val productRuntime: NativeProductRuntime,
) : Closeable {
    private val started = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val vpnObserver = AndroidVpnObserver(
        context = context,
        onObservation = ::onVpnObservation,
        onObservationUnavailable = ::onVpnObservationUnavailable,
    )
    private var sequence = 0L

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
            when (observation) {
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
        } catch (error: MeshTransportBoundaryException) {
            failClosed()
        } catch (_: LinkageError) {
            failClosed()
        } catch (_: Exception) {
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
            productRuntime.observeMeshVpnAmbiguous(sequence.toULong())
        }
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
