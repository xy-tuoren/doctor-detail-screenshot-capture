@echo off
chcp 65001 >nul
set "ROOT=%~dp0..\.."
cd /d "%ROOT%"
echo ========================================
echo   Auto export: multi-institution doctors
echo ========================================
echo.
if not exist "%ROOT%\config.json" (
  echo [ERROR] config.json not found.
  echo Copy config.json.example to config.json and fill it first.
  pause
  exit /b 1
)
echo Multi-institution export has no captcha; it clicks Export directly.
echo If multi export button is not calibrated, run cmd\automation\export-calibrate.cmd (step 8) first.
echo Exported file: 多执业导出-<timestamp>.xls in the exports folder.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\automation\ps1\capture-doctor-details.ps1" -Mode Export -ListEntry Multi
if errorlevel 1 (
  echo.
  echo [ERROR] Export failed. See messages above.
  pause
  exit /b 1
)
echo.
echo Export done.
pause
