import 'dart:async' show StreamSubscription, TimeoutException, Timer;
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert' show jsonEncode, jsonDecode, utf8;
import 'dart:io' show HttpClient, Platform;
import 'package:flutter/foundation.dart' show kDebugMode, kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:android_id/android_id.dart';
import 'package:url_launcher/url_launcher.dart';
import 'qr_scan_page.dart';
import 'push_notifications.dart' show showForegroundNotification;

// 개발 빌드는 LAN dev 서버, 운영 빌드는 InAppLocalhostServer 의 bundled assets 를 로딩한다.
// 둘 다 --dart-define 으로 외부에서 덮어쓸 수 있다.
//   flutter run --dart-define=APP_DEV_URL=https://172.30.1.4:8082
//   flutter build apk --release --dart-define=APP_BASE_URL=https://api.example.com
const String _kAppDevUrl = String.fromEnvironment(
  'APP_DEV_URL',
  defaultValue: 'https://172.30.1.4:8082',
);
const String _kAppBaseUrl = String.fromEnvironment(
  'APP_BASE_URL',
  defaultValue: '',
);
const int _kLocalhostPort = 8080;

// __SHELL__ 브리지 계약 버전 (웹뷰 원격로딩 전환 T1).
// ★ addJavaScriptHandler 로 핸들러를 추가/제거할 때 반드시 _kBridgeHandlers 를 함께 갱신하고
//   버전을 +1 한다. Vue 는 이 목록(window.__SHELL__.handlers)으로 호출 전 지원 여부를 판별한다
//   (앱FE src/utils/shellCapability.js). 목록 누락 시 신Vue 가 해당 기능을 "셸 미지원"으로
//   오판해 기능이 조용히 꺼진다.
const int _kBridgeVersion = 1;
const List<String> _kBridgeHandlers = [
  'JS_CONSOLE',
  'GET_GPS',
  'GET_DEVICE_INFO',
  'GET_APP_FOREGROUND_SEC',
  'GET_PUSH_TOKEN',
  'SCAN_QR',
  'OPEN_APP_SETTINGS',
  'REQUEST_CAMERA_PERMISSION',
];

// 원격 앱 프론트 호스트(T4, D1: app.prafta.com). --dart-define=APP_REMOTE_URL 로 덮어쓸 수
// 있고, 빈 문자열로 빌드하면 원격 시도 자체를 하지 않는다(전원 번들 — 비상 빌드용).
// 평시 원격 중단은 빌드가 아니라 매니페스트 enabled:false(킬 스위치)로 한다.
const String _kRemoteAppUrl = String.fromEnvironment(
  'APP_REMOTE_URL',
  defaultValue: 'https://app.prafta.com',
);

// 웹뷰 검사 허용(T7 축소) — iOS isInspectable 은 릴리즈에서 WEBVIEW_DEBUG 빌드 시에만 켠다.
// 안드로이드 setWebContentsDebuggingEnabled(main.dart kWebviewDebug)와 동일 관례·동일 define.
const bool _kWebviewDebug = bool.fromEnvironment('WEBVIEW_DEBUG');

// 매니페스트(app-manifest.json) 조회 전체 타임아웃(D2: 3초 기본, §7 L-4 실측 후 확정).
const Duration _kManifestTimeout = Duration(seconds: 3);

// 원격 진입 후 첫 페이지 로드 감시 시한 — 이 안에 onLoadStop 이 오지 않으면 번들 폴백
// (§7 N-1 "흰 화면 방치 금지"). 저속망 오탐을 피하려 여유 있게 잡는다.
const Duration _kRemoteLoadWatchdog = Duration(seconds: 12);

// ★임시 진단(2026-08-10, iOS-푸시-미수신 작업지시서 문제 A): AppDelegate.swift 의
// didFailToRegisterForRemoteNotificationsWithError 캡처값을 pull 로 조회한다. 원인 확정 후
// 이 채널과 ios/Runner/AppDelegate.swift 쪽 대응 코드를 함께 제거할 것.
const MethodChannel _apnsDiagChannel = MethodChannel('prafta/apns_diagnostics');

class WebApp extends StatefulWidget {
  const WebApp({super.key});
  @override
  State<WebApp> createState() => _WebAppState();
}

class _WebAppState extends State<WebApp> with WidgetsBindingObserver {
  InAppWebViewController? _ctl;
  InAppLocalhostServer? _localhost;
  int _progress = 0;
  String _status = 'init';

  // 로컬 서버 복구 진행 중 플래그(resume 연타·프로세스 종료 콜백 중복 진입 방지).
  bool _recoveringLocalhost = false;

  // __SHELL__ 주입용 앱 버전(initState 에서 비동기 취득). 취득 전에 로드된 페이지는
  // onLoadStop 재주입으로 보정된다(__APP_BASE_URL__ 과 동일 패턴).
  String _appVersion = '';

  // 현재 웹뷰 콘텐츠 로딩 소스(T4). release 는 _openInitialUrl 의 원격/번들 판정 결과
  // ('remote'|'bundle')가 들어가며, __SHELL__.loadSource 로 Vue 마이페이지 빌드 정보에
  // remote/bundle 표기(§7 판정 수단)된다. 판정 전 기본값은 'bundle'.
  String? _loadSourceState;
  String get _loadSource => kReleaseMode ? (_loadSourceState ?? 'bundle') : 'dev';

  // 원격 → 번들 폴백이 이번 기동에서 이미 수행됐는지(중복 폴백·플래핑 방지, §7 R-5).
  // 재판정은 앱 재기동 시에만 한다(D4).
  bool _remoteFallbackDone = false;

  // 원격 첫 로드 감시 타이머(_kRemoteLoadWatchdog). onLoadStop 에서 해제된다.
  Timer? _remoteWatchdog;

  DateTime? _lastBackPressedAt; // ✅ 추가

  // prafta-051-09: 앱 포그라운드 누적초(단조 증가, TBM 세션 무관 전역 누적).
  // - _fgAccumSec: 지금까지 누적된 포그라운드 시간(초).
  // - _fgResumedAt: 현재 포그라운드 진입 시각(떠 있는 동안만 non-null).
  // GET_APP_FOREGROUND_SEC 브리지가 (_fgAccumSec + 진행중 경과초)를 반환한다.
  // 누적/합산/반환만 담당하며, 세션 귀속·NULL 처리·저장은 Vue/백엔드 몫(비즈니스 로직 금지).
  // 한계: 시스템 강제종료(detached 미수신) 시 마지막 진행분이 유실될 수 있다.
  int _fgAccumSec = 0;
  DateTime? _fgResumedAt;

  // prafta-com-008-F02: FCM 토큰 refresh 구독(앱 1회 구독, dispose 시 해제).
  // onTokenRefresh 발화 시 window.__onPushTokenRefresh 콜백으로 Vue 에 push 한다.
  // ★주의: 알림 권한 요청을 라이프사이클 콜백(onResume 등)에 박지 않는다.
  //   (메모리 project_prafta_app_perm_native_race — geolocator 와 Activity 단위 충돌로
  //    첫 설치 무한로딩 사고). 권한 요청은 Vue 가 GET_PUSH_TOKEN 을 호출하는 단일 경로에서만 한다.
  StreamSubscription<String>? _tokenRefreshSub;

