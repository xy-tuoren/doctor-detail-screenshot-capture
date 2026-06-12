@echo off
set "ROOT=%~dp0.."
cd /d "%ROOT%"
echo ========================================
echo   Auto capture [Multi]: wai yuan zai ben yuan duo zhi ye yi shi
echo ========================================
echo.
if not exist "%ROOT%\config.json" (
  echo [ERROR] config.json not found.
  echo Copy config.json.example to config.json and fill it first.
  pause
  exit /b 1
)
echo All settings will be read from config.json.
echo If coordinates are not calibrated, run cmd\run-calibrate.cmd first.
echo Entry: wai yuan zai ben yuan duo zhi ye yi shi
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\capture-doctor-details.ps1" -Mode LoginAndSearchNames -ListEntry Multi
echo.
echo Done.
pause
