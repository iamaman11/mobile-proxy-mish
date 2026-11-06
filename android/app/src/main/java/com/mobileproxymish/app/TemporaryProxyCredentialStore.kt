package com.mobileproxymish.app

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.mobileproxymish.ffi.externalTemporaryCredentialIssue
import com.mobileproxymish.ffi.externalTemporaryCredentialObserve
import com.mobileproxymish.ffi.externalTemporaryCredentialRevoke
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Sensitive in-memory read: never write this record into diagnostics or error output. */
internal class TemporaryProxyCredentialSnapshot(
    val username: String,
    val password: String,
    val expiresAtUnixSeconds: ULong,
) {
    override fun toString(): String = "TemporaryProxyCredentialSnapshot(<redacted>)"
}

/**
 * Android Keystore AES-GCM effect for the one optional Rust Credentials lease.
 *
 * The lease, username/password and kernel monotonic clock anchor are encrypted as ONE record,
 * and each updated Rust decision is durably committed before it can authorize secondary access.
 * This never reads or modifies the primary credential preferences or primary Keystore alias.
 */
internal class TemporaryProxyCredentialStore(
    context: Context,
    preferencesName: String = PREFERENCES_NAME,
    private val keyAlias: String = KEY_ALIAS,
) {
    private val resolver = context.contentResolver
    private val preferences = context.getSharedPreferences(preferencesName, Context.MODE_PRIVATE)

    /** A one-time grant cannot be recreated after expiration or revocation. */
    @Synchronized
    fun hasBeenIssued(): Boolean = preferences.contains(KEY_ENCRYPTED_RECORD)

    /** Initial wall time only labels the expiry; 24h duration is Android elapsedRealtime.
     * A network-synchronized wall clock is requested for a useful expiry label, but monotonic
     * kernel time (with boot validation) is the actual time authority during this boot.
     */
    @Synchronized
    fun issueOnce(username: String, password: String): Boolean = runCatching {
        check(!preferences.contains(KEY_ENCRYPTED_RECORD))
        check(Settings.Global.getInt(resolver, Settings.Global.AUTO_TIME, 0) == 1)
        val anchor = TemporaryLeaseMonotonicClock.issue(
            bootCount = bootCount(),
            elapsedMillis = SystemClock.elapsedRealtime(),
            wallUnixSeconds = System.currentTimeMillis() / 1_000L,
        ) ?: error("temporary clock anchor unavailable")
        val plain = externalTemporaryCredentialIssue(
            generation = 1uL,
            trustedUnixSeconds = anchor.activatedUnixSeconds.toULong(),
            username = username,
            password = password,
        )
        check(preferences.edit()
            .putString(KEY_ENCRYPTED_RECORD, seal(encodeEnvelope(anchor, plain)))
            .commit())
        true
    }.getOrDefault(false)

    /** Fresh fail-closed Rust lease decision for each temporary authentication or relay tick. */
    @Synchronized
    fun currentForRuntime(): TemporaryProxyCredentialSnapshot? = runCatching {
        val encrypted = preferences.getString(KEY_ENCRYPTED_RECORD, null)
            ?: return@runCatching null
        val (anchor, record) = decodeEnvelope(open(encrypted))
        val trustedNow = TemporaryLeaseMonotonicClock.observe(
            anchor,
            bootCount(),
            SystemClock.elapsedRealtime(),
        )
        val decision = externalTemporaryCredentialObserve(
            protectedPlaintext = record,
            trustedUnixSeconds = trustedNow,
        )
        // A fresh decision must be durable before admission. Unchanged canonical bytes
        // are already durable; avoid one disk write per client/session liveness check.
        if (!decision.nextState.contentEquals(record)) {
            check(preferences.edit()
                .putString(KEY_ENCRYPTED_RECORD, seal(encodeEnvelope(anchor, decision.nextState)))
                .commit())
        }
        if (!decision.admitted) return@runCatching null
        TemporaryProxyCredentialSnapshot(
            username = decision.username,
            password = decision.password,
            expiresAtUnixSeconds = decision.expiresAtUnixSeconds,
        )
    }.getOrElse {
        // If decrypt/validation/persistence fails, do not resurrect a still-active copy
        // on another relay check or after process restart. Revoke only this Keystore key;
        // the encrypted tombstone stays in prefs so issueOnce cannot silently retry.
        runCatching { keystore().deleteEntry(keyAlias) }
        null
    }

    @Synchronized
    fun temporaryAvailableNow(): Boolean = currentForRuntime() != null

    /** Persist permanent Rust revoke before clearing the live secondary generation. */
    @Synchronized
    fun revoke(): Boolean = runCatching {
        val encrypted = preferences.getString(KEY_ENCRYPTED_RECORD, null)
            ?: return@runCatching true
        val (anchor, record) = decodeEnvelope(open(encrypted))
        val revoked = externalTemporaryCredentialRevoke(record)
        val committed = preferences.edit()
            .putString(KEY_ENCRYPTED_RECORD, seal(encodeEnvelope(anchor, revoked)))
            .commit()
        if (!committed) {
            runCatching { keystore().deleteEntry(keyAlias) }
        }
        committed
    }.getOrElse {
        // Any corruption, write or decryption failure must not leave a previously valid
        // secondary ciphertext restorable after a process restart.
        runCatching { keystore().deleteEntry(keyAlias) }
        false
    }

    private fun bootCount(): Int? = runCatching {
        Settings.Global.getInt(resolver, Settings.Global.BOOT_COUNT)
    }.getOrNull()

    private fun encodeEnvelope(anchor: TemporaryLeaseAnchor, ownerRecord: ByteArray): ByteArray {
        require(ownerRecord.isNotEmpty() && ownerRecord.size <= MAX_RECORD_BYTES)
        return ByteArrayOutputStream().use { bytes ->
            DataOutputStream(bytes).use { output ->
                output.writeInt(ENVELOPE_VERSION)
                output.writeInt(anchor.bootCount)
                output.writeLong(anchor.activatedElapsedMillis)
                output.writeLong(anchor.activatedUnixSeconds)
                output.writeInt(ownerRecord.size)
                output.write(ownerRecord)
            }
            bytes.toByteArray()
        }
    }

    private fun decodeEnvelope(bytes: ByteArray): Pair<TemporaryLeaseAnchor, ByteArray> =
        DataInputStream(ByteArrayInputStream(bytes)).use { input ->
            require(input.readInt() == ENVELOPE_VERSION)
            val anchor = TemporaryLeaseAnchor(
                bootCount = input.readInt(),
                activatedElapsedMillis = input.readLong(),
                activatedUnixSeconds = input.readLong(),
            )
            require(TemporaryLeaseMonotonicClock.issue(
                anchor.bootCount, anchor.activatedElapsedMillis, anchor.activatedUnixSeconds
            ) == anchor)
            val size = input.readInt()
            require(size in 1..MAX_RECORD_BYTES && size == input.available())
            val record = ByteArray(size)
            input.readFully(record)
            anchor to record
        }

    private fun seal(plaintext: ByteArray): String {
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, encryptionKey())
        cipher.updateAAD(ADDITIONAL_DATA)
        val iv = cipher.iv
        require(iv.size == NONCE_LENGTH)
        val packed = byteArrayOf(FORMAT_VERSION) + iv + cipher.doFinal(plaintext)
        return Base64.encodeToString(packed, Base64.NO_WRAP)
    }

    private fun open(encoded: String): ByteArray {
        val packed = Base64.decode(encoded, Base64.NO_WRAP)
        require(Base64.encodeToString(packed, Base64.NO_WRAP) == encoded)
        require(packed.size > 1 + NONCE_LENGTH + 16)
        require(packed[0] == FORMAT_VERSION)
        val key = keystore().getKey(keyAlias, null) as? SecretKey
            ?: error("temporary proxy key unavailable")
        check(key.encoded == null)
        val iv = packed.copyOfRange(1, 1 + NONCE_LENGTH)
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
        cipher.updateAAD(ADDITIONAL_DATA)
        return cipher.doFinal(packed.copyOfRange(1 + NONCE_LENGTH, packed.size))
    }

    private fun encryptionKey(): SecretKey {
        val store = keystore()
        val existing = store.getKey(keyAlias, null) as? SecretKey
        if (existing != null) {
            check(existing.encoded == null)
            return existing
        }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
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

    private companion object {
        const val PREFERENCES_NAME = "temporary-proxy-credential-v1"
        const val KEY_ENCRYPTED_RECORD = "encrypted-owner-record-v1"
        const val KEY_ALIAS = "mish-temporary-proxy-aes-gcm-v1"
        const val CIPHER = "AES/GCM/NoPadding"
        const val NONCE_LENGTH = 12
        const val FORMAT_VERSION: Byte = 1
        const val ENVELOPE_VERSION = 2
        const val MAX_RECORD_BYTES = 4_096
        val ADDITIONAL_DATA = "mish-temporary-proxy-record-v1".toByteArray(Charsets.US_ASCII)
    }
}
