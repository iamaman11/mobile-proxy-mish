package com.mobileproxymish.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.mobileproxymish.ffi.ExternalCredentialStateView
import com.mobileproxymish.ffi.externalCredentialDerivation
import com.mobileproxymish.ffi.externalCredentialInitialState
import com.mobileproxymish.ffi.externalCredentialMaterialize
import com.mobileproxymish.ffi.externalCredentialRestore
import com.mobileproxymish.ffi.externalCredentialRevoke
import com.mobileproxymish.ffi.externalCredentialRotate
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

/** Exact owner version plus in-memory external proxy material for one bounded provisioning read. */
internal class ExternalProxyCredentialSnapshot(
    val version: ULong,
    val credentialId: String,
    val credentials: ProxyRuntimeCredentials,
) {
    override fun toString(): String = "ExternalProxyCredentialSnapshot(<redacted>)"
}

/**
 * Narrow Android platform adapter for the Rust Credentials / Secrets natural owner.
 *
 * Durable secret bytes are represented only by a non-exportable Android Keystore HMAC root.
 * SharedPreferences contains one canonical base64 transport of the owner-scoped protobuf state;
 * derived proxy username/password values exist in memory only for a bounded runtime/provisioning
 * read. The two legacy scalar keys are accepted only for one fail-closed migration.
 */
