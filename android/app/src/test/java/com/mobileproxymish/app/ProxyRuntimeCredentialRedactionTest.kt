package com.mobileproxymish.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Android retains only the presentation/redaction contract for ephemeral proxy material.
 * Runtime lifecycle and exact generation cleanup are Rust-owned and tested in mish-runtime.
 */
class ProxyRuntimeCredentialRedactionTest {
    @Test
    fun externalCredentialMaterialIsRedactedFromStringProjection() {
        val credentials = ProxyRuntimeCredentials(
            username = "external-user-secret",
            password = "external-password-secret",
        )

        assertEquals("external-user-secret", credentials.username)
        assertEquals("external-password-secret", credentials.password)
        assertFalse(credentials.toString().contains(credentials.username))
        assertFalse(credentials.toString().contains(credentials.password))

        val reveal = CredentialRevealUiState.Revealed(
            version = 9uL,
            username = credentials.username,
            password = credentials.password,
        )
        assertFalse(reveal.toString().contains(credentials.username))
        assertFalse(reveal.toString().contains(credentials.password))
    }
}
