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
val generatedUniFfiFile = "$generatedUniFfiPath/com/mobileproxymish/ffi/mish_android_ffi.kt"
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
val generatedAndroidUniFfiFile = "$generatedJniLibsPath/$targetAbi/libmish_android_ffi.so"

// DEVICE-1 is the fixed product appliance target: Android 11 / API 30.
// Keep the Android package floor and Rust/NDK platform floor on one authority.
val androidMinSdk = 30

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
val rustWorkspaceInputs = files(
    "$repoRootPath/Cargo.toml",
    "$repoRootPath/Cargo.lock",
    "$repoRootPath/rust-toolchain.toml",
    "$repoRootPath/crates",
)

val buildHostUniFfi = tasks.register<Exec>("buildHostUniFfi") {
    inputs.files(rustWorkspaceInputs)
    inputs.property("rustToolchain", "1.98.1")
    outputs.file(hostLibraryPath)
    workingDir(repoRootPath)
    commandLine("cargo", "build", "-p", "mish-android-ffi", "--locked")
}

val generateUniFfiBindings = tasks.register<Exec>("generateUniFfiBindings") {
    dependsOn(buildHostUniFfi)
    inputs.files(rustWorkspaceInputs)
    inputs.file(hostLibraryPath)
    inputs.file("$repoRootPath/crates/android-ffi/uniffi.toml")
    inputs.property("language", "kotlin")
    outputs.file(generatedUniFfiFile)
    workingDir(repoRootPath)
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

val buildAndroidUniFfi = tasks.register<Exec>("buildAndroidUniFfi") {
    inputs.files(rustWorkspaceInputs)
    inputs.property("rustToolchain", "1.98.1")
    inputs.property("cargoNdkVersion", "4.1.2")
    inputs.property("androidNdkVersion", "29.0.14206865")
    inputs.property("androidMinSdk", androidMinSdk)
    inputs.property("mishTargetAbi", targetAbi)
    outputs.file(generatedAndroidUniFfiFile)
    workingDir(repoRootPath)
    commandLine(
        "cargo",
        "ndk",
        "-P",
        androidMinSdk.toString(),
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

    testBuildType = if (releaseSigningRequested) "release" else "debug"

    defaultConfig {
        applicationId = "com.mobileproxymish.app"
        minSdk = androidMinSdk
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
        getByName("debug") {
            // Diagnostic/development bytes must never be package-compatible with the production
            // appliance. This keeps the release UID and its device/root authorization boundary
            // stable across local debug installs.
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        getByName("release") {
            if (releaseSigningRequested) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    buildFeatures {
        compose = true
        // The variant-aware package-identity regression reads BuildConfig.APPLICATION_ID for
        // both debug and release. Keep generation explicit instead of relying on AGP defaults.
        buildConfig = true
    }

    sourceSets.getByName("main") {
        kotlin.directories += generatedUniFfiPath
        jniLibs.directories += generatedJniLibsPath
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// Static Android work needs only the generated Kotlin FFI contract. Android native artifacts are
// package inputs, not compile/lint prerequisites. Keep the two paths independent so cheap failures
// surface without cargo-ndk or the Android NDK.
tasks.matching {
    (it.name.startsWith("compile") && it.name.endsWith("Kotlin")) || it.name.startsWith("lint")
}.configureEach {
    dependsOn(generateUniFfiBindings)
}

// AGP consumes the generated JNI directory in its native merge tasks. Attach the Rust producer at
// that exact boundary instead of globally to preBuild, so Kotlin/static work remains native-free.
tasks.matching {
    it.name.startsWith("merge") &&
        (it.name.endsWith("NativeLibs") || it.name.endsWith("JniLibFolders"))
}.configureEach {
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
    testImplementation("org.json:json:20240303")

    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation(composeBom)
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
