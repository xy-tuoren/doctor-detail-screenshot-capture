@echo off
chcp 65001 >nul
set "ROOT=%~dp0.."
cd /d "%ROOT%"
echo ========================================
echo   Export coordinate calibration
echo ========================================
echo.
if not exist "%ROOT%\config.json" (
  echo [ERROR] config.json not found.
  echo Copy config.json.example to config.json and fill it first.
  pause
  exit /b 1
)
echo Open the doctor app and go to:
echo   本院执业医师信息 -^> 主执业机构在本院医师
echo Click [获取最新] to show the captcha dialog before calibration.
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\capture-doctor-details.ps1" -Mode ExportCalibrate
if errorlevel 1 (
  echo.
  echo [ERROR] Export calibration failed. See messages above.
  pause
  exit /b 1
)
echo.
echo Export calibration done. You can run cmd\run-export.cmd to export data.
pause
