@echo off
cd /d "%~dp0"
echo.
echo NOTE: Only use this if the doctor app itself runs as Administrator.
echo For a normal doctor app window, use: run-batch.cmd
echo.
pause
echo Starting batch capture as Administrator...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode Batch -Resume -Elevate
pause
