package com.mobileproxymish.app

import java.security.KeyPairGenerator
import java.security.spec.MGF1ParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.OAEPParameterSpec
import javax.crypto.spec.PSource
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialProvisioningEnvelopeTest {
    @Test
    fun protobufStateRoundTripsCanonicalOwnerMetadata() {
        assertArrayEquals(byteArrayOf(0x08, 0x07), CredentialContractV1.encodeState(7uL, false))
        assertArrayEquals(
            byteArrayOf(0x08, 0x07, 0x10, 0x01),
            CredentialContractV1.encodeState(7uL, true),
        )
        assertEquals(
            CredentialContractV1.State(version = 7uL, revoked = true),
            CredentialContractV1.decodeState(byteArrayOf(0x08, 0x07, 0x10, 0x01)),
        )
        assertTrue(runCatching { CredentialContractV1.decodeState(byteArrayOf(0x10, 0x01)) }.isFailure)
    }

    @Test
    fun envelopeBindsExactOwnerVersionAndEphemeralChallengeAsProtobuf() {
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
        val decoded = CredentialContractV1.decodeProvisioningEnvelope(plaintext)

        assertEquals(1u, decoded.schemaVersion)
        assertEquals(7uL, decoded.credentialVersion)
        assertEquals("external-proxy-v7", decoded.credentialId)
        assertArrayEquals(challenge, decoded.challenge)
        assertEquals(snapshot.credentials.username, decoded.username)
        assertEquals(snapshot.credentials.password, decoded.password)
        assertFalse(snapshot.toString().contains(snapshot.credentials.username))
        assertFalse(snapshot.toString().contains(snapshot.credentials.password))
        assertFalse(String(plaintext, Charsets.UTF_8).startsWith("{"))

        val unrelatedKey = rsaKeyPair(3072)
        val wrongKeyDecrypt = runCatching {
            decrypt(ciphertext, unrelatedKey.private.encoded)
        }
        assertTrue(wrongKeyDecrypt.isFailure)
    }

    @Test
    fun envelopeRejectsWeakKeyMalformedChallengeAndIdentityMismatch() {
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
        assertTrue(
            runCatching {
                CredentialContractV1.encodeProvisioningEnvelope(
                    credentialVersion = 1uL,
                    credentialId = "external-proxy-v2",
                    challenge = ByteArray(32),
                    username = snapshot.credentials.username,
                    password = snapshot.credentials.password,
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
