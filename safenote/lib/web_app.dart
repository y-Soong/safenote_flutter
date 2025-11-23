import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:permission_handler/permission_handler.dart';

const String DEV_URL = "https://172.30.1.4:8082";

class WebApp extends StatefulWidget {
  const WebApp({super.key});
  @override
  State<WebApp> createState() => _WebAppState();
}

class _WebAppState extends State<WebApp> with WidgetsBindingObserver {
  InAppWebViewController? _ctl;
  int _progress = 0;
  String _status = 'init';

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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 앱 라이프사이클: 카메라 앱 다녀온 후(RESUMED) 강제 스캔
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ctl != null) {
      debugPrint('🔎 App RESUMED -> scan hidden file inputs');
      _ctl!.evaluateJavascript(source: _scanPickersJS);
    }
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

  Future<void> _openDevServer(InAppWebViewController ctl) async {
    await ctl.loadUrl(urlRequest: URLRequest(url: WebUri(DEV_URL)));
    debugPrint('🌐 Load DEV_URL -> $DEV_URL');
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

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle.dark.copyWith(statusBarColor: Colors.transparent),
    );

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            InAppWebView(
              initialSettings: _settings(),

              onWebViewCreated: (controller) async {
                _ctl = controller;
                debugPrint('WebView created');

                // JS → Flutter 로그 브릿지 핸들러
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

                await _openDevServer(controller);
              },

              onLoadStart: (controller, url) async {
                setState(() => _status = 'pageStarted: $url');
                debugPrint('onLoadStart: $url');
              },

              onLoadStop: (controller, url) async {
                setState(() => _status = 'pageFinished: $url');
                debugPrint('onLoadStop: $url');

                // 콘솔 브릿지 주입
                try {
                  await controller.evaluateJavascript(source: _consoleBridgeJS);
                  debugPrint('✅ console bridge injected');
                } catch (e) {
                  debugPrint('❌ console bridge inject failed: $e');
                }

                // 로드 완료 직후 한 번 스캔 (change 누락 기기 대응)
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
                return NavigationActionPolicy.ALLOW;
              },

              onPermissionRequest: (controller, request) async {
                debugPrint('onPermissionRequest: ${request.resources}');
                return PermissionResponse(
                  resources: request.resources,
                  action: PermissionResponseAction.GRANT,
                );
              },

              // (안드) 파일 선택기 진입 로깅 — 문제 발생 시 추적에 도움
              // androidOnShowFileChooser: (controller, params) async {
              //   debugPrint(
              //       'androidOnShowFileChooser: accept=${params.acceptTypes} '
              //           'capture=${params.isCaptureEnabled} '
              //           'mode=${params.mode} '
              //           'filenameHint=${params.filenameHint}');
              //   // 기본 시스템 파일선택기 사용
              //   return null;
              // },

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
    );
  }
}
