"""Window management — finding, foreground, maximize. Replaces PS1 window functions."""

from __future__ import annotations

import re
import time
from dataclasses import dataclass
from typing import Optional

import uiautomation as ua

from . import win32_api


@dataclass
class WindowInfo:
    """Lightweight window handle wrapper — avoids holding COM references."""
    hwnd: int
    title: str
    left: int
    top: int
    width: int
    height: int

    @property
    def is_offscreen(self) -> bool:
        return self.width < 2 or self.height < 2


def _control_to_info(ctrl: ua.Control) -> WindowInfo:
    rect = ctrl.BoundingRectangle
    return WindowInfo(
        hwnd=ctrl.NativeWindowHandle,
        title=ctrl.Name or "",
        left=rect.left,
        top=rect.top,
        width=rect.right - rect.left,
        height=rect.bottom - rect.top,
    )


def get_root_windows() -> list[WindowInfo]:
    try:
        results: list[WindowInfo] = []
        root = ua.GetRootControl()
        for child in root.GetChildren():
            if child.ClassName == "" and child.ControlType == ua.ControlType.PaneControl:
                continue
            results.append(_control_to_info(child))
        return results
    except Exception:
        return []


def _find_windows_win32(title_pattern: re.Pattern) -> list[WindowInfo]:
    """纯 Win32 枚举窗口（不依赖 UIA/COM），用于 UIA 崩溃时回退。"""
    results: list[WindowInfo] = []
    for hwnd in win32_api.enum_windows():
        if not win32_api.is_window_visible(hwnd):
            continue
        title = win32_api.get_window_text(hwnd)
        if not title:
            continue
        rect = win32_api.get_window_rect(hwnd)
        if rect is None:
            continue
        left, top, width, height = rect
        results.append(WindowInfo(
            hwnd=hwnd, title=title,
            left=left, top=top, width=width, height=height,
        ))
    return [w for w in results if title_pattern.search(w.title)]


def find_main_window(title_regex: str) -> Optional[WindowInfo]:
    pattern = re.compile(title_regex)
    # 1) 优先 UIA
    try:
        for win in get_root_windows():
            if win.hwnd == 0 or win.is_offscreen:
                continue
            if pattern.search(win.title):
                return win
        for win in get_root_windows():
            if win.hwnd == 0:
                continue
            if win.width > 800 and win.height > 500 and pattern.search(win.title):
                return win
    except Exception:
        pass
    # 2) 回退 Win32（UIA 崩溃时）
    matches = _find_windows_win32(pattern)
    for win in matches:
        if win.hwnd != 0 and not win.is_offscreen:
            return win
    return None


def find_window_by_title(title_regex: str) -> Optional[WindowInfo]:
    pattern = re.compile(title_regex)
    try:
        for win in get_root_windows():
            if win.is_offscreen:
                continue
            if pattern.search(win.title):
                return win
    except Exception:
        pass
    # Win32 回退
    matches = _find_windows_win32(pattern)
    for win in matches:
        if not win.is_offscreen:
            return win
    return None


def wait_window_by_title(title_regex: str, timeout_s: int) -> Optional[WindowInfo]:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        win = find_window_by_title(title_regex)
        if win is not None:
            return win
        time.sleep(0.5)
    return None


def wait_detail_window(
    before_handles: set[int],
    main_hwnd: int,
    title_regex: str,
    timeout_s: int,
) -> Optional[WindowInfo]:
    pattern = re.compile(title_regex)
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        for win in get_root_windows():
            if win.hwnd == 0 or win.hwnd == main_hwnd:
                continue
            if win.is_offscreen:
                continue
            if win.width < 400 or win.height < 250:
                continue
            title_match = bool(pattern.search(win.title))
            is_new = win.hwnd not in before_handles
            if title_match or is_new:
                return win
        time.sleep(0.2)
    return None


def bring_to_front(hwnd: int) -> None:
    """与 PS1 Bring-ToFront 一致：仅最小化时 restore，然后 SetForegroundWindow。"""
    if win32_api.is_iconic(hwnd):
        win32_api.show_window(hwnd, win32_api.SW_RESTORE)
    win32_api.set_foreground_window(hwnd)
    time.sleep(0.2)


def maximize_window(hwnd: int) -> None:
    win32_api.show_window(hwnd, win32_api.SW_MAXIMIZE)
    win32_api.set_foreground_window(hwnd)
    time.sleep(0.5)


def ensure_main_window_maximized(title_regex: str) -> None:
    main = find_main_window(title_regex)
    if main is None or main.hwnd == 0:
        return
    if win32_api.is_zoomed(main.hwnd):
        return
    print("[INFO] 机构端主窗口未最大化，先最大化再继续。")
    maximize_window(main.hwnd)
    bring_to_front(main.hwnd)


def get_window_handles() -> set[int]:
    return {win.hwnd for win in get_root_windows() if win.hwnd != 0}


def get_top_level_titles() -> list[str]:
    titles: list[str] = []
    for hwnd in win32_api.enum_windows():
        if not win32_api.is_window_visible(hwnd):
            continue
        title = win32_api.get_window_text(hwnd)
        if title:
            titles.append(title)
    return titles


def get_focused_element_value() -> Optional[str]:
    """Read focused element's Value pattern. Returns None if unavailable."""
    try:
        focused = ua.GetFocusedElementControl()
        if focused is None:
            return None
        # Try ValuePattern
        try:
            val = focused.GetValuePattern()
            if val is not None:
                return val.Value or ""
        except Exception:
            pass
        return None
    except Exception:
        return None


def get_element_text_summary(hwnd: int) -> str:
    """Get text content from a window's descendants (for error popup detection)."""
    try:
        ctrl = ua.ControlFromHandle(hwnd)
        if ctrl is None:
            return ""
        parts: list[str] = []
        for child in ctrl.GetChildren():
            name = child.Name or ""
            if name.strip():
                ct = child.ControlType
                if ct != ua.ControlType.ButtonControl:
                    parts.append(name.strip())
        return " | ".join(parts)
    except Exception:
        return ""


@dataclass
class EditControlInfo:
    """A found Edit control with its screen coordinates."""
    left: int
    top: int
    right: int
    bottom: int
    name: str
    automation_id: str

    @property
    def center_x(self) -> int:
        return (self.left + self.right) // 2

    @property
    def center_y(self) -> int:
        return (self.top + self.bottom) // 2


def find_edit_controls(hwnd: int, timeout: float = 2.0) -> list[EditControlInfo]:
    """在窗口内查找所有 Edit 控件（输入框），返回其屏幕坐标。
    用于精确定位登录窗口的用户名/密码输入框，避免坐标偏移。
    """
    if hwnd == 0:
        return []
    try:
        ctrl = ua.ControlFromHandle(hwnd)
        if ctrl is None:
            return []
        from uiautomation import ControlType, TreeScope
        cond = ua.Condition(ControlType=ControlType.EditControl)
        found = ctrl.FindAll(TreeScope.Descendants, cond, timeout=timeout)
        results: list[EditControlInfo] = []
        for edit in found:
            rect = edit.BoundingRectangle
            if rect.right > rect.left and rect.bottom > rect.top:
                results.append(EditControlInfo(
                    left=rect.left, top=rect.top,
                    right=rect.right, bottom=rect.bottom,
                    name=edit.Name or "",
                    automation_id=edit.AutomationId or "",
                ))
        return results
    except Exception:
        return []
