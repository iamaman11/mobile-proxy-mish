buildscript {
    dependencies {
        // AGP 9 built-in Kotlin uses KGP at runtime. Pin the higher supported KGP
        // explicitly so the Compose compiler plugin and Kotlin compiler stay aligned.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.20")
    }
}

plugins {
    id("com.android.application") version "9.3.1" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.20" apply false
}
