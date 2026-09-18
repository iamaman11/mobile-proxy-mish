package com.mobileproxymish.app

import com.mobileproxymish.ffi.NativeProductRuntime
import com.mobileproxymish.ffi.NativeProxyRuntimeObserver
import com.mobileproxymish.ffi.ProxyRuntimePublicationView
import com.mobileproxymish.ffi.ProxyServingFailure
import com.mobileproxymish.ffi.ProxyServingState
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
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

/** Exact Credentials-owner version plus ephemeral derived material for one runtime start. */
internal class ProxyRuntimeCredentialSnapshot(
    val version: ULong,
    val credentials: ProxyRuntimeCredentials,
) {
    override fun toString(): String = "ProxyRuntimeCredentialSnapshot(version=$version,<redacted>)"
}

/** Narrow composition input; credential lifecycle and durable semantics remain in Rust. */
internal fun interface ProxyCredentialProvider {
    fun currentCredential(): ProxyRuntimeCredentialSnapshot?
}

/**
 * Android composition/presentation adapter for the Rust-owned Proxy runtime coordinator.
 *
 * Rust owns serving-generation identity, listener/session execution, terminal failure,
 * recoverability, backoff, recovery timers and restart. Android supplies the current credential
 * snapshot at an explicit start and projects immutable native publications to StateFlow.
 */
class ProxyRuntimeSupervisor internal constructor(
    private val productRuntime: NativeProductRuntime,
    private val publicCredentials: ProxyCredentialProvider,
) : Closeable {
    private val closed = AtomicBoolean(false)
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

    fun start() {
        if (closed.get()) return
        val publicCredential = try {
            publicCredentials.currentCredential()
        } catch (_: Exception) {
            null
        }
        val publication = try {
            productRuntime.startProxyRuntime(
                credentialVersion = publicCredential?.version,
                username = publicCredential?.credentials?.username,
                password = publicCredential?.credentials?.password,
            )
        } catch (_: LinkageError) {
            null
        } catch (_: Exception) {
            null
        }
        mutableSnapshot.value = if (publication == null) {
            ProxyRuntimeSnapshot.Failed(ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE)
        } else {
            projectOwnerPublication(publication)
        }
    }

    fun stop() {
        if (closed.get()) return
        val publication = try {
            productRuntime.stopProxyRuntime()
        } catch (_: Exception) {
            null
        }
        mutableSnapshot.value = if (publication == null) {
            ProxyRuntimeSnapshot.Failed(ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE)
        } else {
            projectOwnerPublication(publication)
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        val publication = try {
            productRuntime.stopProxyRuntime()
        } catch (_: Exception) {
            null
        }
        mutableSnapshot.value = if (publication == null) {
            ProxyRuntimeSnapshot.Failed(ProxyServingFailure.RUNTIME_STATE_UNAVAILABLE)
        } else {
            projectOwnerPublication(publication)
        }
        if (publication?.failure == ProxyServingFailure.SHUTDOWN_FAILED) {
            throw IllegalStateException("native proxy runtime cleanup failed")
        }
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
