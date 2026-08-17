import 'package:flutter_inappwebview/flutter_inappwebview.dart'
    show SslErrorType;
import 'package:flutter_test/flutter_test.dart';
import 'package:safenote/server_trust_policy.dart';

/// 서버 신뢰 판정 회귀 테스트 — 2026-08-17 iOS TestFlight 130~132 전면 장애 재발 방지.
///
/// ★핵심 불변식 2개(깨지면 iOS 웹뷰 API 전멸):
///   1. sslError 부재(안드로이드 정상 경로) → 항상 PROCEED.
///   2. UNSPECIFIED(iOS 유효 인증서의 정상 평가 결과) → release 에서도 항상 PROCEED.
/// 보안 불변식(S-3): 무효 인증서는 release 에서 항상 CANCEL(debug 만 자가서명 허용).
void main() {
  group('shouldProceedServerTrust — 정상 신뢰는 빌드 형상 무관 통과', () {
    test('sslError 부재(안드로이드: 유효 인증서는 챌린지 자체가 없거나 오류 없음)', () {
      expect(
        shouldProceedServerTrust(sslErrorCode: null, isDebugBuild: false),
        isTrue,
      );
      expect(
        shouldProceedServerTrust(sslErrorCode: null, isDebugBuild: true),
        isTrue,
      );
    });

    test('UNSPECIFIED(iOS: 유효 인증서의 정상 평가 결과 — 빌드 132 실증 함정)', () {
      expect(
        shouldProceedServerTrust(
          sslErrorCode: SslErrorType.UNSPECIFIED,
          isDebugBuild: false,
        ),
        isTrue,
        reason: 'iOS 는 유효 인증서도 UNSPECIFIED 로 오므로 release 에서 반드시 통과해야 한다 '
            '(거부 시 iOS 웹뷰 발 전체 API 가 TLS 단계에서 전멸 — TestFlight 130~132 장애)',
      );
    });
  });

  group('shouldProceedServerTrust — 무효 인증서는 debug 만 통과(S-3)', () {
    final invalidCodes = <SslErrorType>[
      SslErrorType.DENY,
      SslErrorType.INVALID,
      SslErrorType.UNTRUSTED,
      SslErrorType.EXPIRED,
      SslErrorType.IDMISMATCH,
      SslErrorType.NOT_YET_VALID,
      SslErrorType.DATE_INVALID,
      SslErrorType.FATAL_TRUST_FAILURE,
      SslErrorType.RECOVERABLE_TRUST_FAILURE,
      SslErrorType.OTHER_ERROR,
    ];

    test('release/profile(isDebugBuild=false) → 전부 CANCEL', () {
      for (final code in invalidCodes) {
        expect(
          shouldProceedServerTrust(sslErrorCode: code, isDebugBuild: false),
          isFalse,
          reason: '$code 는 release 에서 거부되어야 한다(S-3)',
        );
      }
    });

    test('debug(LAN dev 자가서명) → 전부 PROCEED(L-4)', () {
      for (final code in invalidCodes) {
        expect(
          shouldProceedServerTrust(sslErrorCode: code, isDebugBuild: true),
          isTrue,
          reason: '$code 는 debug 에서만 허용된다(L-4)',
        );
      }
    });
  });
}
