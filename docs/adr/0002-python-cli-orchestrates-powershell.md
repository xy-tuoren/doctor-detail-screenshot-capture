# 统一 Python CLI 编排，保留 PowerShell 截图脚本

所有 `cmd/` 入口改为统一的 Python CLI（编排器 + 可单独运行的步骤子命令，步骤间用 xlsx/json 中间产物传递）。

机构端截图依赖 `automation/ps1/capture-doctor-details.ps1`（约 5500 行 Win32 UI 自动化）。尽管目标是"全部用 Python 操作"，我们**刻意不重写这个脚本**，而是由 Python 通过 `subprocess` 调用它。重写 UI 自动化（窗口定位、坐标校准、OCR 验证码）风险高、收益低，且该脚本已稳定可用。

后果：技术栈是异构的（Python 编排 + PowerShell 执行截图）。这是有意为之——未来若有人想"顺手把它改成纯 Python"，应先权衡 UI 自动化的重写成本，而不是默认重写。
