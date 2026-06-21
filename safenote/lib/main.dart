import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'location_gate.dart'; // 👈 위치권한 하드 게이트
import 'camera_gate.dart'; // 👈 카메라권한 하드 게이트

// prafta-com-008-F02: FCM 백그라운드 메시지 핸들러.
// firebase_messaging 은 백그라운드 수신 시 별도 isolate 에서 top-level(또는 static) 함수를
// 호출하도록 요구한다. 본 작업 범위는 "토큰 획득/전달"이므로 여기서는 메시지 처리(라우팅/저장)를
// 하지 않고 최소 등록만 한다. 실제 알림 표시/처리 로직은 비즈니스 로직이므로 추가하지 않는다.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // 백그라운드 isolate 에서도 Firebase 초기화가 선행되어야 한다.
  await Firebase.initializeApp();
  // 비즈니스 로직 금지: 수신 사실만 로깅(페이로드 본문은 로깅하지 않음 — 최소 수집).
  debugPrint('[FCM] 백그라운드 메시지 수신: ${message.messageId}');
}

Future<void> main() async {
  // Firebase.initializeApp() 은 플랫폼 채널을 쓰므로 바인딩 초기화가 선행되어야 한다.
  WidgetsFlutterBinding.ensureInitialized();

  // prafta-com-008-F02: Firebase 초기화(FCM 전제). google-services.json 미배치 시 빌드에서
  // 실패하므로(배치는 사용자 몫), 런타임 예외는 격리하여 앱 기동 자체는 막지 않는다.
  try {
    await Firebase.initializeApp();
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
