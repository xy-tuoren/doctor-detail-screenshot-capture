@echo off
cd /d "%~dp0"
if not exist "%~dp0calibration.json" (
  echo No calibration found. Please run run-calibrate.cmd first.
  pause
  exit /b 1
)
echo Enter one or more names, separated by commas. Example: Zhang San,Li Si
set /p SEARCH_NAMES=Names: 
if "%SEARCH_NAMES%"=="" (
  echo Names are required.
  pause
  exit /b 1
)
echo Make sure the doctor app list page is open, then press any key...
pause >nul
echo Starting name-series capture...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode SearchNames -Names "%SEARCH_NAMES%"
echo.
echo Done.
pause
