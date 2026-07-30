import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            // 기본값과 동일하지만 전체화면 크롭 의도를 명시(화면비 검증 이슈 재발 방지).
            fit: BoxFit.cover,
          ),
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
