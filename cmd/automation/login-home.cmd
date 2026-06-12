@echo off
chcp 65001 >nul
set "ROOT=%~dp0..\.."
cd /d "%ROOT%"
echo ========================================
echo   Step 1: login to home page
echo ========================================
echo.
if not exist "%ROOT%\config.json" (
  echo [ERROR] config.json not found.
  pause
  exit /b 1
)
echo All settings will be read from config.json.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\automation\ps1\capture-doctor-details.ps1" -Mode LoginToHome
echo.
echo Done. The app should now be on the home page.
pause