  // PRAFTA-WEB_001-5: 푸시 알림 "탭(open)" 라우팅 브리지.
  // - onMessageOpenedApp(백그라운드 상태에서 알림 탭) 구독.
  // - getInitialMessage(앱 종료 상태에서 알림 탭으로 콜드스타트) 1회 확인.
  // 수신한 RemoteMessage.data(DATA_PAYLOAD)를 JSON 문자열로 window.__onPushOpened 에 전달한다
  // (push 모델, _subscribeTokenRefresh 의 window.__onPushTokenRefresh 와 동형). 라우팅 판정은 Vue 몫.
  // ★비즈니스 로직 금지: 여기서는 data 전달만. 콜드스타트는 페이지 로드 전이라 _pendingPushData 로
  //   보관했다가 onLoadStop(_pageLoaded)에서 flush 한다.
  StreamSubscription<RemoteMessage>? _msgOpenedSub;
  Map<String, dynamic>? _pendingPushData;
  bool _pageLoaded = false;

  // 작업지시서 iOS-푸시-미수신-및-포그라운드-알림-미표시 문제 B:
  // FirebaseMessaging.onMessage(포그라운드 수신) 구독. 표시 처리는 push_notifications.dart 위임.
  StreamSubscription<RemoteMessage>? _foregroundMsgSub;

  /// 숨겨진 file input을 스캔해서 파일이 있으면 강제로 `input` 이벤트 발생
  /// (일부 안드 기기에서 change 이벤트가 누락되는 문제 대응)
  static const String _scanPickersJS = r"""
  (function(){
    try {
      var nodes = document.querySelectorAll(
        'input[type="file"][id^="gallery_"], input[type="file"][id^="camera_"]'
      );
      nodes.forEach(function(input){
        try {
          if (input && input.files && input.files.length > 0) {
            // 강제로 input 이벤트 디스패치(프레임워크에서 v-model/리스너 트리거)
            var ev = new Event('input', { bubbles: true });
            input.dispatchEvent(ev);
          }
        } catch(e){}
      });
    } catch (e) {}
  })();
  """;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ensureRuntimePermissions();

    // __SHELL__ 주입용 앱 버전 취득(T1). 실패해도 빈 문자열로 주입되며 기능 영향 없음.
    // ignore: discarded_futures
    PackageInfo.fromPlatform().then((pkg) {
      _appVersion = pkg.version;
    }).catchError((e) {
      debugPrint('[__SHELL__] 앱버전 취득 실패: $e');
    });

    // release 빌드: 번들된 Vue 자산을 InAppLocalhostServer 로 서빙
    if (kReleaseMode) {
      _localhost = InAppLocalhostServer(
        port: _kLocalhostPort,
        documentRoot: 'assets/vue_app/',
        directoryIndex: 'index.html',
      );
      // ignore: discarded_futures
      _localhost!.start();
    }

