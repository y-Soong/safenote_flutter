# SafeNote APK 빌드 — 명령어 정리

Vue(prafta-app-frontend) 빌드 → Flutter 셸 번들 → APK. 순서대로 실행.

---

## 매번 하는 것

### 1) Vue 자산 동기화 (Vue 코드 바뀔 때마다)
실행 위치: `C:\PRAFTA\PRAFTA_FLUTTER\safenote`
```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\sync-vue-app.ps1
```
→ Vue 빌드 후 `assets\vue_app\` 로 자동 복사.

### 2) APK 빌드
실행 위치: `C:\PRAFTA\PRAFTA_FLUTTER\safenote`
```bash
flutter clean
flutter pub get
flutter build apk --release --dart-define=APP_BASE_URL=https://운영백엔드주소
```
- `APP_BASE_URL` = 운영 백엔드 주소(끝에 `/prafta` 붙이지 말 것, 자동으로 붙음). 예: `https://api.prafta.example.com`
- 이 값을 빼면 APK가 백엔드에 연결 못 함(번들 서버 자신을 가리킴).
- → 결과물: `build\app\outputs\flutter-apk\app-release.apk`

---

## 최초 1회만 (한 번 해두면 끝)

### 3) 런처 아이콘 생성
실행 위치: `C:\PRAFTA\PRAFTA_FLUTTER\safenote`
```bash
flutter pub get
dart run flutter_launcher_icons
```

### 4) 서명 키 생성
실행 위치: `C:\PRAFTA\PRAFTA_FLUTTER\safenote\android`
```bash
keytool -genkey -v -keystore safenote-upload-key.jks -keyalg RSA -keysize 2048 -validity 10000 -alias safenote
```
※ 비밀번호 기억 + `.jks` 백업 (분실 시 스토어 업데이트 불가)

### 5) key.properties 작성
실행 위치: `C:\PRAFTA\PRAFTA_FLUTTER\safenote\android`
```powershell
Copy-Item key.properties.example key.properties
```
→ 만들어진 `key.properties` 열어서 4줄 채우기:
```properties
storePassword=<keystore 비밀번호>
keyPassword=<key 비밀번호>
keyAlias=safenote
storeFile=safenote-upload-key.jks
```

---

## 확인 (선택)
실행 위치: `C:\PRAFTA\PRAFTA_FLUTTER\safenote`
```bash
adb install build\app\outputs\flutter-apk\app-release.apk   # 실기기 설치
```

---

## 참고
- cert 필요: `prafta-app-frontend\prafta-app-frontend\cert\` 에 `172.30.1.4-key.pem`, `172.30.1.4.pem` 없으면 1번에서 실패.
- 첫 빌드는 5~10분 걸림(정상).
- 운영 백엔드 연결: 빌드 시 `--dart-define=APP_BASE_URL=https://...` 만 넣으면 됨(2번 참고). 누락 시 로그인/API 실패.
- HTTPS 정식 도메인이면 추가 설정 불필요. 평문(http)·사설 IP면 `android\app\src\main\res\xml\network_security_config.xml` 에 도메인 등록 필요.
