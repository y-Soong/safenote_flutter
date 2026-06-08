package com.prafta.safenote

import io.flutter.embedding.android.FlutterActivity

// 권한 요청은 전적으로 Flutter 측 게이트가 담당한다.
//   - 위치: LocationGate (geolocator)
//   - 카메라: CameraGate (permission_handler)
// 과거 onResume() 에서 네이티브로 직접 requestPermissions(CAMERA/RECORD_AUDIO) 를 호출하던
// 코드는, geolocator 의 위치 권한요청과 Activity 단위로 충돌(동시 요청 불가)하여 첫 설치 시
// 위치 권한 콜백이 유실되고 LocationGate 가 "확인 중" 에서 무한정지하는 원인이었으므로 제거했다.
// (resume 마다 만들던 일회용 WebChromeClient 블록도 화면에 미부착이라 무효 코드여서 함께 제거)
class MainActivity : FlutterActivity()
