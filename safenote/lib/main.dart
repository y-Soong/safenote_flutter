import 'package:flutter/material.dart';
import 'location_gate.dart'; // 👈 위치권한 하드 게이트
import 'camera_gate.dart'; // 👈 카메라권한 하드 게이트

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      // 권한 게이트 체이닝: 위치 → 카메라 모두 허용해야 웹뷰(WebApp)로 진입한다.
      // 둘 중 하나라도 미동의면 앱 사용 불가(하드 게이트).
      home: LocationGate(next: CameraGate()),
    );
  }
}
