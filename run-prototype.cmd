@echo off
cd /d "%~dp0"
echo Open the doctor app list page first, then press any key...
pause >nul
echo Starting prototype capture (limit 5)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode Prototype -Limit 5
echo.
echo Done.
pause
