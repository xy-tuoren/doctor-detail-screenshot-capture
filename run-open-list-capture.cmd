@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ========================================
echo   Step 2: open doctor list and capture
echo ========================================
echo.
if not exist "%~dp0config.json" (
  echo [ERROR] config.json not found.
  pause
  exit /b 1
)
echo Please make sure the app is already on the home page.
echo This will click the doctor list entry and continue screenshots.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode OpenListAndSearchNames
echo.
echo Done.
pause
