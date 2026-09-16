package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.ffi.ExternalCredentialStateView
import com.mobileproxymish.ffi.externalCredentialRevoke
import com.mobileproxymish.ffi.externalCredentialRotate

/** Exact owner version plus in-memory external proxy material for one bounded provisioning read. */
internal class ExternalProxyCredentialSnapshot(
    val version: ULong,
    val credentialId: String,
    val credentials: ProxyRuntimeCredentials,
) {
    override fun toString(): String = "ExternalProxyCredentialSnapshot(<redacted>)"
}

/** Non-secret read-only owner projection used by readiness composition. */
internal data class ExternalProxyCredentialReadinessSnapshot(
    val version: ULong,
    val active: Boolean,
)

/**
 * Thin Android facade for the Rust Credentials / Secrets natural owner.
 *
 * `CredentialMetadataStore` owns the canonical `state_pb_b64_v1` durable protobuf schema and
 * bounded legacy migration. `AndroidKeystoreRoot` owns the non-exportable physical secret root and
 * HMAC effect, and `CredentialMaterializer` derives bounded in-memory proxy material. This facade
 * serializes those effects with Rust owner transitions; it owns no duplicate credential lifecycle
 * state machine.
 */
internal class ExternalProxyCredentialStore(
    context: Context,
) : ProxyCredentialProvider {
    private val metadata = CredentialMetadataStore(context.applicationContext)
    private val rootEffect = AndroidKeystoreRoot()
    private val materializer = CredentialMaterializer(rootEffect)

    @Synchronized
    override fun currentCredential(): ProxyRuntimeCredentialSnapshot? = runCatching {
        val current = materializeCurrent()
        ProxyRuntimeCredentialSnapshot(
            version = current.version,
            credentials = current.credentials,
        )
    }.getOrNull()

    /** Read-only, exact owner-version snapshot for the ADB-only provisioning transaction. */
    @Synchronized
    fun currentProvisioningSnapshot(): ExternalProxyCredentialSnapshot? = runCatching {
        materializeCurrent()
    }.getOrNull()

    /**
     * Read-only observation never initializes metadata, creates a Keystore root or performs legacy
     * migration. It projects only already-coherent existing Credentials-owner state.
     */
    @Synchronized
    fun currentReadinessSnapshot(): ExternalProxyCredentialReadinessSnapshot? = runCatching {
        val state = metadata.existingForObservation(rootEffect.exists()) ?: return@runCatching null
        ExternalProxyCredentialReadinessSnapshot(
            version = state.version,
            active = !state.revoked,
        )
    }.getOrNull()

    /** Applies the Rust natural-owner rotation transition while the runtime is exactly stopped. */
    @Synchronized
    fun rotateWhileStopped(): Boolean = runCatching {
        val current = loadOrInitializeState()
        metadata.persist(
            externalCredentialRotate(
                version = current.version,
                revoked = current.revoked,
            ),
        )
    }.getOrDefault(false)

    /** Applies the Rust natural-owner revocation transition while the runtime is exactly stopped. */
    @Synchronized
    fun revokeWhileStopped(): Boolean = runCatching {
        val current = loadOrInitializeState()
        metadata.persist(
            externalCredentialRevoke(
                version = current.version,
                revoked = current.revoked,
            ),
        )
    }.getOrDefault(false)

    private fun materializeCurrent(): ExternalProxyCredentialSnapshot {
        val state = loadOrInitializeState()
        return materializer.materialize(state, rootEffect.load())
    }

    private fun loadOrInitializeState(): ExternalCredentialStateView = metadata.loadOrInitialize(
        rootExists = rootEffect.exists(),
        createRoot = {
            rootEffect.generate()
            Unit
        },
        deleteRoot = rootEffect::delete,
    )
}
