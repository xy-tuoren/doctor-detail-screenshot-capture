@echo off
cd /d "%~dp0"
echo ============================================================
echo  Coordinate calibration (run this ONCE)
echo ------------------------------------------------------------
echo  1) Open the doctor app and log in.
echo  2) Type any common surname in the name box and press Enter
echo     so the list shows at least TWO rows.
echo  3) Keep that list visible, then press any key here.
echo ------------------------------------------------------------
pause
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode Calibrate
echo.
echo Done.
pause
