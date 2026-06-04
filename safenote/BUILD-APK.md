# 세이프노트 APK 배포 빌드 가이드

prafta-038 Phase A 정비 완료 후, 실제 APK를 만들기 위해 **사용자가 직접** 실행해야 하는 단계입니다.

> 참조:
> - 분해 로그: `C:\PRAFTA\.claude\requests\changelog\prafta-038-planning.md`
> - 작업서: `C:\PRAFTA\.claude\requests\prafta-038.md`

---

## 사전 조건

- Flutter SDK (`C:\flutter\`, 본 프로젝트 `local.properties` 기준)
- Android SDK + JDK 11+
- PowerShell 5.1+ (Windows 기본)
- Node.js 18+ (Vue 빌드용)
- mkcert (또는 동등한 도구)로 발급된 `PRAFTA\prafta-app-frontend\prafta-app-frontend\cert\` 의 인증서 4개
  - `172.30.1.4-key.pem` / `172.30.1.4.pem` 가 핵심 (vite.config.js가 module load 시점에 read)

---

## 1단계 — Vue 자산 동기화 (최초 1회 + Vue 코드 변경 시마다)

```powershell
cd C:\PRAFTA\PRAFTA_FLUTTER\safenote
powershell -ExecutionPolicy Bypass -File .\scripts\sync-vue-app.ps1
```

스크립트가 자동으로:
1. cert 파일 존재 확인 (없으면 명확한 에러 표시)
2. `node_modules` 없으면 `npm install`
3. `npm run build` (Vite → `dist/`)
4. `assets/vue_app/` 비우고 `dist/*` 복사

**현재 `assets/vue_app/`는 Vue CLI(웹팩) 산출물 stale 상태**입니다. 본 스크립트를 한 번 돌려서 Vite 산출물로 갱신해야 prafta-037 메인 홈을 포함한 최신 화면이 들어갑니다.

---

## 2단계 — 런처 아이콘 생성 (최초 1회 + 아이콘 변경 시)

```bash
cd C:\PRAFTA\PRAFTA_FLUTTER\safenote
flutter pub get
dart run flutter_launcher_icons
```

- 입력: `assets/icons/app_icon.png` (현재 `prafta-app-frontend`의 `safenote_sign.png` 복사본)
- 출력: `android/app/src/main/res/mipmap-*/ic_launcher.png` + adaptive icon XML (자동 생성, 커밋 대상)

---

## 3단계 — 릴리즈 keystore 생성 (최초 1회만)

`safenote/android/` 디렉토리에서:

```bash
cd C:\PRAFTA\PRAFTA_FLUTTER\safenote\android
keytool -genkey -v -keystore safenote-upload-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias safenote
```

대화형으로 묻는 항목:
- keystore 비밀번호 (기억해두세요)
- 이름, 조직, 도시 등 (Play Store 표시 X, 인증서 내부 정보)
- key 비밀번호 (Enter로 keystore 비밀번호와 동일하게 가능)

**중요:**
- 생성된 `safenote-upload-key.jks`는 **절대 분실 금지**. 분실 시 Play Store 앱 업데이트 불가.
- `.gitignore`에 자동 제외되어 있음 (`android/*.jks`).
- 안전한 위치에 백업하세요 (개인 클라우드 / 패스워드 매니저 파일 첨부 등).

---

## 4단계 — key.properties 작성 (최초 1회만)

```powershell
cd C:\PRAFTA\PRAFTA_FLUTTER\safenote\android
Copy-Item key.properties.example key.properties
```

`key.properties`를 열어 4개 값 채우기:
```properties
storePassword=<위에서 입력한 keystore 비밀번호>
keyPassword=<위에서 입력한 key 비밀번호>
keyAlias=safenote
storeFile=safenote-upload-key.jks
```

- `storeFile`은 `android/` 기준 상대경로. 절대경로(`C:/PRAFTA/.../safenote-upload-key.jks`)도 가능.
- `.gitignore`에 자동 제외됨.

---

## 5단계 — Release APK 빌드

```bash
cd C:\PRAFTA\PRAFTA_FLUTTER\safenote
flutter clean
flutter pub get
flutter build apk --release
```

운영 백엔드 URL이 결정되면:
```bash
flutter build apk --release --dart-define=APP_BASE_URL=https://api.prafta.example.com
```

빌드 결과: `build/app/outputs/flutter-apk/app-release.apk`

> 첫 빌드는 Gradle 다운로드로 5~10분 걸릴 수 있음 (타임아웃 600초 권장).

---

## 6단계 — APK 검증

```bash
# Android SDK 의 aapt 사용 (보통 C:\Users\<user>\AppData\Local\Android\Sdk\build-tools\<version>\aapt.exe)
aapt dump badging build\app\outputs\flutter-apk\app-release.apk | findstr "package label"
```

확인 사항:
- `package: name='com.prafta.safenote'` ✓
- `application-label-ko:'세이프노트'` 또는 `application-label:'세이프노트'` ✓
- `application-icon-XXX:'res/mipmap-xxhdpi-v4/ic_launcher.png'` ✓

실기기 설치:
```bash
adb install build\app\outputs\flutter-apk\app-release.apk
```

체크리스트:
- [ ] 런처에 "세이프노트"로 표시되는가
- [ ] 아이콘이 safenote_sign 그림인가 (Flutter 기본 아이콘 아님)
- [ ] 앱 진입 시 Vue 홈 화면(prafta-037)이 로딩되는가 (`http://localhost:8080/`)
- [ ] 카메라/저장소 권한 요청이 정상 표시되는가

---

## 디버그 빌드 (개발용)

dev 서버를 사용하는 디버그 빌드는 기존과 동일:
```bash
flutter run                                # 기본 (APP_DEV_URL=https://172.30.1.4:8082)
flutter run --dart-define=APP_DEV_URL=https://other.dev:8082
```

debug 빌드는 `usesCleartextTraffic` + user 인증서 신뢰가 main sourceSet의 network_security_config로 그대로 유지됨 (LAN IP cert 신뢰 필요).

---

## 문제 해결

### `vite build 실패` (cert 부재)
- `PRAFTA\prafta-app-frontend\prafta-app-frontend\cert\172.30.1.4-key.pem` 및 `172.30.1.4.pem` 존재 확인.
- 없으면 mkcert로 재발급.

### `Execution failed for task ':app:validateSigningRelease'`
- `key.properties`가 없으면 release 빌드가 debug 키 fallback. validate 단계에서 경고 또는 실패 가능.
- 4단계 다시 확인. `storeFile` 경로가 실제 keystore 파일을 가리키는지.

### release APK 진입 시 흰 화면
- `assets/vue_app/`이 비어있거나 stale일 가능성. 1단계 sync 스크립트 재실행.
- adb logcat에서 `InAppLocalhostServer` 또는 `rootBundle.load` 관련 로그 확인.
- pubspec.yaml의 `assets:` 라인에 `assets/vue_app/assets/`까지 포함되어 있는지 확인 (Flutter의 디렉토리 1단계만 자동 포함 정책 때문).

### Play Store 업로드 시 "debug-signed APK" 오류
- `key.properties` 없이 빌드한 경우. 3~4단계 후 재빌드.

---

## Phase A에 포함되지 않은 후속 작업 (Phase B/C)

- `lib/qr_scan_page.dart` dead code 정리 또는 라우팅 연결
- `MainActivity.onResume`의 dead code WebView 인스턴스 정리
- `READ_EXTERNAL_STORAGE` / `RECORD_AUDIO` / `org.apache.http.legacy` 권한 정리
- 운영 백엔드 도메인 결정 + Vue axios baseURL 정비 + manifest network_security_config domain-config 등록
- `enableJetifier=true` 비활성화 검토 (빌드 속도)
- Flutter shell ↔ Vue webview JS-bridge 명세 (deviceId, push token, QR 결과 등)
- `flutter_launcher_icons`의 adaptive icon foreground 디자인 분리 (현재는 동일 PNG 사용)
- 사용 안 하는 플랫폼 폴더(`/web`, `/macos`, `/linux`, `/windows`) 정리
