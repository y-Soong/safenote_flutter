import 'package:flutter/foundation.dart' show TargetPlatform, debugPrint, defaultTargetPlatform;
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// 작업지시서 iOS-푸시-미수신-및-포그라운드-알림-미표시 문제 B:
// FirebaseMessaging.onMessage(포그라운드 수신 스트림)를 구독하는 코드가 어디에도 없어
// 앱이 포그라운드일 때는 PUSH 알림이 화면에 전혀 뜨지 않던 결함의 표시 처리를 담당한다.
//
// - 안드로이드: FCM 사양상 앱이 포그라운드면 OS 가 알림 배너를 자동 표시하지 않으므로
//   flutter_local_notifications 로 직접 로컬 알림을 띄운다.
// - iOS: setForegroundNotificationPresentationOptions 로 OS 배너 자동 표시를 켠다.
//   (안드로이드처럼 로컬 알림을 별도로 또 띄우면 중복 알림이 생기므로 iOS 는 이 경로를 타지 않는다.)

const AndroidNotificationChannel _highImportanceChannel = AndroidNotificationChannel(
  'high_importance_channel',
  '중요 알림',
  description: '근태/승인 등 즉시 확인이 필요한 알림',
  importance: Importance.high,
);

final FlutterLocalNotificationsPlugin _localNotifications = FlutterLocalNotificationsPlugin();

/// main() 에서 Firebase 초기화 이후 1회 호출한다.
Future<void> initPushNotifications() async {
  await _localNotifications
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(_highImportanceChannel);

  await _localNotifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  if (defaultTargetPlatform == TargetPlatform.iOS) {
    await FirebaseMessaging.instance.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
  }
}

/// FirebaseMessaging.onMessage 구독 콜백(web_app.dart 에서 호출).
/// 안드로이드에서만 로컬 알림으로 표시한다(iOS 는 initPushNotifications 의
/// setForegroundNotificationPresentationOptions 가 OS 배너로 처리).
void showForegroundNotification(RemoteMessage message) {
  if (defaultTargetPlatform != TargetPlatform.android) return;

  final notification = message.notification;
  if (notification == null) return;

  try {
    _localNotifications.show(
      message.hashCode,
      notification.title,
      notification.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'high_importance_channel',
          '중요 알림',
          channelDescription: '근태/승인 등 즉시 확인이 필요한 알림',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  } catch (e) {
    debugPrint('[FOREGROUND_PUSH] 로컬 알림 표시 실패: $e');
  }
}