internal class ExternalProxyCredentialStore(
    context: Context,
) : ProxyCredentialProvider {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    @Synchronized
    override fun currentCredential(): ProxyRuntimeCredentials? = runCatching {
        materializeCurrent().credentials
    }.getOrNull()

    /**
     * Returns one exact owner-version snapshot for the ADB-only Windows provisioning transaction.
     * This is read-only and serialized with rotation/revocation by this store's monitor.
     */
    @Synchronized
    fun currentProvisioningSnapshot(): ExternalProxyCredentialSnapshot? = runCatching {
        materializeCurrent()
    }.getOrNull()

    /**
     * Applies the natural-owner rotation transition and persists only its non-secret protobuf
     * result. Callers must invoke this only while the runtime is exactly stopped.
     */
    @Synchronized
    fun rotateWhileStopped(): Boolean = runCatching {
        val current = loadOrInitialize().state
        persistState(
            externalCredentialRotate(
                version = current.version,
                revoked = current.revoked,
            ),
        )
    }.getOrDefault(false)

    /**
     * Applies the natural-owner revocation transition and persists only its non-secret protobuf
     * result. Callers must invoke this only while the runtime is exactly stopped.
     */
    @Synchronized
    fun revokeWhileStopped(): Boolean = runCatching {
        val current = loadOrInitialize().state
        persistState(
            externalCredentialRevoke(
                version = current.version,
                revoked = current.revoked,
            ),
        )
    }.getOrDefault(false)

    private fun materializeCurrent(): ExternalProxyCredentialSnapshot {
        val stored = loadOrInitialize()
        val derivation = externalCredentialDerivation(
            version = stored.state.version,
            revoked = stored.state.revoked,
        )
        check(stored.root.encoded == null) {
            "Android Keystore HMAC root unexpectedly exportable"
        }
        val usernameMac = hmac(stored.root, derivation.usernameContext)
        val passwordMac = hmac(stored.root, derivation.passwordContext)
        val material = externalCredentialMaterialize(
            version = stored.state.version,
            revoked = stored.state.revoked,
            usernameMac = usernameMac,
            passwordMac = passwordMac,
        )
        return ExternalProxyCredentialSnapshot(
            version = stored.state.version,
            credentialId = stored.state.credentialId,
            credentials = ProxyRuntimeCredentials(
                username = material.username,
                password = material.password,
            ),
        )
    }

    /**
     * Creates the Keystore root only for the first complete owner state. Once protobuf metadata
     * exists, a missing root is corruption and must fail closed rather than silently changing
     * material under the same credential version.
     */
    private fun loadOrInitialize(): StoredCredentialRoot {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val encodedState = preferences.getString(KEY_STATE_PROTOBUF, null)
        val hasLegacyVersion = preferences.contains(LEGACY_KEY_VERSION)
        val hasLegacyRevoked = preferences.contains(LEGACY_KEY_REVOKED)

        if (encodedState != null) {
            check(!hasLegacyVersion && !hasLegacyRevoked) {
                "external credential metadata contains mixed protobuf and legacy schemas"
            }
            check(keyStore.containsAlias(ROOT_KEY_ALIAS)) {
                "external credential root missing for persisted owner state"
            }
            val root = keyStore.getKey(ROOT_KEY_ALIAS, null) as? SecretKey
                ?: error("Android Keystore external credential root has wrong key type")
            return StoredCredentialRoot(restoreState(decodeCanonicalBase64(encodedState)), root)
        }

        check(hasLegacyVersion == hasLegacyRevoked) {
            "legacy external credential owner metadata is incomplete"
        }
        if (hasLegacyVersion) {
            check(keyStore.containsAlias(ROOT_KEY_ALIAS)) {
                "external credential root missing for legacy owner state"
            }
            val root = keyStore.getKey(ROOT_KEY_ALIAS, null) as? SecretKey
                ?: error("Android Keystore external credential root has wrong key type")
            val version = preferences.getString(LEGACY_KEY_VERSION, null)?.toULongOrNull()
                ?: error("legacy external credential version is invalid")
            val state = externalCredentialRestore(
                version = version,
                revoked = preferences.getBoolean(LEGACY_KEY_REVOKED, false),
            )
            check(persistState(state)) { "failed to migrate credential metadata to protobuf" }
            return StoredCredentialRoot(state, root)
        }

        // A key without owner metadata is ambiguous (for example interrupted initialization or
        // lost metadata). Never guess a version because doing so could resurrect old material.
        check(!keyStore.containsAlias(ROOT_KEY_ALIAS)) {
            "external credential root exists without owner metadata"
        }

        val root = generateRootKey()
        val initial = externalCredentialInitialState()
        if (!persistState(initial)) {
            runCatching { keyStore.deleteEntry(ROOT_KEY_ALIAS) }
            error("failed to persist initial credential metadata")
        }
        return StoredCredentialRoot(initial, root)
    }

    private fun restoreState(encoded: ByteArray): ExternalCredentialStateView {
        val decoded = CredentialContractV1.decodeState(encoded)
        return externalCredentialRestore(
            version = decoded.version,
            revoked = decoded.revoked,
        )
    }

    private fun persistState(state: ExternalCredentialStateView): Boolean {
        val encoded = CredentialContractV1.encodeState(state.version, state.revoked)
        val base64 = Base64.encodeToString(encoded, Base64.NO_WRAP)
        return preferences.edit()
            .putString(KEY_STATE_PROTOBUF, base64)
            .remove(LEGACY_KEY_VERSION)
            .remove(LEGACY_KEY_REVOKED)
            .commit()
    }

    private fun decodeCanonicalBase64(encoded: String): ByteArray {
        val decoded = Base64.decode(encoded, Base64.NO_WRAP)
        check(Base64.encodeToString(decoded, Base64.NO_WRAP) == encoded) {
            "external credential protobuf transport encoding is non-canonical"
        }
        return decoded
    }

    private fun generateRootKey(): SecretKey {
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_HMAC_SHA256,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                ROOT_KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN,
            )
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setKeySize(ROOT_KEY_BITS)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private fun hmac(key: SecretKey, context: ByteArray): ByteArray = Mac
        .getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256)
        .apply { init(key) }
        .doFinal(context)

    private data class StoredCredentialRoot(
        val state: ExternalCredentialStateView,
        val root: SecretKey,
    )

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ROOT_KEY_ALIAS = "mobile-proxy-mish.external-proxy-root.v1"
        const val ROOT_KEY_BITS = 256
        const val PREFERENCES_NAME = "external-proxy-credential-state"
        const val KEY_STATE_PROTOBUF = "state_pb_b64_v1"
        const val LEGACY_KEY_VERSION = "version"
        const val LEGACY_KEY_REVOKED = "revoked"
    }
}
