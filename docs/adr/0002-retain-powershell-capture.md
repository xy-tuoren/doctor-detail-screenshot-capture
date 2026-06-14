# 保留 PowerShell 机构端截图脚本，由 Python 调用而非重写

总体目标是"去 cmd、全部用 Python 操作"。但机构端截图依赖 `automation/ps1/capture-doctor-details.ps1`（约 5500 行）——基于 Win32 / UI Automation 的桌面客户端自动化，重写为 Python 风险高、收益低。决定：去掉 `.cmd` 入口，但保留该 PowerShell 脚本，由 Python 编排器通过 `subprocess` 调用并解析其产物/日志。这样"Python 化"落在入口与编排层，UI 自动化实现保持稳定。日后若要纯 Python 化截图，作为独立工作另行评估，不在本次架构重构范围内。
