pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // AGP 8.11.1 requires Gradle 8.13+ and JDK 17 (wrapper is on 8.14.3).
    id("com.android.application") version "8.11.1" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
    // Processes android/app/google-services.json into the google_app_id /
    // gcm_defaultSenderId string resources that Firebase reads at process
    // start. Without it those resources are absent and firebase_messaging's
    // FlutterFirebaseMessagingInitProvider throws while Android is creating
    // the app's ContentProviders -- killing the process before Flutter or any
    // Dart code runs, which looks exactly like "tap the icon, nothing happens".
    id("com.google.gms.google-services") version "4.4.2" apply false
}

include(":app")
