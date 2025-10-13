plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.safenote"
    compileSdk = 36 // ✅ mobile_scanner, webview_flutter_android 요구사항 충족
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "11"
    }

    defaultConfig {
        applicationId = "com.example.safenote"
        minSdk = flutter.minSdkVersion
        targetSdk = 36 // ✅ compileSdk와 동일하게 유지
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.getByName("debug") // ⚠️ 실제 배포 시 release 키로 변경
        }

        debug {
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        resources.excludes.add("META-INF/*")
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ✅ Java11 호환
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
