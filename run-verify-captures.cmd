@echo off
cd /d "%~dp0"
echo ========================================
echo   OCR verify capture filenames
echo ========================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\setup-ocr-env.ps1"
if errorlevel 1 (
  echo.
  echo [ERROR] Failed to prepare OCR environment.
  pause
  exit /b 1
)
echo.
"%~dp0.venv\Scripts\python.exe" "%~dp0scripts\verify_captures.py" %*
if errorlevel 1 (
  echo.
  echo [ERROR] OCR verification failed.
  pause
  exit /b 1
)
echo.
pause
