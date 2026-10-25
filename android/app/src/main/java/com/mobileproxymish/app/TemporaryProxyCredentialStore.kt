package com.mobileproxymish.app

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.mobileproxymish.ffi.externalTemporaryCredentialIssue
import com.mobileproxymish.ffi.externalTemporaryCredentialObserve
import com.mobileproxymish.ffi.externalTemporaryCredentialRevoke
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Sensitive in-memory read from a separately protected optional temporary credential. */
internal class TemporaryProxyCredentialSnapshot(
    val username: String,
    val password: String,
    val expiresAtUnixSeconds: ULong,
) {
    override fun toString(): String = "TemporaryProxyCredentialSnapshot(<redacted>)"
}

/**
 * Android Keystore AES-GCM and opaque SharedPreferences effect for the Rust Credentials owner.
 *
 * The entire username/password/lease record is authenticated and encrypted together. There is
 * no second PRODUCT state-machine owner in Kotlin: Rust FFI issues/observes/revokes the lease.
 * Never save a plaintext record, persist an observed admission after reporting true, or log a
 * password, ciphertext, returned FFI record or exception containing sensitive material.
 */
internal class TemporaryProxyCredentialStore(context: Context) {
    private val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    /** This is a single one-time additional credential, not a general user-management facility.
     * A second issue after any existing record is deliberately disallowed until an explicit
     * separate owner renewal/replacement operation is implemented and accepted.
     */
    @Synchronized
    fun issueOnce(username: String, password: String): Boolean = runCatching {
        check(!preferences.contains(KEY_ENCRYPTED_RECORD))
        val now = utcSeconds() ?: error("clock unavailable")
        val plaintext = externalTemporaryCredentialIssue(
            generation = 1uL,
            trustedUnixSeconds = now,
            username = username,
            password = password,
        )
        val sealed = seal(plaintext)
        check(preferences.edit().putString(KEY_ENCRYPTED_RECORD, sealed).commit())
        true
    }.getOrDefault(false)

    /** Refresh the sole Rust lease before admission, encrypt and durably commit before success.
     * Missing/corrupt Keystore state and uncertain/rewound time deny SECONDARY, not the primary.
     */
    @Synchronized
    fun currentForRuntime(): TemporaryProxyCredentialSnapshot? = runCatching {
        val encrypted = preferences.getString(KEY_ENCRYPTED_RECORD, null)
            ?: return@runCatching null
        val cleartext = open(encrypted)
        val decision = externalTemporaryCredentialObserve(
            protectedPlaintext = cleartext,
            trustedUnixSeconds = utcSeconds(),
        )
        check(preferences.edit().putString(KEY_ENCRYPTED_RECORD, seal(decision.nextState)).commit())
        if (!decision.admitted) return@runCatching null
        TemporaryProxyCredentialSnapshot(
            username = decision.username,
            password = decision.password,
            expiresAtUnixSeconds = decision.expiresAtUnixSeconds,
        )
    }.getOrNull()

    /** This is intentionally a fresh owner-backed read on EACH secondary auth, not a cached yes. */
    @Synchronized
    fun temporaryAvailableNow(): Boolean = currentForRuntime() != null

    /** Persist permanent revoke (and invalidate encryption root on failure) before reporting it.
     * The runtime controller separately invalidates the live secondary generation.
     */
    @Synchronized
    fun revoke(): Boolean = runCatching {
        val encrypted = preferences.getString(KEY_ENCRYPTED_RECORD, null) ?: return@runCatching true
        val revoked = externalTemporaryCredentialRevoke(open(encrypted))
        if (!preferences.edit().putString(KEY_ENCRYPTED_RECORD, seal(revoked)).commit()) {
            runCatching { keystore().deleteEntry(KEY_ALIAS) }
            return@runCatching false
        }
        true
    }.getOrDefault(false)

    /** A failed atomic issuance must invalidate the secret before the caller can retry. */
    @Synchronized
    fun invalidateUncommittedIssue(): Boolean = runCatching {
        val keyStore = keystore()
        if (keyStore.containsAlias(KEY_ALIAS)) keyStore.deleteEntry(KEY_ALIAS)
        preferences.edit().remove(KEY_ENCRYPTED_RECORD).commit()
    }.getOrDefault(false)

    private fun seal(plaintext: ByteArray): String {
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())
        cipher.updateAAD(ADDITIONAL_DATA)
        val iv = cipher.iv
        require(iv.size == NONCE_LENGTH)
        val ciphertext = cipher.doFinal(plaintext)
        val packed = byteArrayOf(FORMAT_VERSION) + iv + ciphertext
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    private fun open(encoded: String): ByteArray {
        val packed = Base64.decode(encoded, Base64.NO_WRAP)
        require(Base64.encodeToString(packed, Base64.NO_WRAP) == encoded)
        require(packed.size > 1 + NONCE_LENGTH + 16)
        require(packed[0] == FORMAT_VERSION)
        val key = keystore().getKey(KEY_ALIAS, null) as? SecretKey
            ?: error("temporary proxy key unavailable")
        check(key.encoded == null)
        val iv = packed.copyOfRange(1, 1 + NONCE_LENGTH)
        val payload = packed.copyOfRange(1 + NONCE_LENGTH, packed.size)
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(ADDITIONAL_DATA)
        return cipher.doFinal(payload)
    }

    private fun encryptionKey(): SecretKey {
        val store = keystore()
        val existing = store.getKey(KEY_ALIAS, null) as? SecretKey
        if (existing != null) {
            check(existing.encoded == null)
            return existing
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun keystore(): KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun utcSeconds(): ULong? =
        System.currentTimeMillis().takeIf { it > 0L }?.toULong()?.div(1000uL)

    private companion object {
        const val PREFERENCES_NAME = "temporary-proxy-credential-v1"
        const val KEY_ENCRYPTED_RECORD = "encrypted-owner-record-v1"
        const val KEY_ALIAS = "mish-temporary-proxy-aes-gcm-v1"
        const val CIPHER = "AES/GCM/NoPadding"
        const val NONCE_LENGTH = 12
        const val FORMAT_VERSION: Byte = 1
        val ADDITIONAL_DATA = "mish-temporary-proxy-record-v1".toByteArray(Charsets.US_ASCII)
    }
}
