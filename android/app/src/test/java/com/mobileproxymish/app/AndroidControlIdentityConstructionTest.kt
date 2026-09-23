package com.mobileproxymish.app

import org.junit.Test

class AndroidControlIdentityConstructionTest {
    @Test
    fun constructionDoesNotOpenAndroidKeystore() {
        // Local JVM tests do not provide the AndroidKeyStore provider. Construction succeeding here
        // proves MishApplication.attachBaseContext() cannot trigger platform-keystore work eagerly.
        AndroidControlIdentity()
    }
}
