"""Capture session orchestrator — replaces PS1 invocation from runner.py."""

from __future__ import annotations

import time
from pathlib import Path
from typing import Optional

from .capture import CaptureResult, Person, invoke_capture_with_recovery
from .login import MAIN_WINDOW_REGEX, enter_list_from_home, get_doctor_app_pids, login_to_home
from .pause import PauseController


def run_capture_session(
    persons: list[dict[str, str]],
    list_entry: str,
    config: dict,
    output_dir: Path,
    *,
    dry_run: bool = False,
    error_log_path: Optional[Path] = None,
) -> int:
    """
    Main entry point — replaces PS1 -Mode LoginAndSearchNames.

    persons: [{"name": "...", "certCode": "..."}, ...]
    config: full config.json dict (loginUser, loginPassword, appPath,
            loginCalibration, listCalibration, etc.)
    """
    person_list = [
        Person(name=p.get("name", ""), cert_code=p.get("certCode", ""))
        for p in persons
    ]

    if dry_run:
        print(f"[dry-run] would capture {len(person_list)} {list_entry} doctors")
        print(f"[dry-run] output dir: {output_dir}")
        return 0

    print(f"[INFO] 名单来源：ListEntry={list_entry}，共 {len(person_list)} 人。")
    print("[INFO] 将自动探测机构端当前阶段，跳过已完成的步骤。")

    # Get app PIDs for foreground detection (title matching is primary, PIDs are bonus)
    app_path = config.get("appPath", "")
    doctor_pids = get_doctor_app_pids(app_path)
    # 无人值守运行时禁用前台暂停：
    # 1) 环境变量 CAPTURE_NO_FOREGROUND_PAUSE=1 显式指定
    # 2) stdout 被重定向（非 tty）→ 自动判定为无人值守
    import os, sys
    no_fg_pause = (
        os.environ.get("CAPTURE_NO_FOREGROUND_PAUSE", "").strip() in ("1", "true", "yes")
        or not sys.stdout.isatty()
    )
    pause_ctrl = PauseController(
        doctor_app_pids=doctor_pids,
        pause_when_not_foreground=not no_fg_pause,
    )
    pause_ctrl.start_hotkey_thread()  # 启动 Ctrl+Space 后台轮询，确保暂停即时响应
    if no_fg_pause:
        print("[INFO] 已禁用前台暂停（无人值守模式），适合后台/重定向运行。")

    # Initialize OCR engine (pre-load model)
    print("[INFO] 初始化 OCR 引擎...")
    from .ocr import get_engine
    get_engine()
    print("[INFO] OCR 引擎就绪。")

    # Login
    main_win = login_to_home(config, pause_ctrl)
    # Enter list
    main_win = enter_list_from_home(main_win, list_entry, config, pause_ctrl)

    # Pause hints
    print("[INFO] 提示：运行中随时按【Ctrl+空格】暂停/恢复。")
    print("[INFO] 提示：机构端窗口不在前台时将自动暂停；切回前台后，需再按【Ctrl+空格】才会继续。")

    # Capture with recovery
    result = invoke_capture_with_recovery(
        person_list, config, list_entry, output_dir, pause_ctrl,
        main_win=main_win,
        error_log_path=error_log_path,
    )

    print(f"\n[INFO] 采图完成：共保存 {result.total_saved} 张截图。")
    return 0
