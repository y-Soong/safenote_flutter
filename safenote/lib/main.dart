import 'package:flutter/material.dart';
import 'web_app.dart'; // 👈 분리한 파일 import

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: WebApp(), // 👈 WebView 위젯만 불러오기
    );
  }
}
