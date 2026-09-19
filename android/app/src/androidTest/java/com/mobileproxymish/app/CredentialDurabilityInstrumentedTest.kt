package com.mobileproxymish.app

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CredentialDurabilityInstrumentedTest {
    @Test
    fun currentCredentialPersistsAcrossStoreReconstructionAndRotatesOnlyExplicitly() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val suffix = System.nanoTime().toString()
        val preferencesName = "external-proxy-credential-e-test-$suffix"
        val keystoreAlias = "mobile-proxy-mish.external-proxy-e-test.$suffix"
        val root = AndroidKeystoreRoot(keystoreAlias)

        context.getSharedPreferences(preferencesName, 0).edit().clear().commit()
        runCatching(root::delete)

        try {
            val firstStore = ExternalProxyCredentialStore(
                context = context,
                preferencesName = preferencesName,
                keystoreAlias = keystoreAlias,
            )
            val first = requireNotNull(firstStore.currentCredentialForRuntime())

            val reconstructedStore = ExternalProxyCredentialStore(
                context = context,
                preferencesName = preferencesName,
                keystoreAlias = keystoreAlias,
            )
            val revealed = requireNotNull(reconstructedStore.revealCurrentCredential())
            assertEquals(first.version, revealed.version)
            assertEquals(first.credentials.username, revealed.credentials.username)
            assertEquals(first.credentials.password, revealed.credentials.password)

            val runtimeReadAgain = requireNotNull(reconstructedStore.currentCredentialForRuntime())
            assertEquals(first.version, runtimeReadAgain.version)
            assertEquals(first.credentials.username, runtimeReadAgain.credentials.username)
            assertEquals(first.credentials.password, runtimeReadAgain.credentials.password)

            assertTrue(reconstructedStore.rotateWhileStopped())

            val afterRotationStore = ExternalProxyCredentialStore(
                context = context,
                preferencesName = preferencesName,
                keystoreAlias = keystoreAlias,
            )
            val rotated = requireNotNull(afterRotationStore.revealCurrentCredential())
            assertEquals(first.version + 1uL, rotated.version)
            assertNotEquals(first.credentials.username, rotated.credentials.username)
            assertNotEquals(first.credentials.password, rotated.credentials.password)
        } finally {
            context.getSharedPreferences(preferencesName, 0).edit().clear().commit()
            runCatching(root::delete)
        }
    }
}
