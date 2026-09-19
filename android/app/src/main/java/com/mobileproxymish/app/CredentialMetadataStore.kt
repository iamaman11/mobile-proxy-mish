package com.mobileproxymish.app

import android.content.Context
import android.util.Base64

/** Raw Android persistence facts. The byte payload is opaque to Kotlin. */
internal data class RawCredentialPersistence(
    val canonicalState: ByteArray?,
    val legacyVersion: String?,
    val legacyRevoked: Boolean?,
)

/**
 * Android SharedPreferences byte-storage adapter for the Rust Credentials natural owner.
 *
 * Kotlin owns only opaque transport storage. It does not decode credential protobuf, decide
 * canonical-vs-legacy meaning, validate versions, or choose migration/initialization policy.
 */
internal class CredentialMetadataStore(
    context: Context,
    preferencesName: String = PREFERENCES_NAME,
) {
    private val preferences = context.applicationContext.getSharedPreferences(
        preferencesName,
        Context.MODE_PRIVATE,
    )

    fun readRaw(): RawCredentialPersistence {
        val canonical = preferences.getString(KEY_STATE_PROTOBUF, null)?.let(::decodeOpaqueBase64)
        val legacyVersion = if (preferences.contains(LEGACY_KEY_VERSION)) {
            preferences.getString(LEGACY_KEY_VERSION, null)
        } else {
            null
        }
        val legacyRevoked = if (preferences.contains(LEGACY_KEY_REVOKED)) {
            preferences.getBoolean(LEGACY_KEY_REVOKED, false)
        } else {
            null
        }
        return RawCredentialPersistence(
            canonicalState = canonical,
            legacyVersion = legacyVersion,
            legacyRevoked = legacyRevoked,
        )
    }

    fun persistCanonical(encoded: ByteArray): Boolean {
        val base64 = Base64.encodeToString(encoded, Base64.NO_WRAP)
        return preferences.edit()
            .putString(KEY_STATE_PROTOBUF, base64)
            .remove(LEGACY_KEY_VERSION)
            .remove(LEGACY_KEY_REVOKED)
            .commit()
    }

    private fun decodeOpaqueBase64(encoded: String): ByteArray {
        val decoded = Base64.decode(encoded, Base64.NO_WRAP)
        check(Base64.encodeToString(decoded, Base64.NO_WRAP) == encoded) {
            "external credential opaque state transport encoding is invalid"
        }
        return decoded
    }

    internal companion object {
        const val PREFERENCES_NAME = "external-proxy-credential-state"
        const val KEY_STATE_PROTOBUF = "state_pb_b64_v1"
        const val LEGACY_KEY_VERSION = "version"
        const val LEGACY_KEY_REVOKED = "revoked"
    }
}
