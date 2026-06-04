import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'web_app.dart';

/// 카메라권한 하드 게이트.
///
/// 앱 기동 시(위치권한 게이트 통과 후) 카메라권한을 필수로 요구한다. 권한이
/// 허용되기 전에는 웹뷰(WebApp)로 진입할 수 없다. 즉 카메라 미동의 = 앱 사용 불가.
///
/// QR 스캔(안전점검 입실/점검 개소 인식)이 앱의 핵심 동선이므로 위치권한과
/// 동일하게 하드 게이트로 둔다.
///
/// - 권한 거부(denied) → 재요청 버튼.
/// - 영구 거부(permanentlyDenied) / 제한(restricted) → openAppSettings() 로
///   앱 설정 화면 유도.
///
/// 실제 카메라 사용(스캔/촬영)은 각 화면 몫이며, 여기서는 권한 게이트만 담당한다.
class CameraGate extends StatefulWidget {
  const CameraGate({super.key, this.next = const WebApp()});

  /// 카메라권한 허용 후 진입할 위젯(기본 [WebApp]).
  final Widget next;

  @override
  State<CameraGate> createState() => _CameraGateState();
}

/// 게이트 내부 상태.
enum _GateStatus {
  checking, // 권한 확인 중
  denied, // 권한 거부(재요청 가능)
  permanentlyDenied, // 영구 거부/제한(설정 이동 필요)
  granted, // 허용됨 → 다음 위젯 진입
}

class _CameraGateState extends State<CameraGate> with WidgetsBindingObserver {
  _GateStatus _status = _GateStatus.checking;
  bool _busy = false; // 중복 요청 방지

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 최초 진입 시 권한 평가 + 요청.
    _evaluateAndRequest();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 앱 설정 화면(영구거부 시) 다녀온 뒤 복귀하면 권한을 재평가한다.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        _status != _GateStatus.granted &&
        !_busy) {
      _evaluateAndRequest(requestIfDenied: false);
    }
  }

  /// 카메라 권한 상태를 평가하고, 거부 상태면 권한을 요청한다.
  ///
  /// [requestIfDenied] 가 false 면(설정 복귀 등) 평가만 하고 시스템 권한
  /// 다이얼로그를 다시 띄우지 않는다.
  Future<void> _evaluateAndRequest({bool requestIfDenied = true}) async {
    if (_busy) return;
    _busy = true;
    if (mounted) setState(() => _status = _GateStatus.checking);

    try {
      PermissionStatus permission = await Permission.camera.status;

      if (permission.isDenied && requestIfDenied) {
        // 시스템 권한 다이얼로그 요청.
        permission = await Permission.camera.request();
      }

      if (permission.isGranted || permission.isLimited) {
        _setStatus(_GateStatus.granted);
      } else if (permission.isPermanentlyDenied || permission.isRestricted) {
        _setStatus(_GateStatus.permanentlyDenied);
      } else {
        _setStatus(_GateStatus.denied);
      }
    } catch (e) {
      debugPrint('[CameraGate] 권한 평가 실패: $e');
      _setStatus(_GateStatus.denied);
    } finally {
      _busy = false;
    }
  }

  void _setStatus(_GateStatus s) {
    if (!mounted) return;
    setState(() => _status = s);
  }

  /// 앱 권한 설정(시스템) 화면 열기 — 영구거부 복구용.
  Future<void> _openAppSettings() async {
    await openAppSettings();
  }

  @override
  Widget build(BuildContext context) {
    // 허용된 경우에만 다음 위젯(웹뷰)으로 진입.
    if (_status == _GateStatus.granted) {
      return widget.next;
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    switch (_status) {
      case _GateStatus.checking:
        return const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('카메라 권한을 확인하는 중입니다...'),
          ],
        );

      case _GateStatus.denied:
        return _gateMessage(
          icon: Icons.photo_camera,
          title: '카메라 권한이 필요합니다',
          desc: '이 앱은 QR 스캔과 현장 사진 촬영을 위해 카메라 권한이 반드시 필요합니다.\n'
              '권한을 허용해야 앱을 사용할 수 있습니다.',
          primaryLabel: '카메라 권한 허용하기',
          onPrimary: () => _evaluateAndRequest(),
        );

      case _GateStatus.permanentlyDenied:
        return _gateMessage(
          icon: Icons.settings,
          title: '카메라 권한이 차단되어 있습니다',
          desc: '카메라 권한이 영구적으로 거부되었습니다.\n'
              '앱 설정 화면에서 카메라 권한을 직접 허용해 주세요.',
          primaryLabel: '앱 설정 열기',
          onPrimary: _openAppSettings,
          secondaryLabel: '다시 확인',
          onSecondary: () => _evaluateAndRequest(requestIfDenied: false),
        );

      case _GateStatus.granted:
        // 위 build 에서 분기되므로 도달하지 않음.
        return const SizedBox.shrink();
    }
  }

  /// 게이트 안내 카드 공통 레이아웃.
  Widget _gateMessage({
    required IconData icon,
    required String title,
    required String desc,
    required String primaryLabel,
    required Future<void> Function() onPrimary,
    String? secondaryLabel,
    Future<void> Function()? onSecondary,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 56, color: Colors.blueGrey),
        const SizedBox(height: 20),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Text(
          desc,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 14, height: 1.5),
        ),
        const SizedBox(height: 28),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => onPrimary(),
            child: Text(primaryLabel),
          ),
        ),
        if (secondaryLabel != null && onSecondary != null) ...[
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => onSecondary(),
              child: Text(secondaryLabel),
            ),
          ),
        ],
      ],
    );
  }
}
