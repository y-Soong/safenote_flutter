import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 프리뷰 진단 모드. iOS 절반 검정 원인 규명용 임시 계측이며, 원인 확정 후 false 로 되돌린다.
///
/// 켜면 두 가지가 바뀐다:
///  1) Scaffold 배경을 자홍색으로 바꾼다 — 검정 영역이 자홍색으로 변하면 그 영역은
///     "카메라 위젯 바깥"(레이아웃 문제)이고, 그대로 검정이면 "카메라 텍스처 안"(버퍼 문제)이다.
///     이 한 가지로 원인 계열이 둘 중 하나로 확정된다.
///  2) 네이티브가 보고한 프리뷰 크기/방향과 실제 위젯 크기를 화면에 띄운다.
///     debugPrint 는 Mac 의 Console.app 없이는 볼 수 없어 TestFlight 검증에 쓸 수 없다.
const bool kQrPreviewDiagnostics = true;

class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final MobileScannerController _controller = MobileScannerController(
    // torchEnabled: true,       // 필요시 기본 플래시 ON
    // facing: CameraFacing.back,
    detectionSpeed: DetectionSpeed.noDuplicates,
    // 안드로이드 전용 옵션(iOS 무시). mobile_scanner 7.4.0 은 ImageAnalysis 해상도를
    // 프리뷰 사이즈로 Flutter 에 보고하는데, 미지정 시 기본 1920x1080(16:9)이 강제되어
    // 실제 Preview 스트림(CameraX 기본 4:3)과 화면비가 어긋나면 프리뷰 하단이 검게 남는다.
    // 4:3 으로 명시해 보고 사이즈와 실제 스트림 화면비를 정렬한다.
    cameraResolution: const Size(1440, 1080),
  );
  bool _handled = false;
  bool _sizeLogged = false;

  @override
  void initState() {
    super.initState();
    // 실기기 검증용: 네이티브가 보고한 프리뷰 사이즈/방향 1회 로깅 (adb logcat 확인).
    _controller.addListener(_logPreviewSize);
  }

  void _logPreviewSize() {
    final v = _controller.value;
    if (_sizeLogged || !v.isInitialized || v.size == Size.zero) return;
    _sizeLogged = true;
    debugPrint(
      '[QR_PREVIEW] size=${v.size.width.toInt()}x${v.size.height.toInt()}'
      ' orientation=${v.deviceOrientation}',
    );
  }

  @override
  void dispose() {
    _controller.removeListener(_logPreviewSize);
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final codes = capture.barcodes;
    if (codes.isEmpty) return;

    final raw = codes.first.rawValue ?? '';
    _handled = true;
    Navigator.pop(context, raw); // ✅ 스캔값을 호출자에게 반환
  }

  /// 진단 오버레이. 네이티브가 보고한 프리뷰 크기·방향과 화면 크기를 화면에 직접 띄운다.
  /// (TestFlight 빌드는 로그를 볼 수단이 없으므로 화면 출력이 유일한 계측 경로다.)
  Widget _buildDiagnosticsOverlay(BuildContext context) {
    final media = MediaQuery.of(context);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: ValueListenableBuilder<MobileScannerState>(
          valueListenable: _controller,
          builder: (context, value, _) {
            final size = value.size;
            final ratio =
                size.height == 0
                    ? '-'
                    : (size.width / size.height).toStringAsFixed(3);
            final screen = media.size;
            final screenRatio = (screen.width / screen.height).toStringAsFixed(3);

            return Container(
              width: double.infinity,
              color: Colors.black.withValues(alpha: 0.72),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: DefaultTextStyle(
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  height: 1.45,
                  fontFamily: 'monospace',
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('init=${value.isInitialized}  err=${value.error?.errorCode.name ?? "-"}'),
                    Text(
                      'preview=${size.width.toStringAsFixed(0)}x'
                      '${size.height.toStringAsFixed(0)}  ratio=$ratio',
                    ),
                    Text('orientation=${value.deviceOrientation.name}'),
                    Text(
                      'screen=${screen.width.toStringAsFixed(0)}x'
                      '${screen.height.toStringAsFixed(0)}  ratio=$screenRatio'
                      '  dpr=${media.devicePixelRatio.toStringAsFixed(2)}',
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 진단 모드에서는 배경을 자홍색으로 둔다. 검정 영역의 정체(위젯 바깥 vs 텍스처 안)를
      // 스크린샷 한 장으로 가른다 — 자홍색이면 레이아웃, 검정 그대로면 카메라 버퍼.
      backgroundColor: kQrPreviewDiagnostics ? const Color(0xFFFF00AA) : Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // 기본값과 동일하지만 전체화면 크롭 의도를 명시(화면비 검증 이슈 재발 방지).
            fit: BoxFit.cover,
            // 초기화 전 기본 플레이스홀더가 검정이라 진단 시 "텍스처 검정"과 혼동된다.
            // 진단 모드에서만 파란색으로 바꿔 세 상태를 색으로 분리한다.
            placeholderBuilder:
                kQrPreviewDiagnostics
                    ? (context) => const ColoredBox(color: Color(0xFF0033AA))
                    : null,
          ),
          if (kQrPreviewDiagnostics) _buildDiagnosticsOverlay(context),
          // 상단 닫기 버튼
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context, null),
              ),
            ),
          ),
          // 중앙 스캔 가이드 박스 (옵션)
          IgnorePointer(
            child: Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.white70, width: 2),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
