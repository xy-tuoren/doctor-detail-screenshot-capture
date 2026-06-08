@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ========================================
echo   Step 2 [Multi]: open list and capture
echo ========================================
echo.
if not exist "%~dp0config.json" (
  echo [ERROR] config.json not found.
  pause
  exit /b 1
)
echo Please make sure the app is already on the home page.
echo Entry: wai yuan zai ben yuan duo zhi ye yi shi (reads namesMulti)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode OpenListAndSearchNames -ListEntry Multi
echo.
echo Done.
pause
