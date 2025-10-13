import 'dart:io' show Platform;
import 'dart:convert' show json;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'qr_scan_page.dart'; // ✅ 네이티브 스캐너

const bool USE_LOCAL_ASSET = false;
const String DEV_URL = "https://172.30.1.4:8082";

const _LOG_CH = 'LOG';
const _ERR_CH = 'ERR';

class WebApp extends StatefulWidget {
  const WebApp({super.key});
  @override
  State<WebApp> createState() => _WebAppState();
}

class _WebAppState extends State<WebApp> {
  late final WebViewController _ctl;
  int _progress = 0;
  String _status = 'init';

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _setupWebView();
  }

  Future<void> _requestPermissions() async {
    // 카메라/마이크/위치 권한 사전요청 (필요 범위만 선택해도 됨)
    final statuses = await [
      Permission.camera,
      Permission.microphone,
      Permission.location, // 위치가 필요 없다면 제거
    ].request();

    final allGranted = statuses.values.every((s) => s.isGranted);
    if (!allGranted) {
      // 사용자가 거부한 경우 설정 이동 유도
      await openAppSettings();
    }
  }

  void _setupWebView() {
    late final PlatformWebViewControllerCreationParams params;
    if (WebViewPlatform.instance is AndroidWebViewPlatform) {
      params = AndroidWebViewControllerCreationParams();
    } else {
      params = const PlatformWebViewControllerCreationParams();
    }

    final controller = WebViewController.fromPlatformCreationParams(params)
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(_LOG_CH,
          onMessageReceived: (msg) => debugPrint('console: ${msg.message}'))
      ..addJavaScriptChannel(_ERR_CH,
          onMessageReceived: (msg) => debugPrint('console.error: ${msg.message}'))
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (p) => setState(() => _progress = p),
          onPageStarted: (url) => setState(() => _status = 'loading: $url'),
          onPageFinished: (url) async {
            setState(() => _status = 'finished: $url');
            await _injectDebugHooks();
          },
          // ✅ 여기서 Web 경로를 가로채 네이티브 스캐너로 전환
          onNavigationRequest: (req) {
            final url = req.url;
            // Vue 라우트가 '#/QrScanner' 로 진입하려 할 때
            if (url.contains('#/QrScanner')) {
              _openNativeScanner(); // 네이티브 QR 스캐너 실행
              return NavigationDecision.prevent; // 웹뷰 전환 차단
            }
            return NavigationDecision.navigate;
          },
          onWebResourceError: (err) {
            setState(() => _status = 'error: ${err.errorCode} ${err.description}');
            debugPrint('resourceError: code=${err.errorCode} desc=${err.description}');
          },
        ),
      );

    if (controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      AndroidWebViewController.enableDebugging(true);
      androidController.setMediaPlaybackRequiresUserGesture(false);

      // (옵션) 파일 선택/캡쳐 요청 대응
      androidController.setOnShowFileSelector((params) async {
        debugPrint('📷 WebView file/capture request (ignored).');
        return <String>[];
      });
    }

    _ctl = controller;
    _load();
  }

  Future<void> _load() async {
    if (USE_LOCAL_ASSET) {
      // 자산 확인 (필수는 아님)
      final manifest = await rootBundle.loadString('AssetManifest.json');
      final assets = json.decode(manifest) as Map<String, dynamic>;
      for (final path in const [
        'assets/vue_app/index.html',
        'assets/vue_app/js/chunk-vendors.0250f8dc.js',
        'assets/vue_app/js/app.a8aec3b6.js',
        'assets/vue_app/css/app.704180ee.css',
      ]) {
        debugPrint('[ASSET ${assets.keys.contains(path) ? "OK" : "MISS"}] $path');
      }

      await rootBundle.loadString('assets/vue_app/index.html');
      await _ctl.loadFlutterAsset('assets/vue_app/index.html');
    } else {
      await _ctl.loadRequest(Uri.parse(DEV_URL));
    }
  }

  // ✅ 네이티브 스캐너 열고 결과를 웹뷰로 전달
  Future<void> _openNativeScanner() async {
    final result = await Navigator.of(context).push<String?>(
      MaterialPageRoute(builder: (_) => const QrScanPage()),
    );

    if (result == null || result.isEmpty) return;

    // 1) 웹뷰 라우터로 결과 페이지로 이동 (Vue: #/QrResultView?qr=...)
    final escaped = Uri.encodeComponent(result);
    await _ctl.runJavaScript("""
      try {
        // Vue Router 사용 가정
        window.location.hash = '#/QrResultView?qr=$escaped';
      } catch (e) {
        console.error('route change error:', e);
      }
    """);

    // 2) 혹은 커스텀 이벤트로 결과 전달 (원하는 방식 택1)
    // await _ctl.runJavaScript("""
    //   window.dispatchEvent(new CustomEvent('qr-scanned', { detail: '$escaped' }));
    // """);
  }

  Future<void> _injectDebugHooks() async {
    const js = r'''
      (function() {
        window.addEventListener('error', function(e) {
          try {
            var t = e.target || {};
            var src = t.src || t.href || (t.tagName ? t.tagName : '');
            LOG.postMessage('resource error: ' + src);
          } catch (_) {}
        }, true);

        window.onerror = function(msg, url, line, col, err) {
          ERR.postMessage('onerror: ' + msg + ' @' + url + ':' + line + ':' + col);
        };

        var origLog = console.log, origErr = console.error, origWarn = console.warn;
        console.log = function(){ try { LOG.postMessage([].map.call(arguments, String).join(' ')); } catch(_){}; origLog.apply(console, arguments); };
        console.error = function(){ try { ERR.postMessage([].map.call(arguments, String).join(' ')); } catch(_){}; origErr.apply(console, arguments); };
        console.warn = function(){ try { LOG.postMessage('warn: ' + [].map.call(arguments, String).join(' ')); } catch(_){}; origWarn.apply(console, arguments); };

        try {
          LOG.postMessage('baseURI=' + document.baseURI);
        } catch(_) {}
      })();
    ''';
    await _ctl.runJavaScript(js);
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (await _ctl.canGoBack()) {
          _ctl.goBack();
          return false;
        }
        return true;
      },
      child: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: _ctl),
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
