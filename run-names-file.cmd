@echo off
cd /d "%~dp0"
if not exist "%~dp0calibration.json" (
  echo No calibration found. Please run run-calibrate.cmd first.
  pause
  exit /b 1
)
if not exist "%~dp0name.txt" (
  echo name.txt not found in this folder.
  pause
  exit /b 1
)
echo Will read names from name.txt (UTF-8). Open doctor app list page, then press any key...
pause >nul
echo Starting batch name capture...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode SearchNames -NamesFile "%~dp0name.txt"
echo.
echo Done.
pause
