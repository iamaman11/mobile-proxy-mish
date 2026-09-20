package com.mobileproxymish.app

import java.security.KeyPairGenerator
import java.security.spec.MGF1ParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialProvisioningEnvelopeTest {
    @Test
    fun platformRsaEffectRoundTripsOpaqueOwnerPlaintext() {
        val keyPair = rsaKeyPair(3072)
        val plaintext = ByteArray(128) { index -> (index and 0xff).toByte() }

        val ciphertext = CredentialProvisioningEnvelope.encryptOwnerPlaintextForPlatformTest(
            plaintext = plaintext,
            clientPublicKeyDer = keyPair.public.encoded,
        )
        assertArrayEquals(plaintext, decrypt(ciphertext, keyPair.private.encoded))

        val unrelatedKey = rsaKeyPair(3072)
        assertTrue(
            runCatching {
                decrypt(ciphertext, unrelatedKey.private.encoded)
            }.isFailure,
        )
    }

    @Test
    fun platformRsaEffectRejectsWeakKeyAndOversizedPlaintext() {
        val weakKey = rsaKeyPair(2048)
        assertTrue(
            runCatching {
                CredentialProvisioningEnvelope.encryptOwnerPlaintextForPlatformTest(
                    plaintext = ByteArray(64),
                    clientPublicKeyDer = weakKey.public.encoded,
                )
            }.isFailure,
        )

        val strongKey = rsaKeyPair(3072)
        assertTrue(
            runCatching {
                CredentialProvisioningEnvelope.encryptOwnerPlaintextForPlatformTest(
                    plaintext = ByteArray(301),
                    clientPublicKeyDer = strongKey.public.encoded,
                )
            }.isFailure,
        )
    }

    private fun rsaKeyPair(bits: Int) = KeyPairGenerator.getInstance("RSA")
        .apply { initialize(bits) }
        .generateKeyPair()

    private fun decrypt(ciphertext: ByteArray, privateKeyDer: ByteArray): ByteArray {
        val privateKey = java.security.KeyFactory.getInstance("RSA")
            .generatePrivate(java.security.spec.PKCS8EncodedKeySpec(privateKeyDer))
        val cipher = Cipher.getInstance("RSA/ECB/OAEPWithSHA-256AndMGF1Padding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            privateKey,
            OAEPParameterSpec(
                "SHA-256",
                "MGF1",
                MGF1ParameterSpec("SHA-256"),
                PSource.PSpecified.DEFAULT,
            ),
        )
        return cipher.doFinal(ciphertext)
    }
}
