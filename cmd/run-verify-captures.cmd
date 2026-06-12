@echo off
set "ROOT=%~dp0.."
cd /d "%ROOT%"
echo ========================================
echo   OCR verify capture filenames
echo ========================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\scripts\setup-ocr-env.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to prepare OCR environment.
  pause
  exit /b 1
)
echo.
"%ROOT%\.venv\Scripts\python.exe" "%ROOT%\scripts\verify_captures.py" %*
if errorlevel 1 (
  echo.
  echo [ERROR] OCR verification failed.
  pause
  exit /b 1
)
echo.
pause
