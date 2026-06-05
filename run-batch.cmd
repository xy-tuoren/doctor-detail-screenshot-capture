@echo off
cd /d "%~dp0"
echo Open the doctor app list page first, then press any key...
pause >nul
echo Starting batch capture...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode Batch -Resume
echo.
echo Done.
pause
