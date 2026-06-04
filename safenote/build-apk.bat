@echo off
setlocal

REM ============================================================
REM  SafeNote one-click APK build
REM  Steps: sync Vue assets -> flutter clean -> pub get -> release APK
REM  ------------------------------------------------------------
REM  If the backend PC IP changes, edit only APP_BASE_URL below.
REM ============================================================

set "PROJECT_DIR=C:\PRAFTA\PRAFTA_FLUTTER\safenote"
set "APP_BASE_URL=http://172.30.1.71:8080"

cd /d "%PROJECT_DIR%"
if errorlevel 1 (
    echo [ERROR] Cannot move to project dir: %PROJECT_DIR%
    goto :fail
)

echo.
echo [1/4] Sync Vue assets ^(sync-vue-app.ps1^) ...
powershell -ExecutionPolicy Bypass -File ".\scripts\sync-vue-app.ps1"
if errorlevel 1 (
    echo [ERROR] Vue sync failed
    goto :fail
)

echo.
echo [2/4] flutter clean ...
call flutter clean
if errorlevel 1 (
    echo [ERROR] flutter clean failed
    goto :fail
)

echo.
echo [3/4] flutter pub get ...
call flutter pub get
if errorlevel 1 (
    echo [ERROR] flutter pub get failed
    goto :fail
)

echo.
echo [4/4] Build release APK ^(APP_BASE_URL=%APP_BASE_URL%^) ...
call flutter build apk --release --dart-define=APP_BASE_URL=%APP_BASE_URL%
if errorlevel 1 (
    echo [ERROR] APK build failed
    goto :fail
)

set "APK_DIR=%PROJECT_DIR%\build\app\outputs\flutter-apk"
echo.
echo ============================================================
echo  BUILD SUCCESS
echo  APK: %APK_DIR%\app-release.apk
echo ============================================================

REM Open output folder (delete this line if not wanted)
explorer "%APK_DIR%"

echo.
pause
endlocal
exit /b 0

:fail
echo.
echo *** BUILD ABORTED. Check the error message above. ***
echo.
pause
endlocal
exit /b 1
