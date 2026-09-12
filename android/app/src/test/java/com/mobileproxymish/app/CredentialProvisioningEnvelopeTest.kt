package com.mobileproxymish.app

import java.nio.charset.StandardCharsets
import java.security.KeyPairGenerator
import java.security.spec.MGF1ParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialProvisioningEnvelopeTest {
    @Test
    fun envelopeBindsExactOwnerVersionAndEphemeralChallenge() {
        val keyPair = rsaKeyPair(3072)
        val snapshot = ExternalProxyCredentialSnapshot(
            version = 7uL,
            credentialId = "external-proxy-v7",
            credentials = ProxyRuntimeCredentials(
                username = "mish-0123456789abcdef0123456789abcdef",
                password = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            ),
        )
        val challenge = ByteArray(32) { index -> index.toByte() }

        val ciphertext = CredentialProvisioningEnvelope.encrypt(
            snapshot = snapshot,
            challenge = challenge,
            clientPublicKeyDer = keyPair.public.encoded,
        )
        val plaintext = decrypt(ciphertext, keyPair.private.encoded)

        assertTrue(plaintext.contains("\"v\":1"))
        assertTrue(plaintext.contains("\"cv\":\"7\""))
        assertTrue(plaintext.contains("\"id\":\"external-proxy-v7\""))
        assertTrue(
            plaintext.contains(
                "\"c\":\"000102030405060708090a0b0c0d0e0f" +
                    "101112131415161718191a1b1c1d1e1f\"",
            ),
        )
        assertTrue(plaintext.contains("\"u\":\"${snapshot.credentials.username}\""))
        assertTrue(plaintext.contains("\"p\":\"${snapshot.credentials.password}\""))
        assertFalse(snapshot.toString().contains(snapshot.credentials.username))
        assertFalse(snapshot.toString().contains(snapshot.credentials.password))

        val unrelatedKey = rsaKeyPair(3072)
        val wrongKeyDecrypt = runCatching {
            decrypt(ciphertext, unrelatedKey.private.encoded)
        }
        assertTrue(wrongKeyDecrypt.isFailure)
    }

    @Test
    fun envelopeRejectsWeakKeyAndMalformedChallenge() {
        val snapshot = ExternalProxyCredentialSnapshot(
            version = 1uL,
            credentialId = "external-proxy-v1",
            credentials = ProxyRuntimeCredentials(
                username = "mish-0123456789abcdef0123456789abcdef",
                password = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
            ),
        )
        val weakKey = rsaKeyPair(2048)
        assertTrue(
            runCatching {
                CredentialProvisioningEnvelope.encrypt(
                    snapshot = snapshot,
                    challenge = ByteArray(32),
                    clientPublicKeyDer = weakKey.public.encoded,
                )
            }.isFailure,
        )

        val strongKey = rsaKeyPair(3072)
        assertTrue(
            runCatching {
                CredentialProvisioningEnvelope.encrypt(
                    snapshot = snapshot,
                    challenge = ByteArray(31),
                    clientPublicKeyDer = strongKey.public.encoded,
                )
            }.isFailure,
        )
    }

    private fun rsaKeyPair(bits: Int) = KeyPairGenerator.getInstance("RSA")
        .apply { initialize(bits) }
        .generateKeyPair()

    private fun decrypt(ciphertext: ByteArray, privateKeyDer: ByteArray): String {
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
        return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }
}
