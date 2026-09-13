package com.mobileproxymish.app

import android.util.Base64
import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.EgressProbeObservationView
import com.mobileproxymish.ffi.EgressProbeOutcome
import com.mobileproxymish.ffi.MeshAdmissionState
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.ProbeBindingView
import com.mobileproxymish.ffi.ProbeTicketView
import com.mobileproxymish.ffi.ProductReadinessController
import com.mobileproxymish.ffi.ProductReadinessFactsView
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.ReadinessProbeTargetView
import com.mobileproxymish.ffi.egressProbeBudgetMs
import com.mobileproxymish.ffi.proxyHttpConnectPort
import com.mobileproxymish.ffi.readinessProbeTarget
import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.IOException
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLException
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

/**
 * Android effect/composition adapter for the Rust D2 readiness/application contracts.
 *
 * This object owns no readiness truth and caches no leaf owner state. Structural observations are
 * read from their existing owner projections, Rust invalidates/issues one freshness ticket, and the
 * only mutable UI value is the latest Rust `project()` result. The concrete network effect is one
 * authenticated HTTP CONNECT through the PRODUCT loopback proxy followed by an HTTPS-validated TLS
 * handshake. The CONNECT authority remains a hostname, so Android never resolves the public target;
 * sing-box -> private Cellular Egress SOCKS -> cellular-owned scoped DNS remains the only target
 * resolver path.
 */
