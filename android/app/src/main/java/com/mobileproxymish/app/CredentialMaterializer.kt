package com.mobileproxymish.app

import com.mobileproxymish.ffi.ExternalCredentialStateView
import com.mobileproxymish.ffi.externalCredentialDerivation
import com.mobileproxymish.ffi.externalCredentialMaterialize
import javax.crypto.SecretKey

/** Derives ephemeral proxy material from the exact Credentials-owner state and Keystore root. */
internal class CredentialMaterializer(
    private val rootEffect: AndroidKeystoreRoot,
) {
    fun materialize(
        state: ExternalCredentialStateView,
        root: SecretKey,
    ): ExternalProxyCredentialSnapshot {
        val derivation = externalCredentialDerivation(
            version = state.version,
            revoked = state.revoked,
        )
        val material = externalCredentialMaterialize(
            version = state.version,
            revoked = state.revoked,
            usernameMac = rootEffect.hmac(root, derivation.usernameContext),
            passwordMac = rootEffect.hmac(root, derivation.passwordContext),
        )
        return ExternalProxyCredentialSnapshot(
            version = state.version,
            credentialId = state.credentialId,
            credentials = ProxyRuntimeCredentials(
                username = material.username,
                password = material.password,
            ),
        )
    }
}
