# 卫健委采集（batch-doctor-query）并入主项目单一包

`batch-doctor-query` 原为独立子项目：独立 venv、嵌套 git 仓库、且残留 macOS 路径。决定将其并入主项目，作为统一 CLI 的一个步骤模块；移除嵌套 git 与 macOS 残留路径，名单输入改由管线根据 `updateField` 自动生成。其较重的依赖（Playwright、ddddocr）归为可选依赖组安装，使不需要卫健委采集的环境无需安装这些重依赖。

落地：采集核心搬入 `src/capture/nhc_core.py`（保留验证码破解、Clash 轮换等全部能力，去掉 argparse CLI 外壳），`src/capture/nhc.py` 为进程内封装供管线直接 import 调用（不再 subprocess），可选依赖缺失时抛 `NhcDependencyError` 优雅降级。`find_playwright_chromium` 增加 Windows / Linux 缓存路径。依赖归入 `pyproject.toml` 的 `[capture-nhc]` extra 与 `requirements/capture-nhc.txt`。已删除嵌套 `.git`、macOS 残留、旧 `batch-doctor-query/` 目录；卫健委截图默认输出至 `captures/卫健委/`，与机构端 `captures/主执业/`、`captures/多执业/` 并列。
