import java.util.Properties

// ── Versioning ───────────────────────────────────────────────────────────────
//
// Read straight from pubspec.yaml rather than via `flutter.versionCode` /
// `flutter.versionName`.
//
// Those Flutter extension properties are only populated when the build is driven
// by `flutter build` (which passes them through) or when they are pinned in
// android/local.properties. build_custom.ps1 invokes Gradle DIRECTLY and
// local.properties intentionally no longer pins them, so `flutter.versionCode`
// silently resolves to 1 — which Play rejects as a downgrade for every existing
// installed user. Parsing pubspec makes the version correct on every build path.

fun pubspecFor(rootDir: File): File = rootDir.resolve("../pubspec.yaml")

/** The raw `version:` value from pubspec, e.g. "1.12.6+40000159". */
fun loadPubspecVersion(rootDir: File): String {
    val pubspec = pubspecFor(rootDir)
    require(pubspec.exists()) { "pubspec.yaml not found at ${pubspec.path}" }

    val line = pubspec.readLines().firstOrNull { it.startsWith("version:") }
        ?: throw GradleException("pubspec.yaml has no top-level `version:` line")

    val rawValue = line.substringAfter(":", "").trim()
    require(rawValue.isNotEmpty()) { "pubspec.yaml `version:` is empty" }
    return rawValue
}

/** Marketing version shared by every flavor, e.g. "1.12.6". */
fun loadAppVersionName(rootDir: File): String {
    val name = loadPubspecVersion(rootDir).substringBefore("+").trim()
    require(name.isNotEmpty()) { "Could not parse a versionName from pubspec `version:`" }
    return name
}

/** Mobile versionCode, i.e. the build number after "+" in pubspec `version:`. */
fun loadAppVersionCode(rootDir: File): Int {
    val raw = loadPubspecVersion(rootDir)
    val code = raw.substringAfter("+", "").trim().toIntOrNull()
        ?: throw GradleException(
            "pubspec `version:` ($raw) has no build number — expected the form x.y.z+build"
        )
    require(code > 1) { "Refusing to build with versionCode $code — Play treats it as a downgrade" }
    return code
}

/** Android TV versionCode. Must be unique vs mobile: they share one Play listing. */
fun loadAndroidTvVersionCode(rootDir: File): Int {
    val pubspec = pubspecFor(rootDir)
    val line = pubspec.readLines().firstOrNull {
        it.trimStart().startsWith("android_tv_build_number:")
    } ?: throw GradleException("pubspec.yaml has no `android_tv_build_number:` under `voltix:`")

    val code = line.substringAfter(":", "").trim().toIntOrNull()
        ?: throw GradleException("`android_tv_build_number:` is not a number")
    require(code > 1) { "Refusing to build with TV versionCode $code — Play treats it as a downgrade" }
    require(code != loadAppVersionCode(rootDir)) {
        "android_tv_build_number must differ from the mobile build number (shared Play listing)"
    }
    return code
}

