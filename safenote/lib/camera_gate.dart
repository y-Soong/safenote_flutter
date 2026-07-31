import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'web_app.dart';

/// 카메라권한 안내 게이트(소프트 게이트).
///
/// 앱 기동 시(위치권한 게이트 다음) 카메라권한을 먼저 안내·요청하되, **거부해도
/// 앱을 계속 쓸 수 있다**('나중에 하기'). 미허용 상태에서 QR 스캔을 실행하면
/// `web_app.dart` 의 SCAN_QR 브리지가 그 시점에 다시 요청하고, 거부 시
/// `PERMISSION_DENIED` 를 Vue 로 돌린다. 웹뷰 안 스캐너(순회점검 QR)는 iOS 가
/// getUserMedia 시점에 직접 물으며, 실패하면 QrScanner.vue 의 카메라 폴백 화면이 뜬다.
///
/// ★하드 게이트(미동의 = 앱 사용 불가)에서 전환한 이유: App Store 심사
/// 가이드라인 5.1.1 은 권한 거부 시에도 앱이 동작할 것을 요구한다. 카메라는 QR
/// 스캔·사진 첨부에만 쓰이므로 앱 전체를 막으면 리젝 사유가 된다. 되돌리지 말 것.
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
  bool _skipped = false; // '나중에 하기' 선택 — 미허용 상태로 앱 진입

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
    // 이미 앱으로 진입한 뒤(허용 또는 건너뜀)에는 재평가하지 않는다.
    if (state != AppLifecycleState.resumed ||
        _status == _GateStatus.granted ||
        _skipped) {
      return;
    }
    if (_busy) {
      // 진행 중인 요청이 OS 권한콜백 유실로 영구 고착됐을 수 있다. _busy 가 true 로 남아
      // 일반 재평가가 막히므로, 다이얼로그 없는 읽기 전용 재확인으로 고착을 푼다(자가복구).
      _rescueOnResume();
    } else {
      _evaluateAndRequest(requestIfDenied: false);
    }
  }

  /// resume 시 읽기 전용 권한 재확인. 이미 허용 상태면 고착(_busy)을 풀고 진입한다.
  /// 미허용이면 진행 중인 요청을 방해하지 않도록 상태를 강제로 바꾸지 않는다.
  Future<void> _rescueOnResume() async {
    try {
      final permission = await Permission.camera.status;
      if (permission.isGranted || permission.isLimited) {
        _busy = false; // 고착 해제
        _setStatus(_GateStatus.granted);
      }
    } catch (e) {
      debugPrint('[CameraGate] resume 재확인 실패: $e');
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

  /// '나중에 하기' — 권한 없이 앱으로 진입한다. 카메라가 필요한 기능은 그 시점에
  /// 다시 요청되고, 거부되면 각 화면에서 안내된다.
  void _skipForNow() {
    if (!mounted) return;
    setState(() => _skipped = true);
  }

  @override
  Widget build(BuildContext context) {
    // 허용됐거나 사용자가 건너뛴 경우 다음 위젯(웹뷰)으로 진입.
    if (_status == _GateStatus.granted || _skipped) {
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
          title: '카메라 권한을 허용해 주세요',
          desc: 'QR 스캔과 현장 사진 촬영에만 사용합니다.\n'
              '지금 허용하지 않아도 앱은 사용할 수 있으며,\n'
              'QR 스캔을 시작할 때 다시 요청합니다.',
          primaryLabel: '카메라 권한 허용하기',
          onPrimary: () => _evaluateAndRequest(),
        );

      case _GateStatus.permanentlyDenied:
        return _gateMessage(
          icon: Icons.settings,
          title: '카메라 권한이 차단되어 있습니다',
          desc: '앱 설정 화면에서 카메라 권한을 허용하면\n'
              'QR 스캔과 사진 촬영을 쓸 수 있습니다.\n'
              '허용하지 않아도 나머지 기능은 사용할 수 있습니다.',
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
        // 권한 없이 진입하는 경로. 심사 가이드라인 5.1.1 대응이므로 항상 노출한다.
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: _skipForNow,
            child: const Text('나중에 하기'),
          ),
        ),
      ],
    );
  }
}
