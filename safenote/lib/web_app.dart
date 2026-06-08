import 'dart:async' show TimeoutException;
import 'dart:collection' show UnmodifiableListView;
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:android_id/android_id.dart';
import 'package:url_launcher/url_launcher.dart';

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

  DateTime? _lastBackPressedAt; // ✅ 추가

  // prafta-051-09: 앱 포그라운드 누적초(단조 증가, TBM 세션 무관 전역 누적).
  // - _fgAccumSec: 지금까지 누적된 포그라운드 시간(초).
  // - _fgResumedAt: 현재 포그라운드 진입 시각(떠 있는 동안만 non-null).
  // GET_APP_FOREGROUND_SEC 브리지가 (_fgAccumSec + 진행중 경과초)를 반환한다.
  // 누적/합산/반환만 담당하며, 세션 귀속·NULL 처리·저장은 Vue/백엔드 몫(비즈니스 로직 금지).
  // 한계: 시스템 강제종료(detached 미수신) 시 마지막 진행분이 유실될 수 있다.
  int _fgAccumSec = 0;
  DateTime? _fgResumedAt;

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
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      // prafta-051-09: 포그라운드 → 백그라운드 전환. 진행분을 누적에 확정.
      _accumulateForeground();
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
      final results = await [
        Permission.camera,
        Permission.photos,   // Android 13+: READ_MEDIA_IMAGES
        Permission.storage,  // Android 12 이하 호환
        Permission.microphone,
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

  InAppWebViewSettings _settings() => InAppWebViewSettings(
    javaScriptEnabled: true,
    mediaPlaybackRequiresUserGesture: false,
    useOnDownloadStart: true,
    useShouldOverrideUrlLoading: true,
    javaScriptCanOpenWindowsAutomatically: true,
    mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
    builtInZoomControls: false,
    supportZoom: false,
    allowsInlineMediaPlayback: true,

    // 디버깅: chrome://inspect
    isInspectable: true,

    // 파일 접근
    allowFileAccessFromFileURLs: true,
    allowUniversalAccessFromFileURLs: true,
    allowFileAccess: true,

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

  /// 운영 백엔드 절대 URL(_kAppBaseUrl)을 페이지의 JS 번들이 실행되기 "전"(document-start)에
  /// window.__APP_BASE_URL__ 로 주입한다. Vue 의 axios 인스턴스는 모듈 로드 시점에
  /// baseURL 을 고정하므로, onLoadStop(페이지 로드 후) 주입은 이미 늦다.
  /// release APK 는 자산을 http://localhost 로 서빙해 상대경로(/prafta)가 번들 서버 자신을
  /// 가리키므로 이 절대 URL 주입이 백엔드 연결의 핵심이다.
  /// APP_BASE_URL 미지정(dev 등)이면 빈 목록 → 주입 없음(vite 프록시 /prafta 그대로 사용).
  UnmodifiableListView<UserScript> _initialUserScripts() {
    if (_kAppBaseUrl.isEmpty) {
      return UnmodifiableListView<UserScript>(const []);
    }
    return UnmodifiableListView<UserScript>([
      UserScript(
        source: "window.__APP_BASE_URL__ = ${jsStringLiteral(_kAppBaseUrl)};",
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      ),
    ]);
  }

  /// release: InAppLocalhostServer (번들된 Vue 자산)
  /// debug:   LAN dev 서버 (_kAppDevUrl)
  Future<void> _openInitialUrl(InAppWebViewController ctl) async {
    final url = kReleaseMode
        ? 'http://localhost:$_kLocalhostPort/'
        : _kAppDevUrl;
    await ctl.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
    debugPrint('🌐 Load initial URL -> $url (release=$kReleaseMode)');
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

                  await _openInitialUrl(controller);
                },

                onLoadStart: (controller, url) async {
                  setState(() => _status = 'pageStarted: $url');
                  debugPrint('onLoadStart: $url');
                },

                onLoadStop: (controller, url) async {
                  setState(() => _status = 'pageFinished: $url');
                  debugPrint('onLoadStop: $url');

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

                onReceivedServerTrustAuthRequest: (controller, challenge) async {
                  debugPrint('onReceivedServerTrustAuthRequest: ${challenge.protectionSpace.host}');
                  return ServerTrustAuthResponse(
                    action: ServerTrustAuthResponseAction.PROCEED,
                  );
                },

                onConsoleMessage: (controller, msg) {
                  debugPrint('console[${msg.messageLevel}] ${msg.message}');
                },

                onReceivedError: (controller, request, error) {
                  debugPrint('onReceivedError: ${error.type} ${error.description} for ${request.url}');
                  setState(() => _status = 'error: ${error.type} ${error.description}');
                },
              ),

              if (_progress < 100)
                const Positioned(
                  top: 0, left: 0, right: 0,
                  child: LinearProgressIndicator(),
                ),

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
