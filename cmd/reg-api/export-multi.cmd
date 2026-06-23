@echo off
chcp 65001 >nul
set "ROOT=%~dp0..\.."
cd /d "%ROOT%"
echo ========================================
echo   Export multi doctors via SOAP API
echo   (no UI / no coordinates)
echo   Output: exports\reg-api\多执业导出-^<timestamp^>.xlsx
echo   (searchType 8, same roster as UI 多执业 tab / export)
echo ========================================
echo.
echo Coordinate-based export remains at cmd\automation\export-multi.cmd
echo.
if not exist "%ROOT%\config.json" (
  echo [ERROR] config.json not found.
  echo Copy config.json.example to config.json and fill minkeRegApi / loginUser first.
  pause
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\src\api\setup-api-env.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to prepare API environment.
  pause
  exit /b 1
)
"%ROOT%\.venv\Scripts\python.exe" -m src.cli export-reg-multi %*
if errorlevel 1 (
  echo.
  echo [ERROR] SOAP export failed.
  pause
  exit /b 1
)
echo.
echo Export done.
pause
