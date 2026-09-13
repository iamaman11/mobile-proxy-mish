package com.mobileproxymish.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Base64
import java.security.KeyFactory
import java.security.interfaces.RSAPublicKey
import java.security.spec.MGF1ParameterSpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource

/**
 * One-purpose ADB provisioning endpoint for the durable external proxy credential.
 *
 * The manifest protects this exported receiver with android.permission.DUMP. Android shell holds
 * that development-tool permission, while ordinary third-party applications do not. There is no
 * intent filter: provisioning must name this component explicitly through an already-authorized
 * ADB shell. The only successful response is RSA-OAEP ciphertext for the caller's ephemeral key.
 */
class CredentialProvisioningReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (!isOrderedBroadcast) return
        if (intent.action != ACTION_PROVISION) {
            fail(RESULT_INVALID_REQUEST)
            return
        }

        val publicKeyDer = intent.getStringExtra(EXTRA_CLIENT_PUBLIC_KEY)
            ?.let(::decodeCanonicalBase64)
        val challenge = intent.getStringExtra(EXTRA_CHALLENGE_HEX)
            ?.let(::decodeCanonicalChallenge)
        if (publicKeyDer == null || challenge == null) {
            fail(RESULT_INVALID_REQUEST)
            return
        }

        val app = context.applicationContext as? MishApplication
        val snapshot = app?.runtimeController?.currentExternalCredentialProvisioningSnapshot()
        if (snapshot == null) {
            fail(RESULT_CREDENTIAL_UNAVAILABLE)
            return
        }

        val ciphertext = runCatching {
            CredentialProvisioningEnvelope.encrypt(
                snapshot = snapshot,
                challenge = challenge,
                clientPublicKeyDer = publicKeyDer,
            )
        }.getOrNull()
        if (ciphertext == null) {
            fail(RESULT_ENCRYPTION_FAILED)
            return
        }

        setResult(
            RESULT_OK,
            Base64.encodeToString(ciphertext, Base64.NO_WRAP),
            null,
        )
    }

    private fun fail(code: Int) {
        setResult(code, null, null)
    }

    private fun decodeCanonicalBase64(encoded: String): ByteArray? = runCatching {
        val decoded = Base64.decode(encoded, Base64.NO_WRAP)
        check(Base64.encodeToString(decoded, Base64.NO_WRAP) == encoded)
        decoded
    }.getOrNull()

    private fun decodeCanonicalChallenge(encoded: String): ByteArray? {
        if (!CHALLENGE_PATTERN.matches(encoded)) return null
        return ByteArray(CHALLENGE_BYTES) { index ->
            encoded.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
    }

    companion object {
        const val ACTION_PROVISION =
            "com.mobileproxymish.app.action.PROVISION_EXTERNAL_PROXY_V1"
        const val EXTRA_CLIENT_PUBLIC_KEY = "client_public_key_spki_b64"
        const val EXTRA_CHALLENGE_HEX = "challenge_hex"

        const val RESULT_OK = 1
        const val RESULT_INVALID_REQUEST = 10
        const val RESULT_CREDENTIAL_UNAVAILABLE = 11
        const val RESULT_ENCRYPTION_FAILED = 12

        private const val CHALLENGE_BYTES = 32
        private val CHALLENGE_PATTERN = Regex("[0-9a-f]{64}")
    }
}

/** Pure crypto/envelope boundary shared by direct JVM tests and the Android receiver. */
internal object CredentialProvisioningEnvelope {
    private const val MIN_RSA_BITS = 3072
    private const val CHALLENGE_BYTES = 32
    private const val MAX_RSA_3072_OAEP_SHA256_PLAINTEXT = 318
    private const val PLAINTEXT_HEADROOM_BYTES = 18

    fun encrypt(
        snapshot: ExternalProxyCredentialSnapshot,
        challenge: ByteArray,
        clientPublicKeyDer: ByteArray,
    ): ByteArray {
        require(challenge.size == CHALLENGE_BYTES) { "provisioning challenge must be 256-bit" }
        val publicKey = KeyFactory.getInstance("RSA")
            .generatePublic(X509EncodedKeySpec(clientPublicKeyDer)) as? RSAPublicKey
            ?: error("provisioning key is not RSA")
        require(publicKey.modulus.bitLength() >= MIN_RSA_BITS) {
            "provisioning RSA key is below the minimum size"
        }

        val plaintext = CredentialContractV1.encodeProvisioningEnvelope(
            credentialVersion = snapshot.version,
            credentialId = snapshot.credentialId,
            challenge = challenge,
            username = snapshot.credentials.username,
            password = snapshot.credentials.password,
        )
        require(
            plaintext.size <=
                MAX_RSA_3072_OAEP_SHA256_PLAINTEXT - PLAINTEXT_HEADROOM_BYTES,
        ) { "provisioning protobuf exceeds bounded RSA envelope" }

        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        val parameters = OAEPParameterSpec(
            "SHA-256",
            "MGF1",
            MGF1ParameterSpec("SHA-256"),
            PSource.PSpecified.DEFAULT,
        )
        cipher.init(Cipher.ENCRYPT_MODE, publicKey, parameters)
        return cipher.doFinal(plaintext)
    }
}