    // ✅ 매 build마다 호출하지 말고 여기서 한 번만
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
    );
  }

  Future<void> _handleBackPressed() async {
    // 1) Flutter 네비게이션 스택에 이전 화면이 있으면 먼저 pop
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      nav.pop();
      return;
    }

    // 2) WebView 히스토리가 있으면 WebView 뒤로가기
    final canGoBack = await _ctl?.canGoBack() ?? false;
    if (canGoBack) {
      await _ctl?.goBack();
      return;
    }

    // 3) 홈(더 이상 뒤로갈 곳 없음) -> 2번 누르면 종료
    final now = DateTime.now();
    final last = _lastBackPressedAt;
    final within2Sec = last != null && now.difference(last) <= const Duration(seconds: 2);

    if (within2Sec) {
      // Android에서 앱 종료
      SystemNavigator.pop();
      return;
    }

    _lastBackPressedAt = now;

    // 안내 메시지(Toast 대신 SnackBar)
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('한 번 더 누르면 앱이 종료됩니다.'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _localhost?.close();
    _tokenRefreshSub?.cancel(); // prafta-com-008-F02: FCM refresh 구독 해제
    _msgOpenedSub?.cancel(); // PRAFTA-WEB_001-5: 푸시 탭(open) 구독 해제
    _remoteWatchdog?.cancel(); // T4: 원격 첫 로드 감시 타이머 해제
    _foregroundMsgSub?.cancel(); // 포그라운드 PUSH 구독 해제
    super.dispose();
  }

  /// 앱 라이프사이클:
  /// - RESUMED: 카메라 앱 다녀온 후 강제 스캔 + 포그라운드 진입 시각 기록(prafta-051-09).
  /// - PAUSED/INACTIVE/DETACHED: 포그라운드 경과초를 누적(prafta-051-09).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // prafta-051-09: 포그라운드 진입 시각 기록(누적은 백그라운드 전환 시 확정).
      _fgResumedAt = DateTime.now();

      // 기존 동작 보존: 카메라/갤러리 다녀온 뒤 숨은 file input 강제 스캔.
      if (_ctl != null) {
        debugPrint('🔎 App RESUMED -> scan hidden file inputs');
        _ctl!.evaluateJavascript(source: _scanPickersJS);
      }

      // 오래 백그라운드에 있다 복귀하면 로컬 서버 소켓이 회수돼 있을 수 있다(_ensureLocalhostAlive 주석).
      // ★재기동이 실제로 일어났을 때만 리로드한다. resume 마다 무조건 리로드하면
      //   작성 중이던 신청서·필터 등 Vue 상태가 통째로 날아간다.
      // T4/D4: 원격 소스로 떠 있는 동안에는 로컬 서버 상태가 화면과 무관하므로
      //   복구·리로드를 걸지 않는다(사용 중 소스 전환 금지). 재판정은 앱 재기동 시에만.
      if (_loadSourceState == 'remote') return;
      // ignore: discarded_futures
      _ensureLocalhostAlive().then((recovered) {
        if (!recovered || !mounted) return;
        _ctl?.reload();
        ScaffoldMessenger.of(context)
          ..removeCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('연결이 끊겨 화면을 다시 불러왔어요.'),
              duration: Duration(seconds: 2),
            ),
          );
      });
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // prafta-051-09: 포그라운드 → 백그라운드 전환. 진행분을 누적에 확정.
      _accumulateForeground();
    }
  }

  /// 로컬 서버(release 번들 서빙)가 실제로 응답하는지 HTTP 요청으로 확인한다.
  ///
  /// `InAppLocalhostServer.isRunning()` 은 내부 플래그만 보므로 소켓이 회수된 뒤에도
  /// 참을 반환할 수 있다. 그래서 상태값이 아니라 **실제 요청으로 판정**한다.
  Future<bool> _probeLocalhost() async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await client
          .getUrl(Uri.parse('http://localhost:$_kLocalhostPort/index.html'))
          .timeout(const Duration(seconds: 2));
      final res = await req.close().timeout(const Duration(seconds: 2));
      await res.drain<void>();
      return res.statusCode == 200;
    } catch (e) {
      debugPrint('🩺 로컬 서버 응답 없음: $e');
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// 로컬 서버가 죽어 있으면 재기동한다. 반환값 = **재기동이 실제로 일어났는지**
  /// (호출부가 웹뷰 리로드 여부를 판단하는 데 쓴다).
  ///
  /// 배경: 앱이 오래 백그라운드에 있으면 iOS 가 로컬 HTTP 서버 소켓을 회수할 수 있다.
  /// 서버는 initState 에서 한 번만 켜지므로 복귀 후 아무도 되살리지 않고,
  /// 그 결과 **새로 발생하는 요청만** 조용히 실패한다:
  ///   - 로고 등 `<img>` 요청 실패 → 이미지가 안 뜸
  ///   - 라우트 lazy chunk `import()` 실패 → 버튼을 눌러도 화면 이동이 안 됨
  /// 이미 렌더된 DOM 과 로드된 JS 는 살아 있어 스크롤은 정상이라, 겉보기에는
  /// "버튼만 안 눌리는" 것처럼 보인다. 앱을 껐다 켜면 initState 가 다시 돌아 정상화된다.
  Future<bool> _ensureLocalhostAlive() async {
    if (!kReleaseMode || _recoveringLocalhost) return false;
    _recoveringLocalhost = true;
    try {
      if (await _probeLocalhost()) return false;

      debugPrint('♻️ 로컬 서버 재기동 시도');
      try {
        await _localhost?.close();
      } catch (_) {}
      _localhost = InAppLocalhostServer(
        port: _kLocalhostPort,
        documentRoot: 'assets/vue_app/',
        directoryIndex: 'index.html',
      );
      await _localhost!.start();

      final ok = await _probeLocalhost();
      debugPrint(ok ? '✅ 로컬 서버 재기동 완료' : '❌ 재기동 후에도 응답 없음');
      return ok;
    } catch (e) {
      debugPrint('❌ 로컬 서버 재기동 실패: $e');
      return false;
    } finally {
      _recoveringLocalhost = false;
    }
  }

  /// prafta-051-09: 진행 중인 포그라운드 경과초를 _fgAccumSec 에 누적하고 진행 상태를 종료한다.
  void _accumulateForeground() {
    final startedAt = _fgResumedAt;
    if (startedAt != null) {
      final elapsedSec = DateTime.now().difference(startedAt).inSeconds;
      if (elapsedSec > 0) {
        _fgAccumSec += elapsedSec;
      }
      _fgResumedAt = null;
    }
  }

  /// prafta-051-09: 현재까지의 포그라운드 누적초(떠 있으면 진행분 합산).
  int _currentForegroundSec() {
    final startedAt = _fgResumedAt;
    if (startedAt != null) {
      final elapsedSec = DateTime.now().difference(startedAt).inSeconds;
      return _fgAccumSec + (elapsedSec > 0 ? elapsedSec : 0);
    }
    return _fgAccumSec;
  }

  Future<void> _ensureRuntimePermissions() async {
    if (Platform.isAndroid) {
      // Permission.photos 제거(2026-07-27): READ_MEDIA_IMAGES 매니페스트 삭제(사진 선택은
      //   웹뷰 file input → 시스템 피커라 권한 불필요 — 플레이스토어 사진/동영상 정책 대응).
      // Permission.microphone 제거: RECORD_AUDIO 매니페스트 삭제(07-20) 이후 항상 거부되는 죽은 요청.
      final results = await [
        Permission.camera,
        Permission.storage,  // Android 12 이하 호환 (매니페스트 maxSdkVersion=32)
      ].request();
      debugPrint('Permissions: $results');
    }
  }

  /// GET_GPS 브리지 핸들러.
  ///
  /// geolocator 로 현재 위치를 취득하여 계약대로 Map 을 반환한다.
  /// 위치 권한은 앱 기동 시 LocationGate 에서 하드 게이트로 보장되지만,
  /// 권한 변경/서비스 OFF 등 예외 케이스를 방어적으로 다시 검사한다.
  ///
  /// 반환:
  ///   - 정상:    {status:'OK', lat, lon, accuracy, isMocked(bool)}
  ///   - 권한거부: {status:'PERMISSION_DENIED'}
  ///   - 서비스OFF:{status:'SERVICE_DISABLED'}
  ///   - 타임아웃: {status:'TIMEOUT'}
  ///
  /// 비즈니스 로직(지오펜스/저장)은 백엔드 몫이며 여기서는 좌표 취득만 한다.
  Future<Map<String, dynamic>> _handleGetGps() async {
    try {
      // 1) OS 위치 서비스 ON 여부.
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        debugPrint('[GET_GPS] 위치 서비스 OFF');
        return {'status': 'SERVICE_DISABLED'};
      }

      // 2) 권한 상태 확인(필요 시 1회 요청 — 게이트 통과 후에는 보통 이미 허용).
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        debugPrint('[GET_GPS] 위치 권한 거부: $permission');
        return {'status': 'PERMISSION_DENIED'};
      }

      // 3) 현재 위치 취득(타임아웃 부착).
      final Position pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );

      debugPrint(
        '[GET_GPS] OK acc=${pos.accuracy} mocked=${pos.isMocked}',
      );
      return {
        'status': 'OK',
        'lat': pos.latitude,
        'lon': pos.longitude,
        'accuracy': pos.accuracy,
        'isMocked': pos.isMocked,
      };
    } on TimeoutException {
      debugPrint('[GET_GPS] 측위 타임아웃');
      return {'status': 'TIMEOUT'};
    } on LocationServiceDisabledException {
      debugPrint('[GET_GPS] 위치 서비스 OFF(예외)');
      return {'status': 'SERVICE_DISABLED'};
    } catch (e) {
      // getCurrentPosition 의 timeLimit 초과는 일부 플랫폼에서 TimeoutException
      // 으로 던져진다. 그 외 알 수 없는 오류도 타임아웃에 준해 처리한다.
      debugPrint('[GET_GPS] 측위 실패: $e');
      return {'status': 'TIMEOUT'};
    }
  }

  /// GET_DEVICE_INFO 브리지 핸들러 (prafta-com-003 C1).
  ///
  /// 네이티브 디바이스 식별자 + 메타를 취득하여 webview(Vue)에 전달한다(pull 모델, GET_GPS 동일).
  /// 비즈니스 로직(저장/판정/부정탐지)은 백엔드/Vue 몫이며, 여기서는 값 취득·전달만 한다.
  ///
  /// 반환 계약:
  ///   { deviceId, deviceType: 'ANDROID'|'IOS', model, osVersion, appVersion }
  ///   - Android: deviceId = ANDROID_ID(Settings.Secure), deviceType = 'ANDROID'
  ///   - iOS:     deviceId = identifierForVendor(IDFV),     deviceType = 'IOS'
  ///   - 취득 실패 시 deviceId = null (앱FE 가 localStorage UUID 로 graceful 폴백).
  Future<Map<String, dynamic>> _handleGetDeviceInfo() async {
    final deviceInfo = DeviceInfoPlugin();
    String? deviceId;
    String deviceType = 'UNKNOWN';
    String? model;
    String? osVersion;
    String? appVersion;

    try {
      // 앱 버전(공통).
      try {
        final pkg = await PackageInfo.fromPlatform();
        appVersion = pkg.version;
      } catch (e) {
        debugPrint('[GET_DEVICE_INFO] 앱버전 취득 실패: $e');
      }

      if (Platform.isAndroid) {
        deviceType = 'ANDROID';
        try {
          // ANDROID_ID — 재설치/앱데이터 삭제에도 유지(공장초기화 시만 변경).
          deviceId = await const AndroidId().getId();
        } catch (e) {
          debugPrint('[GET_DEVICE_INFO] ANDROID_ID 취득 실패: $e');
        }
        try {
          final a = await deviceInfo.androidInfo;
          model = a.model;
          osVersion = a.version.release;
        } catch (e) {
          debugPrint('[GET_DEVICE_INFO] androidInfo 취득 실패: $e');
        }
      } else if (Platform.isIOS) {
        deviceType = 'IOS';
        try {
          final i = await deviceInfo.iosInfo;
          deviceId = i.identifierForVendor; // IDFV
          model = i.utsname.machine;
          osVersion = i.systemVersion;
        } catch (e) {
          debugPrint('[GET_DEVICE_INFO] iosInfo 취득 실패: $e');
        }
      }

      debugPrint('[GET_DEVICE_INFO] type=$deviceType hasId=${deviceId != null}');
      return {
        'deviceId': deviceId,
        'deviceType': deviceType,
        'model': model,
        'osVersion': osVersion,
        'appVersion': appVersion,
      };
    } catch (e) {
      debugPrint('[GET_DEVICE_INFO] 취득 실패: $e');
      // 부분 실패여도 취득한 값까지 반환(앱FE 가 deviceId null 이면 폴백).
      return {
        'deviceId': deviceId,
        'deviceType': deviceType,
        'model': model,
        'osVersion': osVersion,
        'appVersion': appVersion,
      };
    }
  }

  /// GET_PUSH_TOKEN 브리지 핸들러 (prafta-com-008-F02).
  ///
  /// Vue 가 등록 직전(pull)에 호출한다. 알림 권한 상태를 확인/요청한 뒤 FCM 토큰을 취득해
  /// 계약대로 Map 을 반환한다. 토큰을 백엔드로 직접 보내지 않는다(비즈니스 로직 금지 — F-1 = Vue 경유).
  ///
  /// ★권한 요청 위치: 이 핸들러(= Vue 가 명시적으로 호출하는 단일 경로)에서만 requestPermission 을
  ///   호출한다. onResume 등 라이프사이클 콜백에 절대 박지 않는다
  ///   (메모리 project_prafta_app_perm_native_race — geolocator 와 Activity 단위 충돌 사고).
  ///
  /// 반환 계약:
  ///   { pushToken: String?, platform: 'android', permission: 'granted'|'denied' }
  ///   - 권한 거부 → permission='denied', pushToken=null
  ///   - 권한 허용이나 토큰 미발급/취득 실패 → permission='granted', pushToken=null
  Future<Map<String, dynamic>> _handleGetPushToken() async {
    const String platform = 'android';
    try {
      final messaging = FirebaseMessaging.instance;

      // 1) 알림 권한 확인/요청(단일 경로). iOS/Android13+ 모두 이 한 번의 요청으로 처리.
      final settings = await messaging.requestPermission();
      final bool granted =
          settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;

      if (!granted) {
        debugPrint('[GET_PUSH_TOKEN] 알림 권한 거부: ${settings.authorizationStatus}');
        return {'pushToken': null, 'platform': platform, 'permission': 'denied'};
      }

      // 2) iOS: APNs 토큰이 네이티브에서 비동기로 늦게 도착한다(특히 최초 로그인 직후
      //    requestPermission() 승인 직후에는 didRegisterForRemoteNotificationsWithDeviceToken
      //    콜백이 아직 안 왔을 수 있음). 이 상태에서 getToken() 을 먼저 부르면
      //    [firebase_messaging/apns-token-not-set] 예외가 난다(2026-08-10 TestFlight 실증 —
      //    작업지시서 iOS-푸시-미수신 문제 A). getAPNSToken() 이 찰 때까지 폴링한 뒤에만 진행한다.
      //    상한 12초 = JS 브리지 타임아웃(15초, 커밋 e2470835)보다 짧게 잡아 여유를 둔다.
      if (Platform.isIOS) {
        const stepMs = 300;
        const maxWaitMs = 12000;
        var waitedMs = 0;
        String? apnsToken = await messaging.getAPNSToken();
        while (apnsToken == null && waitedMs < maxWaitMs) {
          await Future.delayed(const Duration(milliseconds: stepMs));
          waitedMs += stepMs;
          apnsToken = await messaging.getAPNSToken();
        }
        debugPrint(apnsToken != null
            ? '[GET_PUSH_TOKEN] APNs 토큰 확보(대기 ${waitedMs}ms)'
            : '[GET_PUSH_TOKEN] APNs 토큰 미확보(${waitedMs}ms 초과)');

        // 미확보 시 네이티브 didFailToRegisterForRemoteNotificationsWithError 캡처값을
        // 로그로 남긴다(Xcode 콘솔 진단용 — iOS-푸시-미수신 작업지시서 문제 A 미해결 상태).
        if (apnsToken == null) {
          try {
            final nativeError = await _apnsDiagChannel.invokeMethod<String>(
              'getLastRegistrationError',
            );
            debugPrint(nativeError != null
                ? '[GET_PUSH_TOKEN] 네이티브 등록 실패: $nativeError'
                : '[GET_PUSH_TOKEN] 네이티브 실패 콜백 없음 — 등록 시도 자체가 무응답');
          } catch (e) {
            debugPrint('[GET_PUSH_TOKEN] 네이티브 진단 채널 조회 실패: $e');
          }
        }
      }

      // 3) FCM 토큰 취득(권한 허용이어도 환경에 따라 null 가능).
      String? token;
      try {
        token = await messaging.getToken();
      } catch (e) {
        debugPrint('[GET_PUSH_TOKEN] getToken 실패: $e');
      }

      debugPrint('[GET_PUSH_TOKEN] granted=$granted hasToken=${token != null}');
      return {'pushToken': token, 'platform': platform, 'permission': 'granted'};
    } catch (e) {
      // Firebase 미초기화(google-services.json 미배치 등) 포함 모든 실패는 denied 로 graceful 처리.
      debugPrint('[GET_PUSH_TOKEN] 취득 실패: $e');
      return {'pushToken': null, 'platform': platform, 'permission': 'denied'};
    }
  }

  /// SCAN_QR 브리지 핸들러 (결함 1.3-3: 관리자 TBM 일용직 QR 입실).
  ///
  /// Vue 가 QR 스캔을 요청한다. 카메라 권한을 확인/요청한 뒤 기존 QrScanPage 를
  /// Navigator 로 push 하여 스캔 결과(raw 문자열)를 받아 계약대로 반환한다.
  /// 비즈니스 로직(입실 처리)은 Vue→백엔드 몫이며, 여기서는 raw 값 취득·전달만 한다.
  ///
  /// 반환 계약:
  ///   - 성공:      {status:'OK', payload: raw 문자열}
  ///   - 사용자취소: {status:'CANCELLED'}
  ///   - 권한거부:   {status:'PERMISSION_DENIED'}
  ///   - 예외:      {status:'ERROR'}
  Future<Map<String, dynamic>> _handleScanQr() async {
    try {
      // 1) 카메라 권한 확인/요청(거부 시 PERMISSION_DENIED).
      var status = await Permission.camera.status;
      if (!status.isGranted) {
        status = await Permission.camera.request();
      }
      if (!status.isGranted) {
        debugPrint('[SCAN_QR] 카메라 권한 거부: $status');
        return {'status': 'PERMISSION_DENIED'};
      }

      // async gap 이후 context 사용 전 위젯 생존 확인.
      if (!mounted) return {'status': 'ERROR'};

      // 2) 기존 QrScanPage push -> 스캔 결과(raw 문자열) 수신. 취소/닫기는 null 반환.
      final raw = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const QrScanPage()),
      );

      if (raw == null || raw.isEmpty) {
        debugPrint('[SCAN_QR] 사용자 취소 또는 빈 결과');
        return {'status': 'CANCELLED'};
      }

      debugPrint('[SCAN_QR] OK len=${raw.length}');
      return {'status': 'OK', 'payload': raw};
    } catch (e) {
      debugPrint('[SCAN_QR] 스캔 실패: $e');
      return {'status': 'ERROR'};
    }
  }

  /// REQUEST_CAMERA_PERMISSION 브리지 핸들러.
  ///
  /// 웹뷰 QR 스캐너(html5-qrcode)가 getUserMedia 를 부르기 "전"에 네이티브 카메라
  /// 권한을 확인/요청한다.
  ///
  /// ★왜 필요한가 (2026-08-01 갤럭시 실측): 안드로이드 웹뷰는 네이티브 CAMERA 권한이
  ///   없을 때 getUserMedia 를 NotAllowedError(권한 거부)가 아니라
  ///   NotReadableError("Could not start video source")로 실패시킨다. 웹 쪽에서는
  ///   "권한 문제"인지 "카메라 점유"인지 구분할 수 없어 안내가 불가능하므로,
  ///   웹이 이 브리지로 권한을 선확인한다. (onPermissionRequest GRANT 는 웹뷰 레벨
  ///   허가일 뿐 OS 권한을 대신하지 못한다.)
  ///
  /// 반환 계약: {status:'GRANTED'|'DENIED'|'PERMANENTLY_DENIED'}
  ///   - PERMANENTLY_DENIED: 다시 묻지 않음(안드) / 프롬프트 소진(iOS) — 설정 이동만 가능.
  ///   - 예외 시 GRANTED 로 폴백: 여기서 막지 말고 실제 getUserMedia 실패 경로가 처리하게 한다.
  Future<Map<String, dynamic>> _handleRequestCameraPermission() async {
    try {
      var status = await Permission.camera.status;
      if (!status.isGranted && !status.isPermanentlyDenied) {
        status = await Permission.camera.request();
      }
      final result = status.isGranted
          ? 'GRANTED'
          : (status.isPermanentlyDenied || status.isRestricted)
              ? 'PERMANENTLY_DENIED'
              : 'DENIED';
      debugPrint('[REQUEST_CAMERA_PERMISSION] $status -> $result');
      return {'status': result};
    } catch (e) {
      debugPrint('[REQUEST_CAMERA_PERMISSION] 확인 실패(GRANTED 폴백): $e');
      return {'status': 'GRANTED'};
    }
  }

  /// OPEN_APP_SETTINGS 브리지 핸들러.
  ///
  /// 권한이 영구 거부된 뒤에는 앱 안에서 다시 물을 수단이 없고(iOS 는 시스템 권한
  /// 프롬프트를 최초 1회만 띄운다) 설정 앱에서 직접 켜는 길밖에 없다. 그런데
  /// 웹뷰에서 `window.location = 'app-settings:'` 로는 열리지 않는다 — 네이티브
  /// 전용 스킴이라 WKWebView 가 네비게이션에 실패하며 화면이 로딩 상태로 멈춘다.
  /// 그래서 네이티브가 대신 연다(permission_handler 의 openAppSettings).
  ///
  /// 반환: {status:'OK'} | {status:'ERROR'}
  Future<Map<String, dynamic>> _handleOpenAppSettings() async {
    try {
      final opened = await openAppSettings();
      debugPrint('[OPEN_APP_SETTINGS] opened=$opened');
      return {'status': opened ? 'OK' : 'ERROR'};
    } catch (e) {
      debugPrint('[OPEN_APP_SETTINGS] 실패: $e');
      return {'status': 'ERROR'};
    }
  }

  /// prafta-com-008-F02: FCM 토큰 refresh 를 Vue 로 push 한다.
  ///
  /// onTokenRefresh 발화 시 window.__onPushTokenRefresh(token) 콜백을 호출한다(push 모델).
  /// 토큰 문자열은 jsStringLiteral 로 안전 escape 한다. 등록 API 호출(JWT 가드 포함)은 Vue 몫.
  /// 구독은 앱 1회만 설정(onWebViewCreated)하고 dispose 에서 해제한다.
  void _subscribeTokenRefresh() {
    _tokenRefreshSub?.cancel();
    _tokenRefreshSub = FirebaseMessaging.instance.onTokenRefresh.listen(
      (token) {
        final ctl = _ctl;
        if (ctl == null) return;
        final literal = jsStringLiteral(token);
        debugPrint('[PUSH_TOKEN_REFRESH] refresh 수신 -> Vue push');
        // ignore: discarded_futures
        ctl.evaluateJavascript(
          source:
              "window.__onPushTokenRefresh && window.__onPushTokenRefresh($literal)",
        );
      },
      onError: (e) {
        debugPrint('[PUSH_TOKEN_REFRESH] 구독 오류: $e');
      },
    );
  }

  /// PRAFTA-WEB_001-5: 푸시 알림 탭(open) 라우팅 구독.
  ///
  /// - onMessageOpenedApp: 앱이 백그라운드일 때 알림을 탭해 복귀한 경우.
  /// - getInitialMessage: 앱이 종료 상태일 때 알림을 탭해 콜드스타트한 경우(1회).
  /// 둘 다 RemoteMessage.data 를 window.__onPushOpened 로 전달한다(라우팅은 Vue 몫).
  /// 구독은 앱 1회만 설정(onWebViewCreated)하고 dispose 에서 해제한다.
  void _subscribeMessageOpened() {
    _msgOpenedSub?.cancel();
    _msgOpenedSub = FirebaseMessaging.onMessageOpenedApp.listen(
      (message) {
        debugPrint('[PUSH_OPENED] onMessageOpenedApp 수신');
        _dispatchPushOpened(message);
      },
      onError: (e) {
        debugPrint('[PUSH_OPENED] 구독 오류: $e');
      },
    );

    // 콜드스타트(종료 상태에서 알림 탭) 초기 메시지 1회 확인. 페이지 로드 전이면 보관 후 flush.
    // ignore: discarded_futures
    FirebaseMessaging.instance.getInitialMessage().then((message) {
      if (message != null) {
        debugPrint('[PUSH_OPENED] getInitialMessage 수신(콜드스타트)');
        _dispatchPushOpened(message);
      }
    }).catchError((e) {
      debugPrint('[PUSH_OPENED] getInitialMessage 실패: $e');
    });
  }

  /// 작업지시서 iOS-푸시-미수신-및-포그라운드-알림-미표시 문제 B: 포그라운드 수신 구독.
  ///
  /// FirebaseMessaging.onMessage 를 구독하는 코드가 어디에도 없어 앱이 포그라운드일 때
  /// PUSH 배너가 전혀 뜨지 않던 결함의 수정. 표시 처리(안드 로컬 알림 / iOS 배너 옵션)는
  /// push_notifications.dart 에 위임한다(비즈니스 로직 금지 원칙 유지 — 여기서는 구독만).
  /// 구독은 앱 1회만 설정(onWebViewCreated)하고 dispose 에서 해제한다.
  void _subscribeForegroundMessages() {
    _foregroundMsgSub?.cancel();
    _foregroundMsgSub = FirebaseMessaging.onMessage.listen(
      (message) {
        debugPrint('[FOREGROUND_PUSH] onMessage 수신: ${message.messageId}');
        showForegroundNotification(message);
      },
      onError: (e) {
        debugPrint('[FOREGROUND_PUSH] 구독 오류: $e');
      },
    );
  }

  /// RemoteMessage.data(DATA_PAYLOAD)를 Vue 로 전달한다.
  /// 페이지 미로드(콜드스타트) 상태면 _pendingPushData 로 보관했다가 onLoadStop 에서 flush 한다.
  void _dispatchPushOpened(RemoteMessage message) {
    final data = message.data;
    if (data.isEmpty) return;
    if (!_pageLoaded || _ctl == null) {
      _pendingPushData = data;
      return;
    }
    _evalPushOpened(data);
  }

  /// data(Map)를 JSON 문자열로 직렬화하여 window.__onPushOpened 호출.
  void _evalPushOpened(Map<String, dynamic> data) {
    final ctl = _ctl;
    if (ctl == null) return;
    try {
      final json = jsonEncode(data);
      // ignore: discarded_futures
      ctl.evaluateJavascript(
        source:
            "window.__onPushOpened && window.__onPushOpened(${jsStringLiteral(json)})",
      );
    } catch (e) {
      debugPrint('[PUSH_OPENED] dispatch 실패: $e');
    }
  }

  InAppWebViewSettings _settings() => InAppWebViewSettings(
    javaScriptEnabled: true,
    mediaPlaybackRequiresUserGesture: false,
    useOnDownloadStart: true,
    useShouldOverrideUrlLoading: true,
    javaScriptCanOpenWindowsAutomatically: true,
    // T7 축소: 원격(https)·번들(http://localhost) 모두 혼합 콘텐츠 서브리소스가 없어 차단이 기본.
    mixedContentMode: MixedContentMode.MIXED_CONTENT_NEVER_ALLOW,
    builtInZoomControls: false,
    supportZoom: false,
    allowsInlineMediaPlayback: true,

    // 디버깅(T7 축소): 릴리즈는 WEBVIEW_DEBUG 빌드에서만 검사 허용(iOS Safari Inspector.
    // 안드 chrome://inspect 는 main.dart 의 setWebContentsDebuggingEnabled 가 담당).
    isInspectable: kDebugMode || _kWebviewDebug,

    // 파일 접근(T7 축소): 콘텐츠 오리진이 항상 http(s)라 file:// 접근 경로 자체가 없다.
    // 사진 첨부는 네이티브 파일 선택기 경유라 무관 — §7 R-9 실기기 시험으로 확인.
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    allowFileAccess: false,

    // WebRTC/iframe 힌트
    iframeAllow: "camera; microphone",
    iframeAllowFullscreen: true,
  );

  /// 첨부 다운로드 스트림 URL 판별(경로가 '/file-download' 로 끝남). 토큰 발급 EP
  /// ('/file-download-token')는 axios(JSON)로 처리되어 네비게이션이 아니므로 제외된다.
  bool _isDownloadUrl(WebUri? url) {
    if (url == null) return false;
    return url.path.endsWith('/file-download');
  }

  /// 다운로드 URL 을 외부 브라우저로 연다(파일 저장은 OS 다운로드 매니저가 처리).
  Future<void> _launchExternal(WebUri? url) async {
    if (url == null) return;
    try {
      final uri = Uri.parse(url.toString());
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) debugPrint('첨부 외부 열기 실패: $uri');
    } catch (e) {
      debugPrint('첨부 외부 열기 예외: $e');
    }
  }

  /// __SHELL__ 주입 JS (T1). Vue 측 shellCapability.js 계약:
  ///   { bridgeVersion, platform, appVersion, handlers[], loadSource }
  /// handlers 는 addJavaScriptHandler 등록 목록(_kBridgeHandlers)과 항상 일치해야 한다.
  /// jsonEncode 결과는 유효한 JS 객체 리터럴이므로 그대로 대입한다.
  String _shellInfoJS() {
    final info = <String, dynamic>{
      'bridgeVersion': _kBridgeVersion,
      'platform': Platform.isIOS ? 'ios' : 'android',
      'appVersion': _appVersion,
      'handlers': _kBridgeHandlers,
      'loadSource': _loadSource,
    };
    return 'window.__SHELL__ = ${jsonEncode(info)};';
  }

  /// 운영 백엔드 절대 URL(_kAppBaseUrl)을 페이지의 JS 번들이 실행되기 "전"(document-start)에
  /// window.__APP_BASE_URL__ 로 주입한다. Vue 의 axios 인스턴스는 모듈 로드 시점에
  /// baseURL 을 고정하므로, onLoadStop(페이지 로드 후) 주입은 이미 늦다.
  /// release APK 는 자산을 http://localhost 로 서빙해 상대경로(/prafta)가 번들 서버 자신을
  /// 가리키므로 이 절대 URL 주입이 백엔드 연결의 핵심이다.
  /// APP_BASE_URL 미지정(dev 등)이면 그 항목만 생략(vite 프록시 /prafta 그대로 사용).
  /// __SHELL__(T1) 은 dev/release 무관하게 항상 주입한다 — 능력 탐지는 양쪽 다 필요.
  UnmodifiableListView<UserScript> _initialUserScripts() {
    final scripts = <UserScript>[
      UserScript(
        source: _shellInfoJS(),
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ];
    if (_kAppBaseUrl.isNotEmpty) {
      scripts.add(
        UserScript(
          source: "window.__APP_BASE_URL__ = ${jsStringLiteral(_kAppBaseUrl)};",
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      );
    }
    return UnmodifiableListView<UserScript>(scripts);
  }

  /// 원격 매니페스트를 조회해 원격 진입 URL 을 판정한다(T4).
  ///
  /// 반환: 원격 진입 URL(원격 사용 가능) | null(번들 폴백 — D3).
  /// null 이 되는 경우: 호스트 미설정 / 타임아웃(D2) / HTTP 비200 / JSON 파싱 실패
  /// (캡티브 포털 N-4 방어) / enabled!=true(킬 스위치) / minShellBridgeVersion 초과(구셸 차단)
  /// / entry 가 경로가 아님(S-2: 외부 도메인 지정 거부).
  Future<String?> _decideRemoteEntry() async {
    if (_kRemoteAppUrl.isEmpty) return null;
    try {
      return await _fetchRemoteEntry().timeout(_kManifestTimeout);
    } on TimeoutException {
      debugPrint('⏱️ 매니페스트 조회 타임아웃(${_kManifestTimeout.inSeconds}s) → 번들 폴백');
      return null;
    } catch (e) {
      debugPrint('📄 매니페스트 조회 실패 → 번들 폴백: $e');
      return null;
    }
  }

  /// app-manifest.json 을 내려받아 엄격 검증한다. 실패는 예외로 던지고
  /// 타임아웃/폴백 판정은 _decideRemoteEntry 가 담당한다.
  Future<String?> _fetchRemoteEntry() async {
    HttpClient? client;
    try {
      client = HttpClient()..connectionTimeout = _kManifestTimeout;
      final req = await client.getUrl(
        Uri.parse('$_kRemoteAppUrl/app-manifest.json'),
      );
      final res = await req.close();
      if (res.statusCode != 200) {
        debugPrint('📄 매니페스트 HTTP ${res.statusCode} → 번들 폴백');
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      // ★JSON 엄격 파싱(N-4): 캡티브 포털이 가로챈 HTML 은 여기서 반드시 실패해야 한다.
      final data = jsonDecode(body);
      if (data is! Map) {
        debugPrint('📄 매니페스트 형식 오류(Map 아님) → 번들 폴백');
        return null;
      }
      if (data['enabled'] != true) {
        debugPrint('🔌 매니페스트 enabled!=true(킬 스위치) → 번들 폴백');
        return null;
      }
      final minVer = data['minShellBridgeVersion'];
      if (minVer is int && minVer > _kBridgeVersion) {
        debugPrint('🔢 셸 브리지 v$_kBridgeVersion < 요구 v$minVer → 번들 폴백');
        return null;
      }
      var entry = data['entry'];
      if (entry is! String || entry.isEmpty) entry = '/';
      if (!entry.startsWith('/')) {
        // S-2: entry 는 우리 호스트 하위 경로만 허용. 절대 URL(외부 도메인) 거부.
        debugPrint('🚫 매니페스트 entry 가 경로가 아님($entry) → 번들 폴백');
        return null;
      }
      return '$_kRemoteAppUrl$entry';
    } finally {
      client?.close(force: true);
    }
  }

  /// 원격 로딩 실패 시 번들로 1회 폴백한다(중복 진입 가드). onReceivedError(메인 프레임)와
  /// 원격 첫 로드 감시 타이머(_kRemoteLoadWatchdog) 양쪽에서 호출된다.
  Future<void> _fallbackToBundle(String reason) async {
    if (_loadSourceState != 'remote' || _remoteFallbackDone) return;
    _remoteFallbackDone = true;
    _remoteWatchdog?.cancel();
    _loadSourceState = 'bundle';
    debugPrint('🛟 원격 → 번들 폴백: $reason');
    await _ensureLocalhostAlive(); // 이미 살아 있으면 no-op(재기동 없음)
    await _ctl?.loadUrl(
      urlRequest: URLRequest(url: WebUri('http://localhost:$_kLocalhostPort/')),
    );
  }

  /// release: 원격 우선(매니페스트 판정) → 번들 폴백(InAppLocalhostServer, 현행 경로).
  /// debug:   LAN dev 서버 (_kAppDevUrl) — 기존 그대로.
  Future<void> _openInitialUrl(InAppWebViewController ctl) async {
    String url;
    if (!kReleaseMode) {
      url = _kAppDevUrl;
    } else {
      final remoteEntry = await _decideRemoteEntry();
      if (remoteEntry != null) {
        _loadSourceState = 'remote';
        url = remoteEntry;
        // N-1: 원격 진입 후 첫 로드가 시한 내에 끝나지 않으면 번들로 폴백.
        _remoteWatchdog?.cancel();
        _remoteWatchdog = Timer(_kRemoteLoadWatchdog, () {
          if (!_pageLoaded) {
            // ignore: discarded_futures
            _fallbackToBundle('첫 로드 감시 시한(${_kRemoteLoadWatchdog.inSeconds}s) 초과');
          }
        });
      } else {
        _loadSourceState = 'bundle';
        url = 'http://localhost:$_kLocalhostPort/';
      }
    }
    await ctl.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    debugPrint('🌐 Load initial URL -> $url (release=$kReleaseMode, source=$_loadSource)');
  }

  /// JS 콘솔 브릿지: 웹의 console.*을 Flutter 로그로 복제
  final String _consoleBridgeJS = r"""
  (function() {
    try {
      if (window.__console_bridge_patched__) return;
      window.__console_bridge_patched__ = true;

      function serializeArg(a) {
        try {
          if (a === null || a === undefined) return String(a);
          if (typeof a === 'string') return a;
          if (typeof File !== 'undefined' && a instanceof File) {
            return `[File name=${a.name}, type=${a.type}, size=${a.size}]`;
          }
          if (typeof Blob !== 'undefined' && a instanceof Blob) {
            return `[Blob type=${a.type}, size=${a.size}]`;
          }
          if (a instanceof Error) return `[Error ${a.message}]`;
          return JSON.stringify(a);
        } catch (e) {
          try { return String(a); } catch(_) { return '[Unserializable]'; }
        }
      }

      var levels = ['log','info','warn','error','debug'];
      levels.forEach(function(lvl){
        var orig = console[lvl] ? console[lvl].bind(console) : function(){};
        console[lvl] = function() {
          try {
            var args = Array.prototype.slice.call(arguments).map(serializeArg);
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('JS_CONSOLE', { level: lvl, args: args });
            }
          } catch (e) {}
          try { orig.apply(null, arguments); } catch (e) {}
        };
        
      });
    } catch (e) {}
  })();
  """;

  /// dart 문자열을 JS 문자열 리터럴로 안전 escape (single-quote + backslash)
  String jsStringLiteral(String raw) {
    final escaped = raw
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'");
    return "'$escaped'";
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
    );

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (didPop) return;
        await _handleBackPressed();
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              InAppWebView(
                initialSettings: _settings(),
                initialUserScripts: _initialUserScripts(),
                onWebViewCreated: (controller) async {
                  _ctl = controller;
                  debugPrint('WebView created');

                  _ctl?.addJavaScriptHandler(
                    handlerName: 'JS_CONSOLE',
                    callback: (args) {
                      try {
                        final payload = (args.isNotEmpty ? args[0] : null) as Map?;
                        final level = payload?['level'] ?? 'log';
                        final lst = (payload?['args'] ?? []) as List?;
                        final msg = (lst ?? []).join(' ');
                        debugPrint('[JS][$level] $msg');
                      } catch (e) {
                        debugPrint('[JS][bridge] parse error: $e');
                      }
                      return null;
                    },
                  );

                  // GET_GPS 브리지: 웹(Vue)이 네이티브 현재 위치를 요청.
                  // 응답 계약: {status, lat, lon, accuracy, isMocked}
                  //   status: 'OK' | 'PERMISSION_DENIED' | 'SERVICE_DISABLED' | 'TIMEOUT'
                  _ctl?.addJavaScriptHandler(
                    handlerName: 'GET_GPS',
                    callback: (args) async {
                      return await _handleGetGps();
                    },
                  );

                  // GET_DEVICE_INFO 브리지 (prafta-com-003 C1): 네이티브 디바이스ID/메타 pull.
                  // 응답 계약: {deviceId, deviceType:'ANDROID'|'IOS', model, osVersion, appVersion}
                  _ctl?.addJavaScriptHandler(
                    handlerName: 'GET_DEVICE_INFO',
                    callback: (args) async {
                      return await _handleGetDeviceInfo();
                    },
                  );

                  // GET_APP_FOREGROUND_SEC 브리지 (prafta-051-09): 앱 포그라운드 누적초 pull.
                  // 응답 계약: {status:'OK', foregroundSec:int}
                  // 누적/합산/반환만 담당(비즈니스 로직 금지). 귀속·NULL·저장은 Vue/백엔드 몫.
                  _ctl?.addJavaScriptHandler(
                    handlerName: 'GET_APP_FOREGROUND_SEC',
                    callback: (args) {
                      return {
                        'status': 'OK',
                        'foregroundSec': _currentForegroundSec(),
                      };
                    },
                  );

                  // GET_PUSH_TOKEN 브리지 (prafta-com-008-F02): FCM 토큰 + 알림권한 pull.
                  // 응답 계약: {pushToken:String?, platform:'android', permission:'granted'|'denied'}
                  // 토큰 백엔드 등록은 Vue 몫(비즈니스 로직 금지). 권한 요청은 이 단일 경로에서만.
                  _ctl?.addJavaScriptHandler(
                    handlerName: 'GET_PUSH_TOKEN',
                    callback: (args) async {
                      return await _handleGetPushToken();
                    },
                  );

                  // SCAN_QR 브리지 (결함 1.3-3): 관리자 TBM 일용직 QR 입실 스캔 pull.
                  // 응답 계약: {status:'OK', payload:<raw>} | {status:'CANCELLED'}
                  //   | {status:'PERMISSION_DENIED'} | {status:'ERROR'}
                  // 스캔 결과 raw 만 전달(비즈니스 로직 금지). 입실 처리는 Vue→백엔드 몫.
                  _ctl?.addJavaScriptHandler(
                    handlerName: 'SCAN_QR',
                    callback: (args) async {
                      return await _handleScanQr();
                    },
                  );

                  // OPEN_APP_SETTINGS 브리지: 권한 거부 폴백 화면의 '설정으로 이동'.
                  // 응답 계약: {status:'OK'} | {status:'ERROR'}
                  // 웹뷰에서 window.location='app-settings:' 로는 열 수 없다(네이티브 전용 스킴).
                  _ctl?.addJavaScriptHandler(
                    handlerName: 'OPEN_APP_SETTINGS',
                    callback: (args) async {
                      return await _handleOpenAppSettings();
                    },
                  );

                  // REQUEST_CAMERA_PERMISSION 브리지: 웹뷰 QR 스캐너의 카메라 권한 선확인.
                  // 응답 계약: {status:'GRANTED'|'DENIED'|'PERMANENTLY_DENIED'}
                  // 안드 웹뷰가 권한 부재를 NotReadableError 로 뭉개는 문제의 우회 — 상세는 핸들러 주석.
                  _ctl?.addJavaScriptHandler(
                    handlerName: 'REQUEST_CAMERA_PERMISSION',
                    callback: (args) async {
                      return await _handleRequestCameraPermission();
                    },
                  );

                  // 토큰 refresh push (prafta-com-008-F02): onTokenRefresh -> window.__onPushTokenRefresh.
                  // 컨트롤러 확보 후 1회 구독(dispose 에서 해제).
                  _subscribeTokenRefresh();

                  // 푸시 탭(open) 라우팅 (PRAFTA-WEB_001-5): onMessageOpenedApp/getInitialMessage
                  // -> window.__onPushOpened. 컨트롤러 확보 후 1회 구독(dispose 에서 해제).
                  _subscribeMessageOpened();

                  // 포그라운드 PUSH 표시: onMessage 구독(문제 B). 컨트롤러 확보 후 1회 구독.
                  _subscribeForegroundMessages();

                  await _openInitialUrl(controller);
                },

                onLoadStart: (controller, url) async {
                  setState(() => _status = 'pageStarted: $url');
                  debugPrint('onLoadStart: $url');
                },

                onLoadStop: (controller, url) async {
                  setState(() => _status = 'pageFinished: $url');
                  debugPrint('onLoadStop: $url');

                  // T4: 원격 첫 로드 감시 해제(정상 도달).
                  _remoteWatchdog?.cancel();
                  _remoteWatchdog = null;

                  // PRAFTA-WEB_001-5: 페이지 로드 완료 표시 + 콜드스타트 보류 푸시 payload flush.
                  //   (window.__onPushOpened 는 Vue 가 App.vue onMounted 에서 등록 → 페이지 로드 후 호출)
                  _pageLoaded = true;
                  final pending = _pendingPushData;
                  if (pending != null) {
                    _pendingPushData = null;
                    _evalPushOpened(pending);
                  }

                  try {
                    await controller.evaluateJavascript(source: _consoleBridgeJS);
                    debugPrint('✅ console bridge injected');
                  } catch (e) {
                    debugPrint('❌ console bridge inject failed: $e');
                  }

                  // APP_BASE_URL 재확인용 주입(보조). 실제 baseURL 결정은 document-start
                  // 주입(_initialUserScripts)이 담당한다. 여기서는 같은 값을 한 번 더 보장만 한다.
                  if (_kAppBaseUrl.isNotEmpty) {
                    try {
                      await controller.evaluateJavascript(
                        source: "window.__APP_BASE_URL__ = ${jsStringLiteral(_kAppBaseUrl)};",
                      );
                      debugPrint('🌐 APP_BASE_URL injected to window.__APP_BASE_URL__');
                    } catch (e) {
                      debugPrint('❌ APP_BASE_URL inject failed: $e');
                    }
                  }

                  // __SHELL__ 재주입(보조, T1). document-start 시점에는 _appVersion 이
                  // 아직 비어 있을 수 있어 취득 완료값으로 한 번 더 덮어쓴다.
                  try {
                    await controller.evaluateJavascript(source: _shellInfoJS());
                    debugPrint('✅ __SHELL__ injected (v$_kBridgeVersion, $_loadSource)');
                  } catch (e) {
                    debugPrint('❌ __SHELL__ inject failed: $e');
                  }

                  try {
                    await controller.evaluateJavascript(source: _scanPickersJS);
                    debugPrint('🔎 post-finish scan executed');
                  } catch (_) {}

                  try {
                    final current = await controller.getUrl();
                    debugPrint('currentUrl(after finished) = $current');
                  } catch (_) {}
                },

                onProgressChanged: (controller, progress) {
                  setState(() => _progress = progress);
                },

                shouldOverrideUrlLoading: (controller, navAction) async {
                  final url = navAction.request.url;
                  debugPrint('shouldOverrideUrlLoading -> $url');
                  // 첨부 다운로드(/file-download)는 웹뷰가 octet-stream 을 직접 렌더하지 못하고
                  // 연결만 끊겨 백엔드 스트리밍 오류(broken pipe)가 난다. 외부 브라우저로 위임하고
                  // 웹뷰 자체 로드는 취소해 서버 요청 자체를 만들지 않는다.
                  if (_isDownloadUrl(url)) {
                    await _launchExternal(url);
                    return NavigationActionPolicy.CANCEL;
                  }
                  return NavigationActionPolicy.ALLOW;
                },

                // useOnDownloadStart 안전망: shouldOverrideUrlLoading 으로 못 잡은
                // 다운로드(window.open/새 창 경유 등)도 외부 브라우저로 위임한다.
                onDownloadStartRequest: (controller, downloadRequest) async {
                  debugPrint('onDownloadStartRequest -> ${downloadRequest.url}');
                  await _launchExternal(downloadRequest.url);
                },

                onPermissionRequest: (controller, request) async {
                  debugPrint('onPermissionRequest: ${request.resources}');
                  return PermissionResponse(
                    resources: request.resources,
                    action: PermissionResponseAction.GRANT,
                  );
                },

                // T4/S-3: 인증서 오류 무조건 PROCEED 폐지. 무효 인증서는 debug(LAN dev
                // 서버 자가서명)에서만 허용하고, release 는 CANCEL → 메인 프레임 오류
                // → onReceivedError 의 번들 폴백으로 이어진다. 정상 인증서는 이 콜백
                // 자체가 오지 않으므로 release 원격/API 통신에는 영향이 없다.
                onReceivedServerTrustAuthRequest: (controller, challenge) async {
                  debugPrint('onReceivedServerTrustAuthRequest: ${challenge.protectionSpace.host}');
                  if (!kReleaseMode) {
                    return ServerTrustAuthResponse(
                      action: ServerTrustAuthResponseAction.PROCEED,
                    );
                  }
                  debugPrint('🚫 release 무효 인증서 거부(S-3): ${challenge.protectionSpace.host}');
                  return ServerTrustAuthResponse(
                    action: ServerTrustAuthResponseAction.CANCEL,
                  );
                },

                onConsoleMessage: (controller, msg) {
                  debugPrint('console[${msg.messageLevel}] ${msg.message}');
                },

                onReceivedError: (controller, request, error) {
                  debugPrint('onReceivedError: ${error.type} ${error.description} for ${request.url}');
                  setState(() => _status = 'error: ${error.type} ${error.description}');

                  // T4: 원격 소스의 메인 프레임 로드 실패(DNS 실패·연결 거부·인증서 CANCEL 등)
                  // → 번들 폴백(L-3/L-5). 서브리소스 실패는 폴백 사유가 아니다.
                  if (request.isForMainFrame == true && _loadSourceState == 'remote') {
                    // ignore: discarded_futures
                    _fallbackToBundle('메인 프레임 오류 ${error.type}');
                  }
                },

                // iOS 전용: 메모리 압박으로 WKWebView 의 WebContent 프로세스가 죽으면
                // 웹뷰가 백지가 되고 어떤 조작도 먹지 않는다. 복구 수단은 reload 뿐이다.
                // (장수 웹뷰를 띄우는 앱에는 사실상 필수 핸들러다.)
                // 프로세스가 죽을 만한 상황이면 로컬 서버도 함께 회수됐을 수 있어 먼저 확인한다.
                onWebContentProcessDidTerminate: (controller) async {
                  debugPrint('💥 WebContent 프로세스 종료 -> 로컬 서버 확인 후 reload');
                  await _ensureLocalhostAlive();
                  await controller.reload();
                },
              ),

              if (_progress < 100)
                const Positioned(
                  top: 0, left: 0, right: 0,
                  child: LinearProgressIndicator(),
                ),

              if (!kReleaseMode)
                Positioned(
                  bottom: 8, left: 8, right: 8,
                  child: Text(
                    _status,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
