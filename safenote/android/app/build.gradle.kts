import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

// release signing 설정: android/key.properties 가 존재할 때만 활성.
// 부재 시 debug 키로 fallback (배포용 아님, 개발 편의)
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.prafta.safenote"
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
        applicationId = "com.prafta.safenote"
        minSdk = flutter.minSdkVersion
        targetSdk = 36 // ✅ compileSdk와 동일하게 유지
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                // storeFile 은 key.properties 가 있는 위치(=android/) 기준 상대경로로 해석한다.
                // 기본 file(...) 은 app 모듈(=android/app/) 기준이라 한 레벨 어긋나는 점을 보정.
                storeFile = rootProject.file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            // key.properties 가 있으면 release 키로 서명, 없으면 debug 키 fallback (배포용 아님)
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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

// prafta-app-023: url_launcher(첨부 외부열기)가 끌어온 androidx.core 1.17.0 / browser 1.9.0 은
// AGP 8.9.1+ 를 요구해 현재 AGP 8.6.0 빌드(checkReleaseAarMetadata)를 깬다.
// AGP 8.6.0 호환 버전(core 1.16.0 / browser 1.8.0)으로 고정한다.
// (url_launcher 는 단순 ACTION_VIEW 인텐트 실행이라 구버전 androidx 로도 정상 동작)
configurations.all {
    resolutionStrategy {
        force("androidx.core:core:1.16.0")
        force("androidx.core:core-ktx:1.16.0")
        force("androidx.browser:browser:1.8.0")
    }
}

dependencies {
    // ✅ Java11 호환
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
