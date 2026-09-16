package com.mobileproxymish.app

import android.content.Context
import android.util.Base64
import com.mobileproxymish.ffi.ExternalCredentialStateView
import com.mobileproxymish.ffi.externalCredentialInitialState
import com.mobileproxymish.ffi.externalCredentialRestore

/**
 * Durable non-secret credential metadata effect.
 *
 * SharedPreferences stores one canonical protobuf blob. Legacy scalar keys exist only as a bounded
 * migration input and are removed atomically when current metadata is persisted.
 */
internal class CredentialMetadataStore(
    context: Context,
) {
    private val preferences = context.applicationContext.getSharedPreferences(
        PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    /** Read-only observation. Never creates a key, initializes metadata or performs migration. */
    fun existingForObservation(rootExists: Boolean): ExternalCredentialStateView? {
        val encodedState = preferences.getString(KEY_STATE_PROTOBUF, null)
        val hasLegacyVersion = preferences.contains(LEGACY_KEY_VERSION)
        val hasLegacyRevoked = preferences.contains(LEGACY_KEY_REVOKED)

        if (encodedState != null) {
            if (hasLegacyVersion || hasLegacyRevoked || !rootExists) return null
            return restoreState(decodeCanonicalBase64(encodedState))
        }

        if (hasLegacyVersion != hasLegacyRevoked || !hasLegacyVersion || !rootExists) return null
        val version = preferences.getString(LEGACY_KEY_VERSION, null)?.toULongOrNull() ?: return null
        return externalCredentialRestore(
            version = version,
            revoked = preferences.getBoolean(LEGACY_KEY_REVOKED, false),
        )
    }

    /**
     * Resolves owner metadata against the physical root existence proof. The caller owns root-key
     * creation/deletion; this class owns only metadata schema, migration and persistence.
     */
    fun loadOrInitialize(
        rootExists: Boolean,
        createRoot: () -> Unit,
        deleteRoot: () -> Unit,
    ): ExternalCredentialStateView {
        val encodedState = preferences.getString(KEY_STATE_PROTOBUF, null)
        val hasLegacyVersion = preferences.contains(LEGACY_KEY_VERSION)
        val hasLegacyRevoked = preferences.contains(LEGACY_KEY_REVOKED)

        if (encodedState != null) {
            check(!hasLegacyVersion && !hasLegacyRevoked) {
                "external credential metadata contains mixed protobuf and legacy schemas"
            }
            check(rootExists) {
                "external credential root missing for persisted owner state"
            }
            return restoreState(decodeCanonicalBase64(encodedState))
        }

        check(hasLegacyVersion == hasLegacyRevoked) {
            "legacy external credential owner metadata is incomplete"
        }
        if (hasLegacyVersion) {
            check(rootExists) {
                "external credential root missing for legacy owner state"
            }
            val version = preferences.getString(LEGACY_KEY_VERSION, null)?.toULongOrNull()
                ?: error("legacy external credential version is invalid")
            val state = externalCredentialRestore(
                version = version,
                revoked = preferences.getBoolean(LEGACY_KEY_REVOKED, false),
            )
            check(persist(state)) { "failed to migrate credential metadata to protobuf" }
            return state
        }

        check(!rootExists) {
            "external credential root exists without owner metadata"
        }
        createRoot()
        val initial = externalCredentialInitialState()
        if (!persist(initial)) {
            runCatching(deleteRoot)
            error("failed to persist initial credential metadata")
        }
        return initial
    }

    fun persist(state: ExternalCredentialStateView): Boolean {
        val encoded = CredentialContractV1.encodeState(state.version, state.revoked)
        val base64 = Base64.encodeToString(encoded, Base64.NO_WRAP)
        return preferences.edit()
            .putString(KEY_STATE_PROTOBUF, base64)
            .remove(LEGACY_KEY_VERSION)
            .remove(LEGACY_KEY_REVOKED)
            .commit()
    }

    private fun restoreState(encoded: ByteArray): ExternalCredentialStateView {
        val decoded = CredentialContractV1.decodeState(encoded)
        return externalCredentialRestore(
            version = decoded.version,
            revoked = decoded.revoked,
        )
    }

    private fun decodeCanonicalBase64(encoded: String): ByteArray {
        val decoded = Base64.decode(encoded, Base64.NO_WRAP)
        check(Base64.encodeToString(decoded, Base64.NO_WRAP) == encoded) {
            "external credential protobuf transport encoding is non-canonical"
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
