# ============================================================
# PRAFTA safenote - release(R8/minify) keep 룰
# build.gradle.kts 의 release { isMinifyEnabled=true, isShrinkResources=true }
# 가 이 파일을 참조한다. 없으면 assembleRelease 가 실패하므로 반드시 존재해야 함.
# ============================================================

# --- Flutter 엔진/임베딩 ---
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.**  { *; }
-keep class io.flutter.util.**  { *; }
-keep class io.flutter.view.**  { *; }
-keep class io.flutter.**  { *; }
-keep class io.flutter.plugins.**  { *; }
-dontwarn io.flutter.embedding.**

# --- 네이티브 메서드 / 애노테이션 보존 ---
-keepattributes *Annotation*
-keepattributes Signature
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- mobile_scanner: Google ML Kit Barcode ---
# R8 가 ML Kit 진입점/모델 로더를 제거하면 스캐너가 런타임에 죽는다.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.gms.**

# --- webview_flutter_android ---
-keep class io.flutter.plugins.webviewflutter.** { *; }

# --- device_info_plus / package_info_plus / android_id 등 일반 플러그인 ---
# 리플렉션 사용 가능성 대비 (과도한 제거 방지)
-keepclassmembers class * {
    @androidx.annotation.Keep *;
}
-keep @androidx.annotation.Keep class * { *; }
