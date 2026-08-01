import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'location_gate.dart'; // 👈 위치권한 하드 게이트
import 'camera_gate.dart'; // 👈 카메라권한 하드 게이트
import 'firebase_options.dart'; // FlutterFire CLI 생성(iOS 전용 구성)

// 안드로이드 웹뷰 원격 디버깅(chrome://inspect) 토글.
//
// ★web_app.dart 의 InAppWebViewSettings.isInspectable 은 iOS/macOS 전용이다
//   (플러그인 정의: apiName "WKWebView.isInspectable"). 안드로이드는 아래 정적 호출이
//   없으면 devtools 소켓(webview_devtools_remote_<pid>) 자체가 열리지 않아
//   chrome://inspect 의 Remote Target 에 앱이 영원히 나타나지 않는다(2026-08-01 실측).
//
// 릴리즈에 상시로 켜두면 USB 만 꽂으면 웹뷰 내부(세션 토큰 포함)를 들여다볼 수 있으므로
// 반드시 빌드 플래그로 게이트한다. 켜서 빌드하려면:
//   flutter build apk --release --dart-define=WEBVIEW_DEBUG=true
//   (또는 scripts\build-apk.ps1 -WebviewDebug)
const bool kWebviewDebug = bool.fromEnvironment('WEBVIEW_DEBUG');

// iOS 는 FlutterFire CLI 가 생성한 Dart 옵션(firebase_options.dart)으로 초기화한다
// (GoogleService-Info.plist 를 번들하지 않는 Dart-only 구성).
// 안드로이드는 기존대로 네이티브 리소스(google-services.json)로 초기화하므로 null 을 넘긴다
// — firebase_options.dart 는 iOS 만 구성돼 있어 android 에서 currentPlatform 을 부르면 throw 된다.
FirebaseOptions? get _firebaseOptionsForPlatform =>
    defaultTargetPlatform == TargetPlatform.iOS ? DefaultFirebaseOptions.ios : null;

// prafta-com-008-F02: FCM 백그라운드 메시지 핸들러.
// firebase_messaging 은 백그라운드 수신 시 별도 isolate 에서 top-level(또는 static) 함수를
// 호출하도록 요구한다. 본 작업 범위는 "토큰 획득/전달"이므로 여기서는 메시지 처리(라우팅/저장)를
// 하지 않고 최소 등록만 한다. 실제 알림 표시/처리 로직은 비즈니스 로직이므로 추가하지 않는다.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // 백그라운드 isolate 에서도 Firebase 초기화가 선행되어야 한다.
  // try/catch 가 없으면 초기화 실패 시 이 isolate 가 죽어 백그라운드 푸시 수신이 무력화된다.
  try {
    await Firebase.initializeApp(options: _firebaseOptionsForPlatform);
  } catch (e) {
    debugPrint('[FCM] 백그라운드 isolate Firebase 초기화 실패: $e');
    return;
  }
  // 비즈니스 로직 금지: 수신 사실만 로깅(페이로드 본문은 로깅하지 않음 — 최소 수집).
  debugPrint('[FCM] 백그라운드 메시지 수신: ${message.messageId}');
}

Future<void> main() async {
  // Firebase.initializeApp() 은 플랫폼 채널을 쓰므로 바인딩 초기화가 선행되어야 한다.
  WidgetsFlutterBinding.ensureInitialized();

  // 웹뷰 원격 디버깅(안드로이드 전용, 빌드 플래그로만 활성화 — 상단 kWebviewDebug 주석 참조).
  // 웹뷰 생성 전에 호출해야 해당 WebView 에 반영된다.
  if (kWebviewDebug && defaultTargetPlatform == TargetPlatform.android) {
    try {
      await InAppWebViewController.setWebContentsDebuggingEnabled(true);
      debugPrint('[WEBVIEW_DEBUG] 안드로이드 웹뷰 원격 디버깅 활성화 — chrome://inspect');
    } catch (e) {
      debugPrint('[WEBVIEW_DEBUG] 활성화 실패(앱 기동은 계속): $e');
    }
  }

  // prafta-com-008-F02: Firebase 초기화(FCM 전제). google-services.json 미배치 시 빌드에서
  // 실패하므로(배치는 사용자 몫), 런타임 예외는 격리하여 앱 기동 자체는 막지 않는다.
  try {
    await Firebase.initializeApp(options: _firebaseOptionsForPlatform);
    // 백그라운드 메시지 핸들러는 초기화 직후 1회만 등록한다.
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint('[FCM] Firebase 초기화 실패(앱 기동은 계속): $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      // 권한 게이트 체이닝: 위치 → 카메라 모두 허용해야 웹뷰(WebApp)로 진입한다.
      // 둘 중 하나라도 미동의면 앱 사용 불가(하드 게이트).
      home: LocationGate(next: CameraGate()),
    );
  }
}
