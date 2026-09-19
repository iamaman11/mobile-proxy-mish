package com.mobileproxymish.app

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

/** Physical Android Keystore effect for the external-proxy credential root. */
internal class AndroidKeystoreRoot(
    private val keyAlias: String = ROOT_KEY_ALIAS,
) {
    fun exists(): Boolean = keyStore().containsAlias(keyAlias)

    fun load(): SecretKey {
        val key = keyStore().getKey(keyAlias, null) as? SecretKey
            ?: error("Android Keystore external credential root has wrong key type")
        check(key.encoded == null) {
            "Android Keystore HMAC root unexpectedly exportable"
        }
        return key
    }

    fun generate(): SecretKey {
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_HMAC_SHA256,
            ANDROID_KEYSTORE,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
                KeyProperties.PURPOSE_SIGN,
            )
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setKeySize(ROOT_KEY_BITS)
                .setUserAuthenticationRequired(false)
                .build(),
        )
        return generator.generateKey().also { key ->
            check(key.encoded == null) {
                "Android Keystore HMAC root unexpectedly exportable"
            }
        }
    }

    fun delete() {
        keyStore().deleteEntry(keyAlias)
    }

    fun hmac(key: SecretKey, context: ByteArray): ByteArray = Mac
        .getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256)
        .apply { init(key) }
        .doFinal(context)

    private fun keyStore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private companion object {
        const val ANDROID_KEYSTORE = "AndroidKeyStore"
        const val ROOT_KEY_ALIAS = "mobile-proxy-mish.external-proxy-root.v1"
        const val ROOT_KEY_BITS = 256
    }
}
