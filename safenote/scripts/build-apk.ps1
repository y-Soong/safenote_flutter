# 설치용 릴리즈 APK 를 현재 PC 의 LAN IP 를 APP_BASE_URL 로 박아 빌드한다.
#
# [왜 필요한가]
#   릴리즈 APK 는 Vue 를 http://localhost(앱 내장 번들 서버)에서 띄우므로, 백엔드 주소는
#   빌드 시 --dart-define=APP_BASE_URL=http://<PC IP>:8080 으로 주입해야 한다(window.__APP_BASE_URL__).
#   Android Studio 의 일반 빌드나 인자 없는 flutter build apk 는 이 값을 넣지 않아,
#   설치 후 로그인 등 모든 API 가 localhost 번들 서버로 가서 실패한다.
#   본 스크립트는 현재 LAN IP 를 자동 탐지해 그 값을 박아 설치 가능한 APK 를 만든다.
#
# 사용:
#   powershell -ExecutionPolicy Bypass -File .\scripts\build-apk.ps1
#     → 현재 PC LAN IPv4 자동 탐지 → Vue 동기화 → APP_BASE_URL 주입 release APK 빌드
#
# 옵션:
#   -Ip 172.30.1.50   탐지값 대신 IP 직접 지정
#   -Port 8081        백엔드 포트 변경(기본 8080)
#   -NoSync           Vue 산출물 동기화(sync-vue-app.ps1) 건너뛰기
#   -Debug            release 대신 debug APK 빌드
#
# ※ DHCP 로 PC IP 가 바뀌면 그 IP 로 다시 빌드해야 한다(설치된 APK 에 IP 가 박혀 있으므로).
#   기기를 USB 로 연결해 개발 중이라면 run-app.ps1(flutter run)이 매 실행 시 현재 IP 를 주입하므로 더 편하다.
#
# PowerShell 5.1 호환.
param(
    [string]$Ip,
    [int]$Port = 8080,
    [switch]$NoSync,
    [switch]$Debug
)
$ErrorActionPreference = 'Stop'

# 1) LAN IPv4 자동 탐지 (기본 게이트웨이 있는 Up 어댑터 = 실제 네트워크 연결)
if (-not $Ip) {
    $candidates = Get-NetIPConfiguration |
        Where-Object { $null -ne $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }
    if (-not $candidates) {
        throw "[build-apk] LAN IPv4 자동 탐지 실패. 네트워크 연결을 확인하거나 -Ip <주소> 로 지정해 주세요."
    }
    if (($candidates | Measure-Object).Count -gt 1) {
        Write-Host "[build-apk] 게이트웨이 어댑터가 여러 개 — 첫 번째 사용:" -ForegroundColor Yellow
        $candidates | Select-Object InterfaceAlias,
            @{ n = 'IPv4'; e = { $_.IPv4Address.IPAddress } },
            @{ n = 'GW'; e = { $_.IPv4DefaultGateway.NextHop } } | Format-Table -AutoSize | Out-Host
    }
    $Ip = ($candidates | Select-Object -First 1).IPv4Address.IPAddress
}
if ([string]::IsNullOrWhiteSpace($Ip)) {
    throw "[build-apk] 사용할 IP 가 비어 있습니다. -Ip <주소> 로 지정해 주세요."
}

$BaseUrl = "http://${Ip}:${Port}"
$Mode = if ($Debug) { "debug" } else { "release" }
Write-Host "[build-apk] 사용 IP        : $Ip" -ForegroundColor Cyan
Write-Host "[build-apk] APP_BASE_URL   : $BaseUrl" -ForegroundColor Cyan
Write-Host "[build-apk] 빌드 모드       : $Mode"

$ProjectRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot "..")).Path

# 2) Vue 산출물 동기화(옵션)
if (-not $NoSync) {
    $SyncScript = Join-Path $PSScriptRoot "sync-vue-app.ps1"
    Write-Host "[build-apk] Vue 동기화 실행: $SyncScript"
    & powershell -ExecutionPolicy Bypass -File $SyncScript
    if ($LASTEXITCODE -ne 0) { throw "[build-apk] sync-vue-app.ps1 실패 (exit=$LASTEXITCODE)" }
} else {
    Write-Host "[build-apk] -NoSync 지정 — Vue 동기화 건너뜀"
}

# 3) flutter build apk (APP_BASE_URL 주입)
Push-Location $ProjectRoot
try {
    Write-Host "[build-apk] flutter build apk --$Mode --dart-define=APP_BASE_URL=$BaseUrl"
    & flutter build apk "--$Mode" "--dart-define=APP_BASE_URL=$BaseUrl"
    if ($LASTEXITCODE -ne 0) { throw "[build-apk] flutter build apk 실패 (exit=$LASTEXITCODE)" }
} finally {
    Pop-Location
}

$ApkDir = if ($Debug) { "build\app\outputs\flutter-apk\app-debug.apk" } else { "build\app\outputs\flutter-apk\app-release.apk" }
$ApkPath = Join-Path $ProjectRoot $ApkDir
Write-Host ""
Write-Host "[build-apk] 완료. APK: $ApkPath" -ForegroundColor Green
Write-Host "[build-apk] 설치: adb install -r `"$ApkPath`"  (또는 기기로 파일 전송 후 설치)"
