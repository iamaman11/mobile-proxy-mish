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
        val state = loadOrCreateState()
        val derivation = externalCredentialDerivation(
            version = state.version,
            revoked = state.revoked,
        )
        val root = loadOrCreateRootKey()
        check(root.encoded == null) { "Android Keystore HMAC root unexpectedly exportable" }
        val usernameMac = hmac(root, derivation.usernameContext)
        val passwordMac = hmac(root, derivation.passwordContext)
        val material = externalCredentialMaterialize(
            version = state.version,
            revoked = state.revoked,
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
        val current = loadOrCreateState()
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
        val current = loadOrCreateState()
        persistState(
            externalCredentialRevoke(
                version = current.version,
                revoked = current.revoked,
            ),
        )
    }.getOrDefault(false)

    private fun loadOrCreateState(): ExternalCredentialStateView {
        val encodedVersion = preferences.getString(KEY_VERSION, null)
        if (encodedVersion == null) {
            val initial = externalCredentialInitialState()
            check(persistState(initial)) { "failed to persist initial credential metadata" }
            return initial
        }

        val version = encodedVersion.toULongOrNull()
            ?: error("persisted external credential version is invalid")
        return externalCredentialRestore(
            version = version,
            revoked = preferences.getBoolean(KEY_REVOKED, false),
        )
    }

    private fun persistState(state: ExternalCredentialStateView): Boolean = preferences
        .edit()
        .putString(KEY_VERSION, state.version.toString())
        .putBoolean(KEY_REVOKED, state.revoked)
        .commit()

    private fun loadOrCreateRootKey(): SecretKey {
        val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        val existing = keyStore.getKey(ROOT_KEY_ALIAS, null)
        if (existing != null) {
            return existing as? SecretKey
                ?: error("Android Keystore external credential root has wrong key type")
        }

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
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey()
    }

    private fun hmac(key: SecretKey, context: ByteArray): ByteArray = Mac
        .getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256)
        .apply { init(key) }
        .doFinal(context)

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ROOT_KEY_ALIAS = "mobile-proxy-mish.external-proxy-root.v1"
        const val PREFERENCES_NAME = "external-proxy-credential-state"
        const val KEY_VERSION = "version"
        const val KEY_REVOKED = "revoked"
    }
}
