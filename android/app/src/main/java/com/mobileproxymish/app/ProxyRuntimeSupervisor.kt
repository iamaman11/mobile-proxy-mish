package com.mobileproxymish.app

import com.mobileproxymish.ffi.NativeProductRuntime
import com.mobileproxymish.ffi.NativeProxyRuntimeObserver
import com.mobileproxymish.ffi.ProxyRuntimePublicationView
import com.mobileproxymish.ffi.ProxyServingFailure
import com.mobileproxymish.ffi.ProxyServingState
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/** Presentation projection of the Rust-owned current Proxy Serving generation. */
sealed interface ProxyRuntimeSnapshot {
    data object Stopped : ProxyRuntimeSnapshot
    data object Starting : ProxyRuntimeSnapshot
    data object Running : ProxyRuntimeSnapshot

    data class Failed(
        val reason: ProxyServingFailure,
    ) : ProxyRuntimeSnapshot
}

/** Non-secret read-only observation of the native Proxy coordinator. */
internal data class ProxyRuntimeDiagnosticObservation(
    val healthy: Boolean,
    val servingGeneration: Long?,
    val credentialVersion: ULong?,
    val activeSessions: UInt?,
)

/** In-memory only external proxy credential material. */
internal class ProxyRuntimeCredentials(
    val username: String,
    val password: String,
) {
    override fun toString(): String = "ProxyRuntimeCredentials(<redacted>)"
}

/** Exact Credentials-owner version plus sensitive in-memory material for one runtime start. */
internal class ProxyRuntimeCredentialSnapshot(
    val version: ULong,
    val credentials: ProxyRuntimeCredentials,
) {
    override fun toString(): String = "ProxyRuntimeCredentialSnapshot(version=$version,<redacted>)"
}

/**
 * Presentation-only Android projection of the Rust-owned Proxy runtime coordinator.
 *
 * Rust owns start/stop, serving generation, terminal failure and recovery. This class owns no
 * credentials, lifecycle token, retry state, timer or control path.
 */
class ProxyRuntimeSupervisor internal constructor(
    private val productRuntime: NativeProductRuntime,
) {
    private val mutableSnapshot = MutableStateFlow(
        projectOwnerPublication(productRuntime.proxyRuntimeSnapshot()),
    )

    val snapshot: StateFlow<ProxyRuntimeSnapshot>
        get() = mutableSnapshot.asStateFlow()

    init {
        productRuntime.observeProxyRuntime(
            object : NativeProxyRuntimeObserver {
                override fun onProxyRuntime(publication: ProxyRuntimePublicationView) {
                    mutableSnapshot.value = projectOwnerPublication(publication)
                }
            },
        )
    }

    internal fun diagnosticObservation(): ProxyRuntimeDiagnosticObservation {
        val publication = productRuntime.proxyRuntimeSnapshot()
        return ProxyRuntimeDiagnosticObservation(
            healthy = publication.state == ProxyServingState.RUNNING && publication.failure == null,
            servingGeneration = publication.servingGeneration?.toLong(),
            credentialVersion = publication.credentialVersion,
            activeSessions = runCatching { productRuntime.proxyActiveSessions() }.getOrNull(),
        )
    }

    private fun projectOwnerPublication(
        publication: ProxyRuntimePublicationView,
    ): ProxyRuntimeSnapshot = when (publication.state) {
        ProxyServingState.STOPPED -> ProxyRuntimeSnapshot.Stopped
        ProxyServingState.STARTING -> ProxyRuntimeSnapshot.Starting
        ProxyServingState.RUNNING -> ProxyRuntimeSnapshot.Running
        ProxyServingState.FAILED -> ProxyRuntimeSnapshot.Failed(
            publication.failure ?: ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE,
        )
    }
}
