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
echo Entry: zhu zhi ye ji gou zai ben yuan yi shi (reads names / namesMain)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\capture-doctor-details.ps1" -Mode OpenListAndSearchNames -ListEntry Main
echo.
echo Done.
pause
