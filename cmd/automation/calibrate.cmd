@echo off
set "ROOT=%~dp0..\.."
cd /d "%ROOT%"
echo ========================================
echo   Coordinate calibration (login + list)
echo ========================================
echo.
if not exist "%ROOT%\config.json" (
  echo [ERROR] config.json not found.
  echo Copy config.json.example to config.json and fill it first.
  pause
  exit /b 1
)
echo Open the doctor app login page first.
echo The script will guide you through each calibration step.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\automation\ps1\capture-doctor-details.ps1" -Mode CalibrateAll
if errorlevel 1 (
  echo.
  echo [ERROR] Calibration failed. See messages above.
  pause
  exit /b 1
)
echo.
echo Calibration done. You can run cmd\automation\capture.cmd to start capture.
pause