internal class ProductReadinessRuntime(
    private val runtimeGeneration: ULong,
    private val cellularRuntime: CellularRuntimeBridge,
    private val proxyRuntime: ProxyRuntimeSupervisor,
    private val meshRuntime: MeshIngressRuntimeBridge,
    private val credentialStore: ExternalProxyCredentialStore,
) : Closeable {
    private val controller = ProductReadinessController()
    private val closed = AtomicBoolean(false)
    private val socketLock = Any()
    private val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val probeExecutor = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mish-readiness-probe").apply { isDaemon = true }
    }
    private var activeSocket: Socket? = null
    private val mutableState = MutableStateFlow(projectUnknown())
    private var observationJob: Job? = null

    val state: StateFlow<ProductReadinessState>
        get() = mutableState.asStateFlow()

    init {
        observationJob = combine(
            cellularRuntime.snapshot,
            proxyRuntime.snapshot,
            meshRuntime.snapshot,
        ) { cellular, proxy, mesh ->
            StructuralObservation(cellular, proxy, mesh)
        }.onEach(::onStructuralObservation).launchIn(observationScope)
    }

    private fun onStructuralObservation(observation: StructuralObservation) {
        if (closed.get()) return

        // Structural change invalidates any older in-flight/completed probe before its socket is
        // closed. A concurrent late completion therefore cannot publish READY even for one frame.
        if (runCatching { controller.invalidateProbe() }.isFailure) {
            closeActiveSocket()
            mutableState.value = projectUnknown()
            return
        }
        closeActiveSocket()

        val facts = currentFacts(observation)
        mutableState.value = projectOrUnknown(facts, null)
        val binding = candidateBinding(facts) ?: return
        val ticket = try {
            controller.beginProbe(binding)
        } catch (_: Exception) {
            mutableState.value = projectUnknown()
            return
        }

        try {
            probeExecutor.execute { executeProbe(ticket) }
        } catch (_: RejectedExecutionException) {
            runCatching { controller.invalidateProbe() }
            mutableState.value = projectOrUnknown(currentFacts(), null)
        }
    }

    private fun executeProbe(ticket: ProbeTicketView) {
        if (closed.get() || controller.expectedFreshness() != ticket.freshness) return

        val target = try {
            readinessProbeTarget()
        } catch (_: Exception) {
            runCatching { controller.invalidateProbe() }
            mutableState.value = projectUnknown()
            return
        }
        val budgetMs = egressProbeBudgetMs().toLong()
        if (budgetMs <= 0L) {
            runCatching { controller.invalidateProbe() }
            mutableState.value = projectUnknown()
            return
        }
        val credential = credentialStore.currentCredential()
        if (credential == null || credential.version != ticket.binding.credentialVersion) {
            runCatching { controller.invalidateProbe() }
            mutableState.value = projectOrUnknown(currentFacts(), null)
            return
        }

        val started = System.nanoTime()
        val outcome = performAuthenticatedProxyTlsProbe(
            ticket = ticket,
            target = target,
            credentials = credential.credentials,
            budgetMs = budgetMs,
        )
        val elapsedMs = TimeUnit.NANOSECONDS
            .toMillis(System.nanoTime() - started)
            .coerceAtLeast(0L)
            .toULong()

        val completed = try {
            controller.completeProbe(ticket, outcome, elapsedMs)
        } catch (_: Exception) {
            null
        } ?: return

        // Re-read every owner projection after the effect. Rust compares the completed binding to
        // those current facts; a callback that has updated a StateFlow but has not yet run this
        // adapter's collector still cannot make a stale success READY.
        val facts = currentFacts()
        val projected = projectOrUnknown(facts, completed)
        if (controller.expectedFreshness() == completed.freshness) {
            mutableState.value = projected
        }
    }

    private fun performAuthenticatedProxyTlsProbe(
        ticket: ProbeTicketView,
        target: ReadinessProbeTargetView,
        credentials: ProxyRuntimeCredentials,
        budgetMs: Long,
    ): EgressProbeOutcome {
        val started = System.nanoTime()
        val deadline = started + TimeUnit.MILLISECONDS.toNanos(budgetMs)
        val socket = Socket()
        if (!registerActiveSocket(ticket, socket)) {
            socket.close()
            return EgressProbeOutcome.TRANSPORT_FAILED
        }

        try {
            socket.connect(
                InetSocketAddress(LOOPBACK, proxyHttpConnectPort().toInt()),
                remainingMillis(deadline),
            )
            socket.soTimeout = remainingMillis(deadline)

            val authority = "${target.hostname}:${target.port}"
            val basic = Base64.encodeToString(
                "${credentials.username}:${credentials.password}"
                    .toByteArray(StandardCharsets.UTF_8),
                Base64.NO_WRAP,
            )
            val request = buildString {
                append("CONNECT ")
                append(authority)
                append(" HTTP/1.1\r\nHost: ")
                append(authority)
                append("\r\nProxy-Authorization: Basic ")
                append(basic)
                append("\r\nProxy-Connection: keep-alive\r\n\r\n")
            }.toByteArray(StandardCharsets.US_ASCII)
            socket.getOutputStream().apply {
                write(request)
                flush()
            }

            val header = readBoundedConnectHeader(socket, deadline)
                ?: return EgressProbeOutcome.TRANSPORT_FAILED
            val status = classifyProxyConnectStatusLine(header.lineSequence().firstOrNull().orEmpty())
            if (status != EgressProbeOutcome.SUCCEEDED) return status

            val sslFactory = SSLSocketFactory.getDefault() as? SSLSocketFactory
                ?: return EgressProbeOutcome.TLS_FAILED
            val ssl = sslFactory.createSocket(
                socket,
                target.hostname,
                target.port.toInt(),
                false,
            ) as? SSLSocket ?: return EgressProbeOutcome.TLS_FAILED
            ssl.use {
                it.soTimeout = remainingMillis(deadline)
                it.sslParameters = it.sslParameters.apply {
                    endpointIdentificationAlgorithm = "HTTPS"
                }
                it.startHandshake()
            }
            return EgressProbeOutcome.SUCCEEDED
        } catch (_: SocketTimeoutException) {
            return EgressProbeOutcome.TIMEOUT
        } catch (_: SSLException) {
            return EgressProbeOutcome.TLS_FAILED
        } catch (_: IOException) {
            return EgressProbeOutcome.TRANSPORT_FAILED
        } catch (_: RuntimeException) {
            return EgressProbeOutcome.TRANSPORT_FAILED
        } finally {
            synchronized(socketLock) {
                if (activeSocket === socket) activeSocket = null
            }
            runCatching { socket.close() }
        }
    }

    private fun registerActiveSocket(ticket: ProbeTicketView, socket: Socket): Boolean =
        synchronized(socketLock) {
            if (closed.get() || controller.expectedFreshness() != ticket.freshness) {
                false
            } else {
                activeSocket?.let { runCatching { it.close() } }
                activeSocket = socket
                true
            }
        }

    private fun closeActiveSocket() {
        synchronized(socketLock) {
            activeSocket?.let { runCatching { it.close() } }
            activeSocket = null
        }
    }

    private fun readBoundedConnectHeader(socket: Socket, deadline: Long): String? {
        val input = socket.getInputStream()
        val output = ByteArrayOutputStream()
        var suffix = 0
        while (output.size() < MAX_CONNECT_HEADER_BYTES) {
            socket.soTimeout = remainingMillis(deadline)
            val next = input.read()
            if (next < 0) return null
            output.write(next)
            suffix = when {
                suffix == 0 && next == '\r'.code -> 1
                suffix == 1 && next == '\n'.code -> 2
                suffix == 2 && next == '\r'.code -> 3
                suffix == 3 && next == '\n'.code -> 4
                next == '\r'.code -> 1
                else -> 0
            }
            if (suffix == 4) {
                return output.toString(StandardCharsets.US_ASCII.name())
            }
        }
        return null
    }

    private fun remainingMillis(deadline: Long): Int {
        val remainingNanos = deadline - System.nanoTime()
        if (remainingNanos <= 0L) throw SocketTimeoutException("readiness probe deadline expired")
        return TimeUnit.NANOSECONDS
            .toMillis(remainingNanos)
            .coerceAtLeast(1L)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
    }

    private fun currentFacts(observation: StructuralObservation = StructuralObservation(
        cellularRuntime.snapshot.value,
        proxyRuntime.snapshot.value,
        meshRuntime.snapshot.value,
    )): ProductReadinessFactsView {
        val cellular = observation.cellular
        val ownerAdmission = (cellular as? CellularRuntimeSnapshot.OwnerSnapshot)?.admission
        val cellularGeneration = ownerAdmission?.lastSequence
        val cellularAdmitted = ownerAdmission?.state == CellularAdmissionState.ADMITTED

        val proxyDiagnostic = proxyRuntime.diagnosticObservation()
        val proxyHealthy = observation.proxy == ProxyRuntimeSnapshot.Running &&
            proxyDiagnostic.childAlive &&
            proxyDiagnostic.privateBridgeHealthy &&
            proxyDiagnostic.credentialVersion != null
        val credential = credentialStore.currentReadinessSnapshot()
        val mesh = observation.mesh

        return ProductReadinessFactsView(
            cellularOwnerGeneration = cellularGeneration,
            cellularAdmitted = cellularAdmitted,
            // CellularRuntimeBridge publishes an admitted OwnerSnapshot only after exact root-policy
            // reconciliation and Rust owner authorization for that same admission sequence.
            rootPolicyVerified = cellularAdmitted,
            runtimeGeneration = runtimeGeneration,
            privateBridgeHealthy = proxyDiagnostic.privateBridgeHealthy,
            proxyRuntimeGeneration = runtimeGeneration,
            proxyServingGeneration = if (proxyHealthy) runtimeGeneration else null,
            proxyCredentialVersion = if (proxyHealthy) proxyDiagnostic.credentialVersion else null,
            proxyHealthy = proxyHealthy,
            credentialVersion = credential?.version,
            credentialActive = credential?.active == true,
            meshRuntimeGeneration = if (mesh != null) runtimeGeneration else null,
            meshAdmissionEpoch = mesh?.admissionEpoch,
            meshAdmitted = mesh?.state == MeshAdmissionState.ADMITTED,
            meshIngressRunning = mesh?.ingressRunning == true,
        )
    }

    private fun candidateBinding(facts: ProductReadinessFactsView): ProbeBindingView? {
        val cellularGeneration = facts.cellularOwnerGeneration ?: return null
        val proxyGeneration = facts.proxyServingGeneration ?: return null
        val proxyCredential = facts.proxyCredentialVersion ?: return null
        val credentialVersion = facts.credentialVersion ?: return null
        val meshEpoch = facts.meshAdmissionEpoch ?: return null
        if (!facts.cellularAdmitted ||
            !facts.rootPolicyVerified ||
            !facts.privateBridgeHealthy ||
            !facts.proxyHealthy ||
            !facts.credentialActive ||
            !facts.meshAdmitted ||
            !facts.meshIngressRunning ||
            facts.runtimeGeneration != runtimeGeneration ||
            facts.proxyRuntimeGeneration != runtimeGeneration ||
            facts.meshRuntimeGeneration != runtimeGeneration ||
            proxyCredential != credentialVersion
        ) {
            return null
        }
        return ProbeBindingView(
            cellularOwnerGeneration = cellularGeneration,
            runtimeGeneration = runtimeGeneration,
            proxyServingGeneration = proxyGeneration,
            meshAdmissionEpoch = meshEpoch,
            credentialVersion = credentialVersion,
        )
    }

    private fun projectOrUnknown(
        facts: ProductReadinessFactsView,
        observation: EgressProbeObservationView?,
    ): ProductReadinessState = try {
        controller.project(facts, observation)
    } catch (_: Exception) {
        ProductReadinessState.UNKNOWN
    }

    private fun projectUnknown(): ProductReadinessState = try {
        controller.project(emptyFacts(), null)
    } catch (_: Exception) {
        ProductReadinessState.UNKNOWN
    }

    private fun emptyFacts(): ProductReadinessFactsView = ProductReadinessFactsView(
        cellularOwnerGeneration = null,
        cellularAdmitted = false,
        rootPolicyVerified = false,
        runtimeGeneration = null,
        privateBridgeHealthy = false,
        proxyRuntimeGeneration = null,
        proxyServingGeneration = null,
        proxyCredentialVersion = null,
        proxyHealthy = false,
        credentialVersion = null,
        credentialActive = false,
        meshRuntimeGeneration = null,
        meshAdmissionEpoch = null,
        meshAdmitted = false,
        meshIngressRunning = false,
    )

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        observationJob?.cancel()
        observationJob = null
        runCatching { controller.invalidateProbe() }
        closeActiveSocket()
        probeExecutor.shutdownNow()
        val stopped = try {
            probeExecutor.awaitTermination(PROBE_CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
            false
        }
        mutableState.value = projectUnknown()
        if (!stopped) {
            throw IllegalStateException("readiness probe worker did not stop cleanly")
        }
    }

    private data class StructuralObservation(
        val cellular: CellularRuntimeSnapshot,
        val proxy: ProxyRuntimeSnapshot,
        val mesh: MeshAdmissionView?,
    )

    private companion object {
        const val LOOPBACK = "127.0.0.1"
        const val MAX_CONNECT_HEADER_BYTES = 8_192
        const val PROBE_CLOSE_TIMEOUT_SECONDS = 2L
    }
}

/** Pure parser used by the concrete effect; it owns no proxy policy. */
internal fun classifyProxyConnectStatusLine(statusLine: String): EgressProbeOutcome {
    val parts = statusLine.trim().split(Regex("\\s+"), limit = 3)
    if (parts.size < 2 || (parts[0] != "HTTP/1.0" && parts[0] != "HTTP/1.1")) {
        return EgressProbeOutcome.TRANSPORT_FAILED
    }
    val status = parts[1].toIntOrNull() ?: return EgressProbeOutcome.TRANSPORT_FAILED
    return when {
        status == 407 -> EgressProbeOutcome.AUTHENTICATION_FAILED
        status in 200..299 -> EgressProbeOutcome.SUCCEEDED
        else -> EgressProbeOutcome.TRANSPORT_FAILED
    }
}
