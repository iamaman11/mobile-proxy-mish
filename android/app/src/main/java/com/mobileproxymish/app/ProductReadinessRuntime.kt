package com.mobileproxymish.app

import com.mobileproxymish.app.cellular.CellularRuntimeBridge
import com.mobileproxymish.app.cellular.CellularRuntimeSnapshot
import com.mobileproxymish.ffi.CellularAdmissionState
import com.mobileproxymish.ffi.EgressProbeObservationView
import com.mobileproxymish.ffi.MeshAdmissionState
import com.mobileproxymish.ffi.MeshAdmissionView
import com.mobileproxymish.ffi.ProbeBindingView
import com.mobileproxymish.ffi.ProbeTicketView
import com.mobileproxymish.ffi.ProductReadinessController
import com.mobileproxymish.ffi.ProductReadinessFactsView
import com.mobileproxymish.ffi.ProductReadinessState
import com.mobileproxymish.ffi.egressProbeBudgetMs
import com.mobileproxymish.ffi.readinessProbeBindingIfEligible
import com.mobileproxymish.ffi.readinessProbeRefreshDelayMs
import com.mobileproxymish.ffi.readinessProbeTarget
import java.io.Closeable
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
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
 * Thin Android composition adapter for the Rust Readiness/Application contracts.
 *
 * Rust owns freshness, probe eligibility, refresh cadence and terminal readiness projection. This
 * adapter only assembles immutable owner projections, schedules the next requested refresh, executes
 * Android CONNECT+TLS effects through `AuthenticatedEgressProbe`, and returns typed observations. The public hostname is never
 * resolved by Android: native Proxy Serving preserves it until the exact Cellular DNS owner.
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
    private val observationScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private val probeExecutor = Executors.newSingleThreadScheduledExecutor { task ->
        Thread(task, "mish-readiness-probe").apply { isDaemon = true }
    }
    private val refreshLock = Any()
    private val probeIssueLock = Any()
    private var refreshFuture: ScheduledFuture<*>? = null
    private val probeEffect = AuthenticatedEgressProbe { freshness ->
        !closed.get() && controller.expectedFreshness() == freshness
    }
    private val mutableState = MutableStateFlow(projectUnknown())
    private var observationJob: Job? = null
    private var lastStructuralFacts: ProductReadinessFactsView? = null

    val state: StateFlow<ProductReadinessState>
        get() = mutableState.asStateFlow()

    /** Sanitized owner facts only; no endpoint, DNS, credentials, route or probe response. */
    internal fun diagnosticObservation(): ProductReadinessDiagnostic {
        val facts = currentFacts()
        val admission = (cellularRuntime.snapshot.value as? CellularRuntimeSnapshot.OwnerSnapshot)
            ?.admission
        return ProductReadinessDiagnostic(
            cellularState = admission?.state?.name ?: "ABSENT",
            cellularReason = admission?.reason?.name ?: "NONE",
            cellularAdmitted = facts.cellularAdmitted,
            rootPolicyVerified = facts.rootPolicyVerified,
            proxyHealthy = facts.proxyHealthy,
            credentialActive = facts.credentialActive,
            meshAdmitted = facts.meshAdmitted,
            bindingEligible = eligibleBinding(facts) != null,
        )
    }

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

        val facts = currentFacts(observation)
        // Callback sequence noise is not a readiness fact. Only semantic owner facts invalidate the
        // current binding, so duplicate equivalent Mesh observations cannot starve the probe.
        if (facts == lastStructuralFacts) return
        lastStructuralFacts = facts
        cancelScheduledRefresh()

        val binding = eligibleBinding(facts)
        var invalidationFailed = false
        val ticket = synchronized(probeIssueLock) {
            if (runCatching { controller.invalidateProbe() }.isFailure) {
                invalidationFailed = true
                null
            } else if (binding == null) {
                null
            } else {
                try {
                    controller.beginProbe(binding)
                } catch (_: Exception) {
                    null
                }
            }
        }
        probeEffect.cancel()

        if (invalidationFailed) {
            mutableState.value = projectUnknown()
            return
        }
        mutableState.value = projectOrUnknown(facts, null)
        if (binding == null) return
        if (ticket == null) {
            mutableState.value = projectUnknown()
            return
        }

        try {
            probeExecutor.execute { executeProbe(ticket) }
        } catch (_: RejectedExecutionException) {
            synchronized(probeIssueLock) {
                runCatching { controller.invalidateProbe() }
            }
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
        val outcome = probeEffect.execute(
            freshness = ticket.freshness,
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

        val facts = currentFacts()
        val projected = projectOrUnknown(facts, completed)
        if (controller.expectedFreshness() == completed.freshness) {
            mutableState.value = projected
            if (eligibleBinding(facts) == completed.binding) {
                scheduleRefresh(completed.binding)
            }
        }
    }

    private fun scheduleRefresh(binding: ProbeBindingView) {
        val delayMs = try {
            readinessProbeRefreshDelayMs().toLong()
        } catch (_: Exception) {
            return
        }
        if (delayMs <= 0L || closed.get()) return

        synchronized(refreshLock) {
            if (closed.get()) return
            refreshFuture?.cancel(false)
            refreshFuture = try {
                probeExecutor.schedule(
                    {
                        synchronized(refreshLock) {
                            refreshFuture = null
                        }
                        executeScheduledRefresh(binding)
                    },
                    delayMs,
                    TimeUnit.MILLISECONDS,
                )
            } catch (_: RejectedExecutionException) {
                null
            }
        }
    }

    private fun executeScheduledRefresh(expectedBinding: ProbeBindingView) {
        if (closed.get()) return
        val ticket = synchronized(probeIssueLock) {
            if (closed.get()) return
            val facts = currentFacts()
            val binding = eligibleBinding(facts) ?: return
            if (!readinessRefreshBindingStillCurrent(expectedBinding, binding)) return
            try {
                controller.beginProbe(binding)
            } catch (_: Exception) {
                null
            }
        }
        if (ticket == null) {
            mutableState.value = projectUnknown()
            return
        }

        // Same-binding refresh is bounded stale-while-revalidate: preserve the last terminal
        // Rust-projected state until this probe completes. Publishing UNKNOWN here would
        // fail-close Mesh ingress on every healthy periodic refresh. Structural owner changes use
        // the separate invalidation path above and never receive this grace.
        executeProbe(ticket)
    }

    private fun cancelScheduledRefresh() {
        synchronized(refreshLock) {
            refreshFuture?.cancel(false)
            refreshFuture = null
        }
    }

    private fun currentFacts(
        observation: StructuralObservation = StructuralObservation(
            cellularRuntime.snapshot.value,
            proxyRuntime.snapshot.value,
            meshRuntime.snapshot.value,
        ),
    ): ProductReadinessFactsView {
        val ownerAdmission = (observation.cellular as? CellularRuntimeSnapshot.OwnerSnapshot)?.admission
        val cellularGeneration = ownerAdmission?.lastSequence
        val cellularAdmitted = ownerAdmission?.state == CellularAdmissionState.ADMITTED

        val proxyDiagnostic = proxyRuntime.diagnosticObservation()
        val proxyHealthy = observation.proxy == ProxyRuntimeSnapshot.Running &&
            proxyDiagnostic.healthy &&
            proxyDiagnostic.credentialVersion != null
        val credential = credentialStore.currentReadinessSnapshot()
        val mesh = observation.mesh

        return ProductReadinessFactsView(
            cellularOwnerGeneration = cellularGeneration,
            cellularAdmitted = cellularAdmitted,
            // The Cellular adapter publishes ADMITTED only after exact root-policy reconcile and
            // Rust owner authorization for that same generation.
            rootPolicyVerified = cellularAdmitted,
            runtimeGeneration = runtimeGeneration,
            proxyRuntimeGeneration = runtimeGeneration,
            proxyServingGeneration = if (proxyHealthy) runtimeGeneration else null,
            proxyCredentialVersion = if (proxyHealthy) proxyDiagnostic.credentialVersion else null,
            proxyHealthy = proxyHealthy,
            credentialVersion = credential?.version,
            credentialActive = credential?.active == true,
            meshRuntimeGeneration = if (mesh != null) runtimeGeneration else null,
            meshAdmissionEpoch = mesh?.admissionEpoch,
            meshAdmitted = mesh?.state == MeshAdmissionState.ADMITTED,
            // Public ingress is an effect of READY, never an input to READY.
            meshIngressRunning = false,
        )
    }

    private fun eligibleBinding(facts: ProductReadinessFactsView): ProbeBindingView? = try {
        readinessProbeBindingIfEligible(facts)
    } catch (_: Exception) {
        null
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
        cancelScheduledRefresh()
        synchronized(probeIssueLock) {
            runCatching { controller.invalidateProbe() }
        }
        probeEffect.cancel()
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
        const val PROBE_CLOSE_TIMEOUT_SECONDS = 2L
    }
}

internal fun readinessRefreshBindingStillCurrent(
    expected: ProbeBindingView,
    current: ProbeBindingView?,
): Boolean = current == expected

internal data class ProductReadinessDiagnostic(
    val cellularState: String,
    val cellularReason: String,
    val cellularAdmitted: Boolean,
    val rootPolicyVerified: Boolean,
    val proxyHealthy: Boolean,
    val credentialActive: Boolean,
    val meshAdmitted: Boolean,
    val bindingEligible: Boolean,
)
