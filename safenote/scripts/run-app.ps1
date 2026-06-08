# Flutter 앱을 현재 PC 의 LAN IP 를 자동으로 잡아 실행한다(DHCP 환경 대응).
#
# 기존 수동 절차:
#   powershell -ExecutionPolicy Bypass -File .\scripts\sync-vue-app.ps1
#   flutter run --release --dart-define=APP_BASE_URL=http://172.30.1.71:8080
#
# 본 스크립트 사용:
#   powershell -ExecutionPolicy Bypass -File .\scripts\run-app.ps1
#     → 현재 PC LAN IPv4 자동 탐지 → APP_BASE_URL=http://<자동IP>:8080 로 flutter run --release
#
# 옵션:
#   -Ip 172.30.1.50   탐지값 대신 IP 직접 지정
#   -Port 8081        백엔드 포트 변경(기본 8080)
#   -Mode profile     실행 모드 release(기본) / profile / debug
#   -NoSync           Vue 산출물 동기화(sync-vue-app.ps1) 건너뛰기
#   -PrintOnly        실행하지 않고 탐지된 IP / 최종 명령만 출력
#
# PowerShell 5.1 호환.
param(
    [string]$Ip,
    [int]$Port = 8080,
    [ValidateSet('release', 'profile', 'debug')]
    [string]$Mode = 'release',
    [switch]$NoSync,
    [switch]$PrintOnly
)
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# 1) LAN IPv4 자동 탐지
#    - 기본 게이트웨이가 있고 어댑터 상태가 Up 인 인터페이스 = 실제 네트워크 연결.
#    - VMware/VirtualBox/Hyper-V/WSL 등 가상 어댑터(보통 게이트웨이 없음)와 loopback 을 자연히 배제.
# ---------------------------------------------------------------------------
if (-not $Ip) {
    $candidates = Get-NetIPConfiguration |
        Where-Object { $null -ne $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' }

    if (-not $candidates) {
        throw "[run-app] LAN IPv4 를 자동 탐지하지 못했습니다. 네트워크 연결을 확인하거나 -Ip <주소> 로 직접 지정해 주세요."
    }

    if (($candidates | Measure-Object).Count -gt 1) {
        Write-Host "[run-app] 게이트웨이를 가진 어댑터가 여러 개입니다. 첫 번째를 사용합니다:" -ForegroundColor Yellow
        $candidates | Select-Object InterfaceAlias,
            @{ n = 'IPv4'; e = { $_.IPv4Address.IPAddress } },
            @{ n = 'GW'; e = { $_.IPv4DefaultGateway.NextHop } } | Format-Table -AutoSize | Out-Host
    }

    $Ip = ($candidates | Select-Object -First 1).IPv4Address.IPAddress
}

if ([string]::IsNullOrWhiteSpace($Ip)) {
    throw "[run-app] 사용할 IP 가 비어 있습니다. -Ip <주소> 로 직접 지정해 주세요."
}

$BaseUrl = "http://${Ip}:${Port}"
Write-Host "[run-app] 사용 IP        : $Ip" -ForegroundColor Cyan
Write-Host "[run-app] APP_BASE_URL   : $BaseUrl" -ForegroundColor Cyan
Write-Host "[run-app] 실행 모드       : $Mode"

# 프로젝트 루트(= scripts 의 상위) 에서 flutter 를 실행해야 한다.
$ProjectRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot "..")).Path

if ($PrintOnly) {
    Write-Host ""
    Write-Host "[run-app] (PrintOnly) 실행될 명령:"
    Write-Host "  cd `"$ProjectRoot`""
    if (-not $NoSync) {
        Write-Host "  powershell -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'sync-vue-app.ps1')`""
    }
    Write-Host "  flutter run --$Mode --dart-define=APP_BASE_URL=$BaseUrl"
    return
}

# ---------------------------------------------------------------------------
# 2) Vue 산출물 동기화(옵션) — 기존 sync-vue-app.ps1 재사용
# ---------------------------------------------------------------------------
if (-not $NoSync) {
    $SyncScript = Join-Path $PSScriptRoot "sync-vue-app.ps1"
    Write-Host "[run-app] Vue 동기화 실행: $SyncScript"
    & powershell -ExecutionPolicy Bypass -File $SyncScript
    if ($LASTEXITCODE -ne 0) { throw "[run-app] sync-vue-app.ps1 실패 (exit=$LASTEXITCODE)" }
} else {
    Write-Host "[run-app] -NoSync 지정 — Vue 동기화 건너뜀"
}

# ---------------------------------------------------------------------------
# 3) flutter run
# ---------------------------------------------------------------------------
Push-Location $ProjectRoot
try {
    Write-Host "[run-app] flutter run --$Mode --dart-define=APP_BASE_URL=$BaseUrl"
    & flutter run "--$Mode" "--dart-define=APP_BASE_URL=$BaseUrl"
} finally {
    Pop-Location
}
