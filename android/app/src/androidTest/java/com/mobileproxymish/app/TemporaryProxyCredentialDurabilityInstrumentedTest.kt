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
            val terminalCiphertext = preferences.getString("encrypted-owner-record-v1", null)
            assertNotNull(terminalCiphertext)
            assertNull(restored.currentForRuntime())
            assertNull(restored.currentForRuntime())
            // Repeated negative checks must not rewrite a durable terminal record.
            assertEquals(terminalCiphertext,
                preferences.getString("encrypted-owner-record-v1", null))
            assertFalse(restored.issueOnce("replacement", "replacement-secret"))
            assertNull(TemporaryProxyCredentialStore(
                context, preferencesName, keyAlias
            ).currentForRuntime())
        } finally {
            preferences.edit().clear().commit()
            runCatching { keyStore.deleteEntry(keyAlias) }
        }
    }

    @Test
    fun independentTestAliasesRemainIsolatedAcrossReconstructionAndRevoke() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val suffix = System.nanoTime().toString()
        val prefsA = "temporary-proxy-alias-a-$suffix"
        val prefsB = "temporary-proxy-alias-b-$suffix"
        val aliasA = "mish-temporary-alias-a-$suffix"
        val aliasB = "mish-temporary-alias-b-$suffix"
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        try {
            assertTrue(context.getSharedPreferences(prefsA, 0).edit().clear().commit())
            assertTrue(context.getSharedPreferences(prefsB, 0).edit().clear().commit())
            val first = TemporaryProxyCredentialStore(context, prefsA, aliasA)
            val second = TemporaryProxyCredentialStore(context, prefsB, aliasB)
            assertTrue(first.issueOnce("synthetic-alias-a", "synthetic-password-a"))
            assertTrue(second.issueOnce("synthetic-alias-b", "synthetic-password-b"))

            assertEquals("synthetic-alias-a",
                TemporaryProxyCredentialStore(context, prefsA, aliasA).currentForRuntime()?.username)
            assertEquals("synthetic-alias-b",
                TemporaryProxyCredentialStore(context, prefsB, aliasB).currentForRuntime()?.username)

            assertTrue(first.revoke())
            assertNull(TemporaryProxyCredentialStore(context, prefsA, aliasA).currentForRuntime())
            assertEquals("synthetic-alias-b",
                TemporaryProxyCredentialStore(context, prefsB, aliasB).currentForRuntime()?.username)
        } finally {
            context.getSharedPreferences(prefsA, 0).edit().clear().commit()
            context.getSharedPreferences(prefsB, 0).edit().clear().commit()
            runCatching { keyStore.deleteEntry(aliasA) }
            runCatching { keyStore.deleteEntry(aliasB) }
        }
    }


    @Test
    fun corruptProtectedSecondaryFailsClosedAndCannotBeReissued() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val suffix = System.nanoTime().toString()
        val prefsName = "temporary-proxy-corrupt-$suffix"
        val alias = "mish-temporary-corrupt-$suffix"
        val preferences = context.getSharedPreferences(prefsName, 0)
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        try {
            assertTrue(preferences.edit().clear().commit())
            val store = TemporaryProxyCredentialStore(context, prefsName, alias)
            assertTrue(store.issueOnce("synthetic-corrupt", "synthetic-secret"))
            assertNotNull(store.currentForRuntime())
            assertTrue(keyStore.containsAlias(alias))
            // Simulate tampered preferences in a disposable test-only record.
            assertTrue(preferences.edit()
                .putString("encrypted-owner-record-v1", "invalid-ciphertext")
                .commit())
            assertNull(store.currentForRuntime())
            assertFalse(keyStore.containsAlias(alias))
            assertFalse(store.issueOnce("second", "second-secret"))
            assertNull(TemporaryProxyCredentialStore(context, prefsName, alias).currentForRuntime())
        } finally {
            preferences.edit().clear().commit()
            runCatching { keyStore.deleteEntry(alias) }
        }
    }
}
