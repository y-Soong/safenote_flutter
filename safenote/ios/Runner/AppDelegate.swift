import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  // ★임시 진단(2026-08-10, iOS-푸시-미수신 작업지시서 문제 A): APNs 등록이 실패할 때 iOS 가
  // 던지는 실제 에러(didFailToRegisterForRemoteNotificationsWithError)를 Mac/Xcode 기기 로그
  // 없이도 Flutter 쪽(GET_PUSH_TOKEN 진단 다이얼로그, web_app.dart)에서 볼 수 있게 캡처해둔다.
  // FirebaseAppDelegateProxyEnabled(기본 ON) 스위즐링이 이 구현을 감지해 Firebase 내부 처리
  // 후 그대로 호출해준다(공식 지원 방식, Firebase 내부 처리를 막지 않음).
  // 원인 확정 후 이 프로퍼티/메서드채널/콜백을 함께 제거할 것.
  static var apnsRegistrationError: String?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    // window/rootViewController 는 super 호출 안에서 생성되므로 그 이후에 채널을 붙인다.
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "prafta/apns_diagnostics",
        binaryMessenger: controller.binaryMessenger
      )
      channel.setMethodCallHandler { call, methodResult in
        if call.method == "getLastRegistrationError" {
          methodResult(AppDelegate.apnsRegistrationError)
        } else {
          methodResult(FlutterMethodNotImplemented)
        }
      }
    }

    return result
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    AppDelegate.apnsRegistrationError = error.localizedDescription
  }
}
