package com.mobileproxymish.app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * Dedicated non-exportable control-plane device identity.
 *
 * This key is intentionally unrelated to the external proxy credential root. Android Keystore owns
 * private-key custody only; Rust owns the signed message and authentication protocol.
 */
internal class AndroidControlIdentity {
    private val keyStore = KeyStore.getInstance(ANDROID_KEY_STORE).apply { load(null) }

    @Synchronized
    fun publicKeySpki(): ByteArray {
        ensureKey()
        val certificate = checkNotNull(keyStore.getCertificate(KEY_ALIAS)) {
            "control identity certificate is unavailable"
        }
        val publicKey = certificate.publicKey
        check(publicKey.algorithm.equals(KeyProperties.KEY_ALGORITHM_EC, ignoreCase = true)) {
            "control identity is not EC"
        }
        return publicKey.encoded.copyOf()
    }

    @Synchronized
    fun sign(payload: ByteArray): ByteArray {
        require(payload.isNotEmpty() && payload.size <= MAX_SIGNED_PAYLOAD_BYTES) {
            "control auth payload is outside the bounded size"
        }
        ensureKey()
        val privateKey = keyStore.getKey(KEY_ALIAS, null) as? PrivateKey
            ?: error("control identity private key is unavailable")
        check(privateKey.algorithm.equals(KeyProperties.KEY_ALGORITHM_EC, ignoreCase = true)) {
            "control identity private key is not EC"
        }

        return Signature.getInstance(SIGNATURE_ALGORITHM).run {
            initSign(privateKey)
            update(payload)
            sign()
        }
    }

    private fun ensureKey() {
        if (keyStore.containsAlias(KEY_ALIAS)) return
        val generator = KeyPairGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_EC,
            ANDROID_KEY_STORE,
        )
        generator.initialize(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_SIGN,
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec(CURVE))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        generator.generateKeyPair()
    }

    private companion object {
        const val ANDROID_KEY_STORE = "AndroidKeyStore"
        const val KEY_ALIAS = "mobile-proxy-mish.control-identity.v1"
        const val CURVE = "secp256r1"
        const val SIGNATURE_ALGORITHM = "SHA256withECDSA"
        const val MAX_SIGNED_PAYLOAD_BYTES = 512
    }
}
