@echo off
cd /d "%~dp0"
echo ========================================
echo   Auto capture [Main]: zhu zhi ye ji gou zai ben yuan yi shi
echo ========================================
echo.
if not exist "%~dp0config.json" (
  echo [ERROR] config.json not found.
  echo Copy config.json.example to config.json and fill it first.
  pause
  exit /b 1
)
echo All settings will be read from config.json.
echo If coordinates are not calibrated, run run-calibrate.cmd first.
echo Entry: zhu zhi ye ji gou zai ben yuan yi shi
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\capture-doctor-details.ps1" -Mode LoginAndSearchNames -ListEntry Main
echo.
echo Done.
pause
