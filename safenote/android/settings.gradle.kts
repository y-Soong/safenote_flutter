pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }

    val props = java.util.Properties()
    file("local.properties").inputStream().use { props.load(it) }
    val flutterSdkPath = props.getProperty("flutter.sdk")
        ?: error("flutter.sdk not set in local.properties")

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    // mobile_scanner 7.4(androidx.camera 1.6.1)가 AGP 8.9.1+ 요구 (2026-07-30 상향, Gradle 래퍼 8.11.1 동반)
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
    // prafta-com-008-F02: Firebase(FCM) — google-services 플러그인. 앱 모듈에서 apply.
    id("com.google.gms.google-services") version "4.4.2" apply false
}

include(":app")
