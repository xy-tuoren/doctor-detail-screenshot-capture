@echo off
chcp 65001 >nul
set "ROOT=%~dp0..\.."
cd /d "%ROOT%"
echo ========================================
echo   Fetch all doctor medical records (API)
echo   Output: exports\医生医疗机构信息-<timestamp>.xlsx
echo ========================================
echo.
if not exist "%ROOT%\config.json" (
  echo [ERROR] config.json not found.
  echo Copy config.json.example to config.json and fill doctorApi section first.
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
"%ROOT%\.venv\Scripts\python.exe" -m src.cli fetch-doctors %*
if errorlevel 1 (
  echo.
  echo [ERROR] API fetch failed.
  pause
  exit /b 1
)
echo.
echo Fetch done.
pause
