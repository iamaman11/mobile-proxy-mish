package com.mobileproxymish.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
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

/**
 * Narrow Android platform adapter for the Rust Credentials / Secrets natural owner.
 *
 * Durable secret bytes are represented only by a non-exportable Android Keystore HMAC root.
 * SharedPreferences contains owner-approved non-secret version/revocation metadata only. Derived
 * proxy username/password values exist in memory only for the current runtime start transaction.
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
        ProxyRuntimeCredentials(
            username = material.username,
            password = material.password,
        )
    }.getOrNull()

    /**
     * Applies the natural-owner rotation transition and persists only its non-secret result.
     * Callers must invoke this only while the runtime is exactly stopped.
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
     * Applies the natural-owner revocation transition and persists only its non-secret result.
     * Callers must invoke this only while the runtime is exactly stopped.
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

    /**
     * Creates the Keystore root only for the first complete owner state. Once metadata exists,
     * a missing root is corruption and must fail closed rather than silently changing material
     * under the same credential version.
     */
    private fun loadOrInitialize(): StoredCredentialRoot {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val hasVersion = preferences.contains(KEY_VERSION)
        val hasRevoked = preferences.contains(KEY_REVOKED)
        check(hasVersion == hasRevoked) {
            "external credential owner metadata is incomplete"
        }

        if (hasVersion) {
            check(keyStore.containsAlias(ROOT_KEY_ALIAS)) {
                "external credential root missing for persisted owner state"
            }
            val root = keyStore.getKey(ROOT_KEY_ALIAS, null) as? SecretKey
                ?: error("Android Keystore external credential root has wrong key type")
            val version = preferences.getString(KEY_VERSION, null)?.toULongOrNull()
                ?: error("persisted external credential version is invalid")
            val state = externalCredentialRestore(
                version = version,
                revoked = preferences.getBoolean(KEY_REVOKED, false),
            )
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

    private fun persistState(state: ExternalCredentialStateView): Boolean = preferences
        .edit()
        .putString(KEY_VERSION, state.version.toString())
        .putBoolean(KEY_REVOKED, state.revoked)
        .commit()

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
        const val KEY_VERSION = "version"
        const val KEY_REVOKED = "revoked"
    }
}
