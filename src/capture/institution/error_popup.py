"""Error popup detection and auto-restart. Replaces PS1 Find-ErrorPopup + recovery."""

from __future__ import annotations

import csv
import os
import re
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

import psutil

from . import win32_api, windows

DEFAULT_ERROR_TEXT_REGEX = (
    r"非法访问用户身份|禁止\s*Web\s*服务调用|获取详细信息时发生错误|服务调用\(1\)"
)
DEFAULT_ERROR_TITLE_REGEX = r"提示|错误|异常|警告"


def find_error_popup(
    text_regex: str = DEFAULT_ERROR_TEXT_REGEX,
    title_regex: str = DEFAULT_ERROR_TITLE_REGEX,
) -> Optional[str]:
    """Scan top-level windows for error popup. Returns combined title|text if found."""
    text_pat = re.compile(text_regex)
    title_pat = re.compile(title_regex)
    for win in windows.get_root_windows():
        if win.is_offscreen:
            continue
        title = win.title
        text_summary = windows.get_element_text_summary(win.hwnd)
        combined = f"{title} | {text_summary}"
        if text_pat.search(combined) or (title and title_pat.search(title) and text_pat.search(text_summary)):
            return combined
    return None


def write_error_popup_log(
    log_path: Path,
    context: str,
    popup_text: str,
    count: int,
    captured_since_last: int,
    last_time: Optional[datetime],
) -> datetime:
    now = datetime.now()
    seconds_since = ""
    if last_time is not None:
        seconds_since = str(int((now - last_time).total_seconds()))
    clean = re.sub(r"\s+", " ", popup_text).strip()[:200]
    log_path.parent.mkdir(parents=True, exist_ok=True)
    write_header = not log_path.exists()
    with log_path.open("a", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f)
        if write_header:
            writer.writerow([
                "Timestamp", "Count", "SecondsSinceLast",
                "CapturedSinceLast", "Context", "PopupText",
            ])
        writer.writerow([
            now.strftime("%Y-%m-%d %H:%M:%S"),
            count, seconds_since, captured_since_last, context, clean,
        ])
    print(
        f"[ERROR] 接口异常弹窗第 {count} 次："
        f"距上次 {seconds_since or '—'} 秒，期间成功截图 {captured_since_last} 张。"
    )
    return now


def stop_doctor_application(app_path: str, post_wait_s: int = 1) -> int:
    """Kill all doctor application processes."""
    print("[INFO] 关闭医师系统应用...")
    killed = 0
    proc_name = os.path.splitext(os.path.basename(app_path))[0] if app_path else ""
    for proc in psutil.process_iter(["pid", "name", "username"]):
        try:
            name = proc.info["name"] or ""
            if proc_name and proc_name.lower() in name.lower():
                proc.kill()
                killed += 1
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass
    print(f"[INFO] 已结束 {killed} 个相关进程。")
    if post_wait_s > 0:
        time.sleep(post_wait_s)
    return killed
