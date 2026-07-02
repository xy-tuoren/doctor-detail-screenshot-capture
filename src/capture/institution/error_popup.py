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

# 接口异常 / 身份失效 / 验证码 等需要重启恢复的错误文本
DEFAULT_ERROR_TEXT_REGEX = (
    r"非法访问用户身份|非法的用户身份|生法的用户身份|禁止\s*Web\s*服务调用|"
    r"获取详细信息时发生错误|欧取.*信息时发生|服务调用\(1\)|"
    r"接口错误|统口错误|错.*号[:：]?\s*\d{6,}|"
    r"身份.*失效|登录.*失效|会话.*过期|请.*重新登录"
)
DEFAULT_ERROR_TITLE_REGEX = r"提示|错误|异常|警告|信息"
# 采图阶段：这些短标题几乎一定是接口异常弹窗（无需 OCR 命中关键词）
_ERROR_TITLE_EXACT = re.compile(r"^(提示|错误|异常|警告|信息)$")

# 主窗口标题关键词（用于排除主窗口，避免误判）
MAIN_WINDOW_KEYWORDS = r"医师电子化注册|莲藕健康|版本号"

VK_RETURN = 0x0D


def _find_popup_windows_by_title(title_pat: re.Pattern) -> list[tuple[int, str, tuple]]:
    """用纯 Win32 枚举所有可见顶层窗口，返回标题匹配错误弹窗模式的窗口列表。
    返回 [(hwnd, title, (left, top, width, height)), ...]
    排除主窗口（标题含「医师电子化注册」「莲藕健康」等）。

    严格过滤避免误判：
    - 标题长度 ≤ 10 字符（弹窗标题如「提示」「错误」都很短，
      避免匹配到「医生医疗机构信息.note - Google Chrome」等长标题）
    - 窗口尺寸宽 ≥ 150、高 ≥ 80（排除浏览器标签栏等极小窗口）
    """
    results: list[tuple[int, str, tuple]] = []
    main_pat = re.compile(MAIN_WINDOW_KEYWORDS)
    for hwnd in win32_api.enum_windows():
        if not win32_api.is_window_visible(hwnd):
            continue
        title = win32_api.get_window_text(hwnd)
        if not title:
            continue
        # 排除主窗口
        if main_pat.search(title):
            continue
        # 标题必须匹配弹窗模式且足够短（弹窗标题如「提示」只有 2 字）
        if not title_pat.search(title):
            continue
        if len(title) > 10:
            continue
        rect = win32_api.get_window_rect(hwnd)
        if rect is None:
            continue
        left, top, w, h = rect
        # 排除极小窗口（浏览器标签栏等）
        if w < 150 or h < 80:
            continue
        results.append((hwnd, title, (left, top, w, h)))
    return results


def _ocr_popup_rect(left: int, top: int, w: int, h: int) -> str:
    """截图指定屏幕区域并 OCR 识别文本。失败返回空字符串。
    使用纯 PIL ImageGrab，不依赖 UIA（Web 弹窗 UIA 会崩溃）。
    """
    try:
        from . import ocr as ocr_mod, screenshot as ss_mod
        img = ss_mod.capture_screen_rect(left, top, w, h)
        if img is None:
            return ""
        try:
            text = ocr_mod.recognize_image(img)
            return text or ""
        finally:
            img.close()
    except Exception:
        return ""


def _scan_main_window_for_error(main_hwnd: int, text_pat: re.Pattern) -> Optional[str]:
    """主窗口内嵌弹窗（无独立 hwnd）时，OCR 主窗口中央区域。"""
    if main_hwnd == 0:
        return None
    rect = win32_api.get_window_rect(main_hwnd)
    if rect is None:
        return None
    left, top, w, h = rect
    if w < 200 or h < 200:
        return None
    # 中央偏上：列表页接口异常弹窗通常在此
    cx0 = left + int(w * 0.18)
    cy0 = top + int(h * 0.22)
    cx1 = left + int(w * 0.82)
    cy1 = top + int(h * 0.72)
    ocr_text = _ocr_popup_rect(cx0, cy0, cx1 - cx0, cy1 - cy0)
    if not ocr_text.strip():
        return None
    combined = f"main-window | {ocr_text}"
    if text_pat.search(combined):
        return combined
    return None


def find_error_popup(
    text_regex: str = DEFAULT_ERROR_TEXT_REGEX,
    title_regex: str = DEFAULT_ERROR_TITLE_REGEX,
    *,
    main_hwnd: int = 0,
    deep_scan: bool = False,
) -> Optional[str]:
    """扫描顶层窗口寻找错误弹窗。

    deep_scan=False（默认）：仅 Win32 找「提示/错误」短标题窗，命中即返回，不 OCR 主窗口。
    deep_scan=True：额外 OCR 弹窗正文、主窗口中央、UIA 回退（用于详情失败等可疑场景）。
    """
    text_pat = re.compile(text_regex)
    title_pat = re.compile(title_regex)
    main_pat = re.compile(MAIN_WINDOW_KEYWORDS)

    candidates = _find_popup_windows_by_title(title_pat)
    for hwnd, title, (left, top, w, h) in candidates:
        if _ERROR_TITLE_EXACT.match(title.strip()):
            return f"{title} | (按标题判定)"
        if not deep_scan:
            continue
        ocr_text = _ocr_popup_rect(left, top, w, h)
        combined = f"{title} | {ocr_text}"
        if text_pat.search(combined):
            return combined

    if not deep_scan:
        return None

    embedded = _scan_main_window_for_error(main_hwnd, text_pat)
    if embedded:
        return embedded

    try:
        for hwnd in win32_api.enum_windows():
            if not win32_api.is_window_visible(hwnd):
                continue
            title = win32_api.get_window_text(hwnd) or ""
            if main_pat.search(title):
                continue
            summary = windows.get_element_text_summary(hwnd)
            if not summary:
                continue
            combined = f"{title} | {summary}"
            if text_pat.search(combined):
                return combined
    except Exception:
        pass

    return None


def dismiss_error_popup(max_rounds: int = 3) -> bool:
    """关闭前台错误弹窗（发送 Enter 激活「确定」按钮）。
    返回 True 表示至少关闭了一个弹窗。
    只关闭标题短（≤10字符）且匹配弹窗模式的窗口，避免误关浏览器等。
    """
    dismissed = False
    title_pat = re.compile(DEFAULT_ERROR_TITLE_REGEX)
    main_pat = re.compile(MAIN_WINDOW_KEYWORDS)
    for _ in range(max_rounds):
        hwnd = win32_api.get_foreground_window()
        if hwnd == 0:
            break
        title = win32_api.get_window_text(hwnd)
        if not title:
            break
        # 主窗口不关
        if main_pat.search(title):
            break
        # 标题必须匹配弹窗模式且足够短
        if not title_pat.search(title) or len(title) > 10:
            break
        print(f"[INFO] 检测到弹窗「{title}」，发送 Enter 关闭。")
        win32_api.send_key(VK_RETURN, key_up=False)
        win32_api.send_key(VK_RETURN, key_up=True)
        time.sleep(0.3)
        dismissed = True
    return dismissed


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
