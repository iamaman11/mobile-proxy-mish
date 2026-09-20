package com.mobileproxymish.app

import android.content.Context
import com.mobileproxymish.ffi.ExternalCredentialPersistenceActionView
import com.mobileproxymish.ffi.ExternalCredentialStateView
import com.mobileproxymish.ffi.externalCredentialResolvePersistence
import com.mobileproxymish.ffi.externalCredentialRevoke
import com.mobileproxymish.ffi.externalCredentialRotate

/** Exact owner version plus sensitive in-memory material for one explicit bounded read. */
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
 * Thin Android effects facade for the Rust Credentials natural owner.
 *
 * SharedPreferences is opaque byte storage and Android Keystore is the non-exportable HMAC effect.
 * Rust alone interprets persistence schemas, migration, version/status transitions and secret
 * formatting. The same durable Keystore root plus the same version deterministically materialize
 * the same current username/password across runtime, service, process and device restarts.
 */
internal class ExternalProxyCredentialStore private constructor(
    private val metadata: CredentialMetadataStore,
    private val rootEffect: AndroidKeystoreRoot,
) {
    constructor(context: Context) : this(
        CredentialMetadataStore(context),
        AndroidKeystoreRoot(),
    )

    internal constructor(
        context: Context,
        preferencesName: String,
        keystoreAlias: String,
    ) : this(
        CredentialMetadataStore(context, preferencesName),
        AndroidKeystoreRoot(keystoreAlias),
    )

    private val materializer = CredentialMaterializer(rootEffect)

    /**
     * Runtime dependency resolution may provision the one initial current credential when none
     * exists. It never rotates an existing credential.
     */
    @Synchronized
    fun currentCredentialForRuntime(): ProxyRuntimeCredentialSnapshot? = runCatching {
        val current = materializeCurrent(loadOrInitializeState())
        ProxyRuntimeCredentialSnapshot(
            version = current.version,
            credentials = current.credentials,
        )
    }.getOrNull()

    /** Explicit sensitive read. Never creates a root, advances a version or rotates credentials. */
    @Synchronized
    fun revealCurrentCredential(): ExternalProxyCredentialSnapshot? = runCatching {
        val state = existingStateForObservation() ?: return@runCatching null
        materializeCurrent(state)
    }.getOrNull()

    /** Read-only exact owner-version snapshot for the DUMP-gated provisioning transaction. */
    @Synchronized
    fun currentProvisioningSnapshot(): ExternalProxyCredentialSnapshot? =
        revealCurrentCredential()

    /**
     * Read-only observation never initializes metadata or creates a Keystore root. Legacy schema
     * interpretation is still Rust-owned; observation does not need to persist the returned
     * migration plan.
     */
    @Synchronized
    fun currentReadinessSnapshot(): ExternalProxyCredentialReadinessSnapshot? = runCatching {
        val state = existingStateForObservation() ?: return@runCatching null
        ExternalProxyCredentialReadinessSnapshot(
            version = state.version,
            active = !state.revoked,
        )
    }.getOrNull()

    /** Explicit Rust-owner rotation transition, valid only under the stopped-platform lease. */
    @Synchronized
    fun rotateWhileStopped(): Boolean = runCatching {
        val current = loadOrInitializeState()
        val rotated = externalCredentialRotate(
            version = current.version,
            revoked = current.revoked,
        )
        metadata.persistCanonical(rotated.canonicalState)
    }.getOrDefault(false)

    /** Explicit Rust-owner revocation transition, valid only under the stopped-platform lease. */
    @Synchronized
    fun revokeWhileStopped(): Boolean = runCatching {
        val current = loadOrInitializeState()
        val revoked = externalCredentialRevoke(
            version = current.version,
            revoked = current.revoked,
        )
        metadata.persistCanonical(revoked.canonicalState)
    }.getOrDefault(false)

    private fun materializeCurrent(state: ExternalCredentialStateView): ExternalProxyCredentialSnapshot =
        materializer.materialize(state, rootEffect.load())

    private fun existingStateForObservation(): ExternalCredentialStateView? {
        val raw = metadata.readRaw()
        val resolution = externalCredentialResolvePersistence(
            canonicalState = raw.canonicalState,
            legacyVersion = raw.legacyVersion,
            legacyRevoked = raw.legacyRevoked,
            rootExists = rootEffect.exists(),
        )
        return when (resolution.action) {
            ExternalCredentialPersistenceActionView.CREATE_ROOT_AND_PERSIST_CANONICAL -> null
            ExternalCredentialPersistenceActionView.USE_CURRENT,
            ExternalCredentialPersistenceActionView.PERSIST_CANONICAL,
            -> resolution.state
        }
    }

    private fun loadOrInitializeState(): ExternalCredentialStateView {
        val raw = metadata.readRaw()
        val resolution = externalCredentialResolvePersistence(
            canonicalState = raw.canonicalState,
            legacyVersion = raw.legacyVersion,
            legacyRevoked = raw.legacyRevoked,
            rootExists = rootEffect.exists(),
        )
        when (resolution.action) {
            ExternalCredentialPersistenceActionView.USE_CURRENT -> Unit
            ExternalCredentialPersistenceActionView.PERSIST_CANONICAL -> {
                check(metadata.persistCanonical(resolution.canonicalState)) {
                    "failed to persist canonical credential owner state"
                }
            }
            ExternalCredentialPersistenceActionView.CREATE_ROOT_AND_PERSIST_CANONICAL -> {
                rootEffect.generate()
                if (!metadata.persistCanonical(resolution.canonicalState)) {
                    runCatching(rootEffect::delete)
                    error("failed to persist initial credential owner state")
                }
            }
        }
        return resolution.state
    }
}
