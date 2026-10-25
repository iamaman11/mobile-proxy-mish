package com.mobileproxymish.app

import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyStore

/** Real Android Keystore and actual Rust UniFFI, with a test-only alias and private preferences.
 * These tests can never modify the installed primary credentials or a real temporary grant.
 */
class TemporaryProxyCredentialDurabilityInstrumentedTest {
    @Test
    fun oneProtectedSecondaryPersistsAcrossStoreReconstructionAndRevokesPermanently() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val suffix = System.nanoTime().toString()
        val preferencesName = "temporary-proxy-credential-test-$suffix"
        val keyAlias = "mish-temporary-proxy-test-$suffix"
        val preferences = context.getSharedPreferences(preferencesName, 0)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        try {
            assertTrue(preferences.edit().clear().commit())
            val store = TemporaryProxyCredentialStore(context, preferencesName, keyAlias)
            assertFalse(store.hasBeenIssued())
            assertTrue(store.issueOnce("synthetic-local-user", "synthetic-local-password"))
            assertTrue(store.hasBeenIssued())
            val first = store.currentForRuntime()
            assertNotNull(first)
            assertEquals("synthetic-local-user", first!!.username)
            assertEquals("synthetic-local-password", first.password)

            val restored = TemporaryProxyCredentialStore(context, preferencesName, keyAlias)
            val resumed = restored.currentForRuntime()
            assertNotNull(resumed)
            assertEquals(first.expiresAtUnixSeconds, resumed!!.expiresAtUnixSeconds)
            assertEquals(first.username, resumed.username)
            assertEquals(first.password, resumed.password)

            assertTrue(restored.revoke())
            assertNull(restored.currentForRuntime())
            assertFalse(restored.issueOnce("replacement", "replacement-secret"))
            assertNull(TemporaryProxyCredentialStore(
                context, preferencesName, keyAlias
            ).currentForRuntime())
        } finally {
            preferences.edit().clear().commit()
            runCatching { keyStore.deleteEntry(keyAlias) }
        }
    }
}
