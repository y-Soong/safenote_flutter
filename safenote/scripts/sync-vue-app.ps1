# Vue 앱(prafta-app-frontend) 을 빌드하고 그 산출물을 Flutter 셸의 assets/vue_app/ 로 동기화한다.
# 사용:  powershell -ExecutionPolicy Bypass -File .\scripts\sync-vue-app.ps1
# PowerShell 5.1 호환.
$ErrorActionPreference = 'Stop'

# 경로 산출 — 스크립트는 safenote/scripts/ 에 위치. 레포 루트는 3단계 상위.
$RepoRoot = (Resolve-Path -Path (Join-Path $PSScriptRoot "..\..\..")).Path
$VueRoot  = Join-Path $RepoRoot "PRAFTA\prafta-app-frontend\prafta-app-frontend"
$VueDist  = Join-Path $VueRoot "dist"
$VueCert  = Join-Path $VueRoot "cert"

# assets/vue_app 디렉토리 — 없으면 생성 후 Resolve
$TargetRaw = Join-Path $PSScriptRoot "..\assets\vue_app"
if (-not (Test-Path $TargetRaw)) {
    New-Item -ItemType Directory -Force -Path $TargetRaw | Out-Null
}
$Target = (Resolve-Path -Path $TargetRaw).Path

Write-Host "[sync-vue-app] Vue 프로젝트:   $VueRoot"
Write-Host "[sync-vue-app] 동기화 대상:    $Target"

# 1) cert 파일 확인 (vite.config.js 가 readFileSync 로 참조 — 부재 시 빌드 실패)
$CertKey  = Join-Path $VueCert "172.30.1.4-key.pem"
$CertPem  = Join-Path $VueCert "172.30.1.4.pem"
if (-not (Test-Path $CertKey) -or -not (Test-Path $CertPem)) {
    Write-Error @"
[sync-vue-app] 인증서 파일이 없어 Vue 빌드를 진행할 수 없습니다.
  - 기대 경로: $VueCert
  - 필요한 파일: 172.30.1.4-key.pem, 172.30.1.4.pem
vite.config.js 가 fileURLToPath + readFileSync 로 위 파일을 module load 시점에 읽기 때문에
빌드 명령에서도 부재 시 실패합니다. mkcert 등으로 인증서를 먼저 생성해 주세요.
"@
}

# 2) node_modules 가 없으면 install
Push-Location $VueRoot
try {
    if (-not (Test-Path "node_modules")) {
        Write-Host "[sync-vue-app] node_modules 없음 — npm install 실행"
        npm install --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "npm install 실패 (exit=$LASTEXITCODE)" }
    }

    Write-Host "[sync-vue-app] Vite 빌드 시작 (npm run build)"
    npm run build
    if ($LASTEXITCODE -ne 0) { throw "vite build 실패 (exit=$LASTEXITCODE)" }
} finally {
    Pop-Location
}

# 3) dist/ 산출물 존재 확인
if (-not (Test-Path $VueDist)) {
    throw "dist/ 산출물이 없습니다: $VueDist"
}

# 4) 기존 assets/vue_app/ 비우기 (디렉토리 자체는 유지)
Write-Host "[sync-vue-app] 기존 assets/vue_app 정리"
Get-ChildItem -Path $Target -Force | Remove-Item -Recurse -Force

# 5) dist/* 를 assets/vue_app/ 로 mirror 복사
Write-Host "[sync-vue-app] dist 산출물 복사: $VueDist -> $Target"
Copy-Item -Path (Join-Path $VueDist "*") -Destination $Target -Recurse -Force

# 6) 결과 요약
$count = (Get-ChildItem -Path $Target -Recurse -File | Measure-Object).Count
Write-Host "[sync-vue-app] 완료. 복사된 파일 수: $count"
Write-Host "[sync-vue-app] 다음 단계: flutter clean && flutter pub get && flutter build apk --release"
