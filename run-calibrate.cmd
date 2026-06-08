@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo ========================================
echo   坐标校准（登录 + 列表，一次性完成）
echo ========================================
echo.
echo 请先打开医师系统登录页，脚本启动后会继续提示校准步骤。
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture-doctor-details.ps1" -Mode CalibrateAll
echo.
echo 校准完成。接下来可运行 run-capture.cmd 开始自动截图。
pause
