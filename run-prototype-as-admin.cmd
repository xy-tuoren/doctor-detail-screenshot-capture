@echo off
cd /d "%~dp0"
echo.
echo NOTE: Only use this if the doctor app itself runs as Administrator.
echo For a normal doctor app window, use: run-prototype.cmd
echo.
pause
echo Starting prototype as Administrator...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode Prototype -Limit 5 -Elevate
pause
