import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val repoRoot = rootProject.projectDir.parentFile
val generatedUniFfiDir = layout.buildDirectory.dir("generated/uniffi/kotlin").get().asFile
val generatedJniLibsDir = layout.buildDirectory.dir("generated/rust-jni").get().asFile

val hostLibraryName = when {
    System.getProperty("os.name").startsWith("Windows", ignoreCase = true) -> "mish_android_ffi.dll"
    System.getProperty("os.name").startsWith("Mac", ignoreCase = true) -> "libmish_android_ffi.dylib"
    else -> "libmish_android_ffi.so"
}
val hostLibrary = repoRoot.resolve("target/debug/$hostLibraryName")

val buildHostUniFfi = tasks.register<Exec>("buildHostUniFfi") {
    workingDir(repoRoot)
    commandLine("cargo", "build", "-p", "mish-android-ffi", "--locked")
}

val generateUniFfiBindings = tasks.register<Exec>("generateUniFfiBindings") {
    dependsOn(buildHostUniFfi)
    workingDir(repoRoot)
    doFirst {
        project.delete(generatedUniFfiDir)
    }
    commandLine(
        "cargo",
        "run",
        "-p",
        "mish-android-ffi",
        "--bin",
        "uniffi-bindgen",
        "--locked",
        "--",
        "generate",
        "--library",
        hostLibrary.absolutePath,
        "--language",
        "kotlin",
        "--out-dir",
        generatedUniFfiDir.absolutePath,
        "--no-format",
    )
}

val buildAndroidUniFfi = tasks.register<Exec>("buildAndroidUniFfi") {
    dependsOn(generateUniFfiBindings)
    workingDir(repoRoot)
    doFirst {
        check(!System.getenv("ANDROID_NDK_HOME").isNullOrBlank()) {
            "ANDROID_NDK_HOME must point to the pinned Android NDK before building the Rust Android library"
        }
        project.delete(generatedJniLibsDir)
    }
    commandLine(
        "cargo",
        "ndk",
        "-p",
        "23",
        "-t",
        "arm64-v8a",
        "-o",
        generatedJniLibsDir.absolutePath,
        "build",
        "-p",
        "mish-android-ffi",
        "--release",
        "--locked",
    )
}

android {
    namespace = "com.mobileproxymish.app"
    compileSdk = 37
    ndkVersion = "29.0.14206865"

    defaultConfig {
        applicationId = "com.mobileproxymish.app"
        minSdk = 23
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0-dev"

        ndk {
            abiFilters += "arm64-v8a"
        }
    }

    buildFeatures {
        compose = true
    }

    sourceSets.getByName("main") {
        java.srcDir(generatedUniFfiDir)
        jniLibs.srcDir(generatedJniLibsDir)
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

tasks.named("preBuild") {
    dependsOn(buildAndroidUniFfi)
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2026.08.00")
    implementation(composeBom)

    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.10.0")
    implementation("net.java.dev.jna:jna:5.19.1@aar")

    testImplementation("junit:junit:4.13.2")
}
