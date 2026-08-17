import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show SslErrorType;

/// 웹뷰 서버 신뢰(TLS 인증서) 챌린지 판정 단일 출처.
///
/// ★2026-08-17 TestFlight 130~132 전면 장애의 재발 방지 지점이다. 반드시 아래 플랫폼
/// 차이를 전제로 유지하고, 변경 시 `test/server_trust_policy_test.dart` 를 함께 갱신한다.
///
/// 플랫폼 차이(둘 다 실기기 실증):
///  1. 안드로이드는 SSL "오류" 때만 이 챌린지가 오지만, **iOS(WKWebView)는 유효한
///     인증서라도 모든 https 연결마다** 서버 신뢰 챌린지가 온다. release 에서 무조건
///     CANCEL 하면 iOS 만 웹뷰 발 전체 API(https)가 TLS 단계에서 전멸한다
///     (서버 접근로그 요청 0건 + 화면은 정상 렌더 — 빌드 130 실증).
///  2. iOS 는 유효한 인증서의 평가 결과가 proceed 가 아니라 **unspecified(평가 성공·
///     암묵 신뢰)** 라서, 플러그인이 sslError(code=UNSPECIFIED)를 실어 보낸다.
///     "sslError 없음"만 정상으로 보면 iOS 에서 또 CANCEL 로 떨어진다(빌드 132 실증).
///     UNSPECIFIED 는 안드로이드 오류 매핑에 존재하지 않는 iOS 전용 "정상" 값이다.
///
/// 판정 규칙:
///  - 정상 신뢰(sslError 부재 또는 UNSPECIFIED) → 통과(true).
///  - 무효 인증서(DENY/INVALID/UNTRUSTED/EXPIRED 등) → debug 빌드(LAN dev 자가서명)만
///    통과, release/profile 은 거부(false) — S-3/L-4 보안 의도 유지.
bool shouldProceedServerTrust({
  required SslErrorType? sslErrorCode,
  required bool isDebugBuild,
}) {
  if (sslErrorCode == null || sslErrorCode == SslErrorType.UNSPECIFIED) {
    return true;
  }
  return isDebugBuild;
}