// NOTE: there is deliberately no loadAndroidTvVersionName().
//
// Mobile and Android TV share applicationId cc.voltix.streaming and therefore a
// single Play listing, so both flavors must report the SAME versionName — the
// one from pubspec `version:`. When TV read its own `android_tv_version:` key
// the two drifted onto unrelated series (mobile 1.7.6 / TV 1.12.5), and
// AppUpdateService — which compares versionName against the latest GitHub
// release tag — permanently reported "update available" for whichever series
// was behind the tag.
//
// Only the versionCode differs per flavor, because Play requires a unique,
// ascending code for every uploaded artifact.

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties().apply {
    val file = rootProject.file("keystore.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val keystoreStoreType = keystoreProperties
    .getProperty("storeType")
    ?.trim()
    ?.takeIf { it.isNotEmpty() }

val hasReleaseKeystore = rootProject.file("app/release.keystore").exists() &&
    (keystoreProperties.getProperty("keyAlias")?.isNotBlank() == true)

// Release signing is silent when it fails: with no keystore.properties the
// release build type falls back to signingConfigs["debug"], and a debug-signed
// APK carrying a package name that exists on Play is blocked on install by
// Play Protect ("App blocked by Play Protect"). Nothing in the build output
// says so. Fail the build instead.
//
// keystore.properties must sit in android/ (rootProject), NOT android/app/ —
// rootProject.file() resolves against android/.
gradle.taskGraph.whenReady {
    val buildsRelease = allTasks.any {
        it.project == project && it.name.contains("Release", ignoreCase = false)
    }
    if (buildsRelease && !hasReleaseKeystore && !project.hasProperty("allowDebugSigning")) {
        throw GradleException(
            """
            Release build would be signed with the DEBUG key.

            Expected:
              android/keystore.properties   (storePassword, keyPassword, keyAlias)
              android/app/release.keystore

            Both are gitignored, so a fresh clone has neither. Note the
            properties file belongs in android/, not android/app/.

            To build a debug-signed release anyway: -PallowDebugSigning
            """.trimIndent()
        )
    }
}

android {
    namespace = "com.voltix.app"
    compileSdk = 36
    ndkVersion = "28.2.13676358"
    // All four resolved from pubspec.yaml — never from flutter.versionCode /
    // flutter.versionName, which are unset when Gradle is driven directly.
    val appVersionName = loadAppVersionName(rootDir)
    val appVersionCode = loadAppVersionCode(rootDir)
    val androidTvVersionCode = loadAndroidTvVersionCode(rootDir)
    // Shared with mobile by design — see the note above the plugins block.
    val androidTvVersionName = appVersionName

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = appVersionCode
        versionName = appVersionName
    }

    flavorDimensions += "device"
    productFlavors {
        val baseAppId = "cc.voltix.streaming"
        val baseAppName = "Voltix"
        val mobileAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        val tvAbis = listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        create("mobile") {
            dimension = "device"
            applicationId = baseAppId
            versionCode = appVersionCode
            versionName = appVersionName
            ndk { abiFilters += mobileAbis }
            manifestPlaceholders["appName"] = baseAppName
        }
        create("mobile-beta") {
            dimension = "device"
            applicationId = "$baseAppId.beta"
            versionCode = appVersionCode
            versionName = appVersionName
            ndk { abiFilters += mobileAbis }
            manifestPlaceholders["appName"] = "$baseAppName Beta"
        }
        create("androidTv") {
            dimension = "device"
            applicationId = baseAppId
            versionCode = androidTvVersionCode
            versionName = androidTvVersionName
            ndk { abiFilters += tvAbis }
            manifestPlaceholders["appName"] = baseAppName
        }
        create("androidTv-beta") {
            dimension = "device"
            applicationId = "$baseAppId.beta"
            versionCode = androidTvVersionCode
            versionName = androidTvVersionName
            ndk { abiFilters += tvAbis }
            manifestPlaceholders["appName"] = "$baseAppName Beta"
        }
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                storeFile = file("release.keystore")
                storeType = keystoreStoreType
                storePassword = keystoreProperties["storePassword"] as String?
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Voltix ships without R8/resource shrinking (stock Moonfin 2.2.0
            // enabled it, but shrinking breaks media_kit / native video / cast /
            // reflection-based plugins and aborts APK packaging). Keep it off.
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            pickFirsts += setOf("**/libc++_shared.so")
        }
    }

}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("com.google.android.gms:play-services-cast-framework:22.0.0")
    implementation("eu.simonbinder:sqlite3-native-library:3.52.0")
}

val flutterApkOutputDir = layout.buildDirectory.dir("app/outputs/flutter-apk")

tasks.register<Copy>("copyAndroidTvDebugApkForFlutter") {
    from(flutterApkOutputDir.map { it.file("app-androidtv-debug.apk") })
    into(flutterApkOutputDir)
    rename { "app-debug.apk" }
}

tasks.matching { it.name == "assembleDebug" }.configureEach {
    finalizedBy("copyAndroidTvDebugApkForFlutter")
}
