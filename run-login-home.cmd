@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ========================================
echo   Step 1: login to home page
echo ========================================
echo.
if not exist "%~dp0config.json" (
  echo [ERROR] config.json not found.
  pause
  exit /b 1
)
echo All settings will be read from config.json.
echo Press any key to login and stop at the home page...
pause >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode LoginToHome
echo.
echo Done. The app should now be on the home page.
pause
