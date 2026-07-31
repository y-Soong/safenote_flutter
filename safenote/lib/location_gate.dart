import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'web_app.dart';

/// 위치권한 안내 게이트(소프트 게이트).
///
/// 앱 기동 시 위치권한을 먼저 안내·요청하되, **거부해도 앱을 계속 쓸 수 있다**
/// ('나중에 하기'). 미허용 상태에서 위치가 실제로 필요한 기능(출퇴근/TBM)을
/// 실행하면 `web_app.dart` 의 GET_GPS 브리지가 그 시점에 다시 권한을 요청하고,
/// 거부 시 `PERMISSION_DENIED` 를 Vue 로 돌려 화면에서 안내한다.
///
/// ★하드 게이트(미동의 = 앱 사용 불가)에서 전환한 이유: App Store 심사
/// 가이드라인 5.1.1 은 "권한을 거부해도 앱은 동작해야 하며, 핵심 기능과 무관한
/// 데이터 접근을 강제할 수 없다"고 요구한다. 위치는 출퇴근·TBM 에만 쓰이므로
/// 공지 조회 등 나머지 기능까지 막으면 리젝 사유가 된다. 되돌리지 말 것.
///
/// - 위치 서비스(OS 위치 토글) 꺼짐 → 설정 안내(위치 서비스 켜기 유도).
/// - 권한 거부(whileDenied) → 재요청 버튼.
/// - 영구 거부(deniedForever) → openAppSettings() 로 앱 설정 화면 유도.
///
/// 좌표 활용(지오펜스/저장)은 후속 단위(백엔드) 몫이며, 여기서는
/// 권한 게이트만 담당한다.
///
/// [next] 는 위치권한 허용 후 진입할 위젯이다. 기본값은 [WebApp] 이며,
/// 카메라 권한 게이트를 뒤에 체이닝할 때 [CameraGate] 를 주입한다.
class LocationGate extends StatefulWidget {
  const LocationGate({super.key, this.next = const WebApp()});

  /// 위치권한 허용 후 진입할 위젯(기본 [WebApp], 체이닝 시 [CameraGate]).
  final Widget next;

  @override
  State<LocationGate> createState() => _LocationGateState();
}

/// 게이트 내부 상태.
enum _GateStatus {
  checking, // 권한 확인 중
  serviceDisabled, // 위치 서비스(OS) 꺼짐
  denied, // 권한 거부(재요청 가능)
  deniedForever, // 영구 거부(설정 이동 필요)
  granted, // 허용됨 → 웹뷰 진입
}

class _LocationGateState extends State<LocationGate> with WidgetsBindingObserver {
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
      // 진행 중인 요청(requestPermission)이 OS 권한콜백 유실로 영구 고착됐을 수 있다.
      // 이때 _busy 가 true 로 남아 일반 재평가가 막히므로, 다이얼로그를 띄우지 않는
      // 읽기 전용 재확인으로 "이미 허용됨" 을 감지해 고착을 푼다(자가복구).
      _rescueOnResume();
    } else {
      _evaluateAndRequest(requestIfDenied: false);
    }
  }

  /// resume 시 읽기 전용 권한 재확인. 이미 허용 상태면 고착(_busy)을 풀고 진입한다.
  /// 미허용이면 진행 중인 요청을 방해하지 않도록 상태를 강제로 바꾸지 않는다.
  Future<void> _rescueOnResume() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse) {
        _busy = false; // 고착 해제
        _setStatus(_GateStatus.granted);
      }
    } catch (e) {
      debugPrint('[LocationGate] resume 재확인 실패: $e');
    }
  }

  /// 위치 서비스/권한 상태를 평가하고, 거부 상태면 권한을 요청한다.
  ///
  /// [requestIfDenied] 가 false 면(설정 복귀 등) 평가만 하고 시스템 권한
  /// 다이얼로그를 다시 띄우지 않는다.
  Future<void> _evaluateAndRequest({bool requestIfDenied = true}) async {
    if (_busy) return;
    _busy = true;
    if (mounted) setState(() => _status = _GateStatus.checking);

    try {
      // 1) OS 위치 서비스 자체가 켜져 있는지.
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _setStatus(_GateStatus.serviceDisabled);
        return;
      }

      // 2) 앱 권한 상태 확인.
      LocationPermission permission = await Geolocator.checkPermission();

      if (permission == LocationPermission.denied && requestIfDenied) {
        // 시스템 권한 다이얼로그 요청.
        permission = await Geolocator.requestPermission();
      }

      switch (permission) {
        case LocationPermission.always:
        case LocationPermission.whileInUse:
          _setStatus(_GateStatus.granted);
          break;
        case LocationPermission.deniedForever:
          _setStatus(_GateStatus.deniedForever);
          break;
        case LocationPermission.denied:
        case LocationPermission.unableToDetermine:
          _setStatus(_GateStatus.denied);
          break;
      }
    } catch (e) {
      debugPrint('[LocationGate] 권한 평가 실패: $e');
      _setStatus(_GateStatus.denied);
    } finally {
      _busy = false;
    }
  }

  void _setStatus(_GateStatus s) {
    if (!mounted) return;
    setState(() => _status = s);
  }

  /// 위치 서비스 설정(시스템) 화면 열기.
  Future<void> _openLocationSettings() async {
    await Geolocator.openLocationSettings();
  }

  /// 앱 권한 설정(시스템) 화면 열기 — 영구거부 복구용.
  Future<void> _openAppSettings() async {
    await Geolocator.openAppSettings();
  }

  /// '나중에 하기' — 권한 없이 앱으로 진입한다. 위치가 필요한 기능은 그 시점에
  /// GET_GPS 브리지가 다시 요청하고, 거부되면 화면에서 안내된다.
  void _skipForNow() {
    if (!mounted) return;
    setState(() => _skipped = true);
  }

  @override
  Widget build(BuildContext context) {
    // 허용됐거나 사용자가 건너뛴 경우 다음 게이트(또는 웹뷰)로 진입.
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
            Text('위치 권한을 확인하는 중입니다...'),
          ],
        );

      case _GateStatus.serviceDisabled:
        return _gateMessage(
          icon: Icons.location_off,
          title: '위치 서비스가 꺼져 있습니다',
          desc: '출퇴근·TBM 위치 확인에 기기의 위치 서비스가 필요합니다.\n'
              '지금 켜지 않아도 앱은 사용할 수 있습니다.',
          primaryLabel: '위치 서비스 설정 열기',
          onPrimary: _openLocationSettings,
          secondaryLabel: '다시 확인',
          onSecondary: () => _evaluateAndRequest(requestIfDenied: false),
        );

      case _GateStatus.denied:
        return _gateMessage(
          icon: Icons.my_location,
          title: '위치 권한을 허용해 주세요',
          desc: '출퇴근·TBM 위치 확인에만 사용합니다.\n'
              '지금 허용하지 않아도 앱은 사용할 수 있으며,\n'
              '해당 기능을 실행할 때 다시 요청합니다.',
          primaryLabel: '위치 권한 허용하기',
          onPrimary: () => _evaluateAndRequest(),
        );

      case _GateStatus.deniedForever:
        return _gateMessage(
          icon: Icons.settings,
          title: '위치 권한이 차단되어 있습니다',
          desc: '앱 설정 화면에서 위치 권한을 허용하면\n'
              '출퇴근·TBM 위치 확인을 쓸 수 있습니다.\n'
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
