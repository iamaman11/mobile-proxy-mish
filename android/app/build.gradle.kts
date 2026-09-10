import org.gradle.api.tasks.Delete
import org.gradle.api.tasks.Exec

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

// Resolve task inputs to plain serializable paths during configuration. Gradle task
// actions must not capture Project/script objects when configuration cache is enabled.
val repoRootPath = rootProject.projectDir.parentFile.absolutePath
val generatedUniFfiPath = layout.buildDirectory
    .dir("generated/uniffi/kotlin")
    .get()
    .asFile
    .absolutePath
val generatedJniLibsPath = layout.buildDirectory
    .dir("generated/rust-jni")
    .get()
    .asFile
    .absolutePath

val targetAbi = providers.gradleProperty("mishTargetAbi").orNull
    ?: throw GradleException("mishTargetAbi must be defined in android/gradle.properties.")
if (targetAbi !in setOf("armeabi-v7a", "arm64-v8a")) {
    throw GradleException("mishTargetAbi must be one of the explicitly supported Android ABIs.")
}

val releaseVersionName = providers.environmentVariable("MISH_RELEASE_VERSION_NAME").orNull
val releaseVersionCode = providers.environmentVariable("MISH_RELEASE_VERSION_CODE").orNull?.let { raw ->
    raw.toIntOrNull()?.takeIf { it in 1..2_100_000_000 }
        ?: throw GradleException("MISH_RELEASE_VERSION_CODE must be an integer in 1..2100000000.")
}
if ((releaseVersionName == null) != (releaseVersionCode == null)) {
    throw GradleException("MISH_RELEASE_VERSION_NAME and MISH_RELEASE_VERSION_CODE must be provided together.")
}
if (releaseVersionName != null && !Regex("""\d+\.\d+\.\d+""").matches(releaseVersionName)) {
    throw GradleException("MISH_RELEASE_VERSION_NAME must be a base MAJOR.MINOR.PATCH version.")
}

val releaseStoreFile = providers.environmentVariable("MISH_RELEASE_STORE_FILE").orNull
val releaseStorePassword = providers.environmentVariable("MISH_RELEASE_STORE_PASSWORD").orNull
val releaseKeyAlias = providers.environmentVariable("MISH_RELEASE_KEY_ALIAS").orNull
val releaseKeyPassword = providers.environmentVariable("MISH_RELEASE_KEY_PASSWORD").orNull
val releaseSigningInputs = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)
val releaseSigningRequested = releaseSigningInputs.any { !it.isNullOrBlank() }
if (releaseSigningRequested && releaseSigningInputs.any { it.isNullOrBlank() }) {
    throw GradleException("Release signing inputs must be provided as one complete set.")
}

val hostLibraryName = when {
    System.getProperty("os.name").startsWith("Windows", ignoreCase = true) -> "mish_android_ffi.dll"
    System.getProperty("os.name").startsWith("Mac", ignoreCase = true) -> "libmish_android_ffi.dylib"
    else -> "libmish_android_ffi.so"
}
val hostLibraryPath = "$repoRootPath/target/debug/$hostLibraryName"

val cleanGeneratedUniFfi = tasks.register<Delete>("cleanGeneratedUniFfi") {
    delete(generatedUniFfiPath)
}

val buildHostUniFfi = tasks.register<Exec>("buildHostUniFfi") {
    workingDir(repoRootPath)
    commandLine("cargo", "build", "-p", "mish-android-ffi", "--locked")
}

val generateUniFfiBindings = tasks.register<Exec>("generateUniFfiBindings") {
    dependsOn(cleanGeneratedUniFfi, buildHostUniFfi)
    workingDir(repoRootPath)
    // UniFFI 0.32 resolves the crate-local crates/android-ffi/uniffi.toml via cargo
    // metadata. --config is reserved for the newer global configuration format.
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
        hostLibraryPath,
        "--language",
        "kotlin",
        "--out-dir",
        generatedUniFfiPath,
        "--no-format",
    )
}

val cleanGeneratedJniLibs = tasks.register<Delete>("cleanGeneratedJniLibs") {
    delete(generatedJniLibsPath)
}

val buildAndroidUniFfi = tasks.register<Exec>("buildAndroidUniFfi") {
    dependsOn(generateUniFfiBindings, cleanGeneratedJniLibs)
    workingDir(repoRootPath)
    commandLine(
        "cargo",
        "ndk",
        "-P",
        "23",
        "-t",
        targetAbi,
        "-o",
        generatedJniLibsPath,
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
    buildToolsVersion = "36.0.0"
    ndkVersion = "29.0.14206865"

    // Ordinary CI keeps the debug instrumentation variant. Restricted release builds
    // that provide a complete signing configuration bind androidTest to the release
    // variant so the E3 harness can target the exact signed product APK.
    testBuildType = if (releaseSigningRequested) "release" else "debug"

    defaultConfig {
        applicationId = "com.mobileproxymish.app"
        minSdk = 23
        targetSdk = 36
        versionCode = releaseVersionCode ?: 1
        versionName = releaseVersionName ?: "0.1.0-dev"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += targetAbi
        }
    }

    signingConfigs {
        if (releaseSigningRequested) {
            create("release") {
                storeFile = file(requireNotNull(releaseStoreFile))
                storePassword = requireNotNull(releaseStorePassword)
                keyAlias = requireNotNull(releaseKeyAlias)
                keyPassword = requireNotNull(releaseKeyPassword)
            }
        }
    }

    buildTypes {
        getByName("release") {
            if (releaseSigningRequested) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    buildFeatures {
        compose = true
    }

    // AGP 9 built-in Kotlin only recognizes extra Kotlin directories through the
    // AndroidSourceSet.kotlin collection; Java source wiring is intentionally not used.
    sourceSets.getByName("main") {
        kotlin.directories += generatedUniFfiPath
        jniLibs.directories += generatedJniLibsPath
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

    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
}
