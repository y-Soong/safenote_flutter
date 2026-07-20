# Flutter 셸을 "로컬 Vite dev 서버"를 바라보는 debug 모드로 실행한다.
#
# 목적:
#   Vue(prafta-app-frontend) 만 수정하는 동안에는 APK 재빌드/재설치/자산 동기화 없이
#   로컬 dev 서버(npm run dev, :8082 HTTPS)를 그대로 바라보게 한다.
#   → Vue 저장 시 Vite HMR/새로고침만으로 즉시 반영(셸 재설치 불필요).
#
#   release 와 달리 debug 에서는 셸이 _kAppDevUrl(=APP_DEV_URL) 을 로딩하고,
#   APP_BASE_URL 을 주입하지 않으므로 Vue 는 상대경로 /prafta 를 쓰고
#   Vite 프록시(/prafta -> localhost:8080)가 백엔드로 전달한다. dev 서버 하나면 화면+API 모두 동작.
#
#   ★ Flutter(네이티브) 코드를 고쳤다면 이 스크립트로도 그 변경은 hot-restart 까지만 반영된다.
#     네이티브 의존성/권한/매니페스트 변경 등 풀 리빌드가 필요한 경우엔 기존 run-app.ps1(release) 사용.
#
# 사용 예:
#   # USB 연결(IP 무관, 권장): adb reverse 로 폰의 localhost:8082 -> PC 8082 매핑
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-app-dev.ps1 -Adb
#
#   # 같은 WiFi(LAN IP 자동 탐지): https://<자동IP>:8082 로딩
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-app-dev.ps1
#
#   # dev 서버 URL 직접 지정
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-app-dev.ps1 -DevUrl https://172.30.1.50:8082
#
# 옵션:
#   -Adb            adb reverse tcp:<Port> 를 걸고 DevUrl 을 https://localhost:<Port> 로 고정(USB 권장)
#   -Ip 172.30.1.50 LAN 모드에서 탐지값 대신 IP 직접 지정 → https://<Ip>:<Port>
#   -DevUrl <url>   dev 서버 URL 을 통째로 지정(위 -Adb/-Ip 보다 우선)
#   -Port 8082      Vite dev 서버 포트(기본 8082)
#   -Mode debug     debug(기본) / profile. release 는 dev URL 을 무시하므로 금지.
#   -PrintOnly      실행하지 않고 최종 명령만 출력
#
# 사전 준비(별도 터미널):
#   1) 백엔드 기동(:8080)
#   2) cd PRAFTA\prafta-app-frontend\prafta-app-frontend ; npm run dev   (→ :8082 HTTPS)
#
# PowerShell 5.1 호환.
param(
    [switch]$Adb,
    [string]$Ip,
    [string]$DevUrl,
    [int]$Port = 8082,
    [ValidateSet('debug', 'profile')]
    [string]$Mode = 'debug',
    [switch]$PrintOnly
)
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1) dev 서버 URL 결정 (-DevUrl > -Adb > -Ip > LAN 자동탐지)
# ---------------------------------------------------------------------------
$doAdbReverse = $false

if (-not [string]::IsNullOrWhiteSpace($DevUrl)) {
    # 사용자가 통째로 지정 — 그대로 사용
}
elseif ($Adb) {
    # USB: adb reverse 로 폰 localhost:<Port> -> PC <Port>. cert IP 불일치는 셸이 PROCEED 로 무시.
    $DevUrl = "https://localhost:${Port}"
    $doAdbReverse = $true
}
else {
    # LAN: IP 자동탐지(run-app.ps1 과 동일 로직) 또는 -Ip 지정값
    if (-not $Ip) {
        $candidates = Get-NetIPConfiguration |
            Where-Object { $null -ne $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }
        if (-not $candidates) {
            throw "[run-app-dev] LAN IPv4 자동 탐지 실패. -Ip <주소> 또는 -Adb(USB) 또는 -DevUrl 로 지정해 주세요."
        }
        if (($candidates | Measure-Object).Count -gt 1) {
            Write-Host "[run-app-dev] 게이트웨이 보유 어댑터가 여러 개입니다. 첫 번째를 사용합니다:" -ForegroundColor Yellow
            $candidates | Select-Object InterfaceAlias,
                @{ n = 'IPv4'; e = { $_.IPv4Address.IPAddress } },
                @{ n = 'GW'; e = { $_.IPv4DefaultGateway.NextHop } } | Format-Table -AutoSize | Out-Host
        }
        $Ip = ($candidates | Select-Object -First 1).IPv4Address.IPAddress
    }
    if ([string]::IsNullOrWhiteSpace($Ip)) {
        throw "[run-app-dev] 사용할 IP 가 비어 있습니다. -Ip <주소> 로 직접 지정해 주세요."
    }
    $DevUrl = "https://${Ip}:${Port}"
}

Write-Host "[run-app-dev] 실행 모드     : $Mode" -ForegroundColor Cyan
Write-Host "[run-app-dev] APP_DEV_URL  : $DevUrl" -ForegroundColor Cyan
if ($doAdbReverse) { Write-Host "[run-app-dev] adb reverse  : tcp:$Port -> tcp:$Port" -ForegroundColor Cyan }

$ProjectRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot "..")).Path

if ($PrintOnly) {
    Write-Host ""
    Write-Host "[run-app-dev] (PrintOnly) 실행될 명령:"
    Write-Host "  cd `"$ProjectRoot`""
    if ($doAdbReverse) { Write-Host "  adb reverse tcp:$Port tcp:$Port" }
    Write-Host "  flutter run --$Mode --dart-define=APP_DEV_URL=$DevUrl"
    Write-Host ""
    Write-Host "[run-app-dev] 사전 준비(별도 터미널): 백엔드(:8080) + npm run dev(:$Port)"
    return
}

# ---------------------------------------------------------------------------
# 2) (옵션) adb reverse — USB 연결 기기의 localhost:<Port> 를 PC 로 포워딩
# ---------------------------------------------------------------------------
if ($doAdbReverse) {
    $adbCmd = (Get-Command adb -ErrorAction SilentlyContinue)
    if (-not $adbCmd) {
        throw "[run-app-dev] adb 를 PATH 에서 찾지 못했습니다. Android SDK platform-tools 를 PATH 에 추가하거나 -Ip/-DevUrl(LAN) 방식을 쓰세요."
    }
    Write-Host "[run-app-dev] adb reverse tcp:$Port tcp:$Port"
    & adb reverse "tcp:$Port" "tcp:$Port"
    if ($LASTEXITCODE -ne 0) {
        throw "[run-app-dev] adb reverse 실패(exit=$LASTEXITCODE). USB 디버깅/기기 인식 상태를 확인해 주세요."
    }
}

# ---------------------------------------------------------------------------
# 3) flutter run (debug/profile) — sync/APP_BASE_URL 없음. dev 서버를 그대로 로딩.
# ---------------------------------------------------------------------------
Push-Location $ProjectRoot
try {
    Write-Host "[run-app-dev] flutter run --$Mode --dart-define=APP_DEV_URL=$DevUrl"
    Write-Host "[run-app-dev] ※ 별도 터미널에서 백엔드(:8080)와 npm run dev(:$Port)가 떠 있어야 합니다." -ForegroundColor Yellow
    & flutter run "--$Mode" "--dart-define=APP_DEV_URL=$DevUrl"
}
finally {
    Pop-Location
}
