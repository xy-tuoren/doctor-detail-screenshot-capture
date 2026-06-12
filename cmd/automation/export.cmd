@echo off
chcp 65001 >nul
set "ROOT=%~dp0..\.."
cd /d "%ROOT%"
echo ========================================
echo   Auto export: main institution doctors
echo   (captcha flow; file: 主执业导出-<timestamp>.xls)
echo ========================================
echo.
if not exist "%ROOT%\config.json" (
  echo [ERROR] config.json not found.
  echo Copy config.json.example to config.json and fill it first.
  pause
  exit /b 1
)
echo All settings will be read from config.json.
echo If export coordinates are not calibrated, run cmd\automation\export-calibrate.cmd first.
echo Exported files will be saved to the exports folder by default.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\automation\ps1\capture-doctor-details.ps1" -Mode Export -ListEntry Main
if errorlevel 1 (
  echo.
  echo [ERROR] Export failed. See messages above.
  pause
  exit /b 1
)
echo.
echo Export done.
pause
