"""Input simulation — clicks, paste, IME, keyboard. Replaces PS1 input functions."""

from __future__ import annotations

import time
from typing import Optional, TYPE_CHECKING

import pyperclip

from . import win32_api
from . import windows

if TYPE_CHECKING:
    from .pause import PauseController


def screen_click(x: int, y: int, focus_hwnd: int = 0,
                 pause_ctrl: Optional["PauseController"] = None) -> None:
    if pause_ctrl is not None:
        pause_ctrl.wait_if_pause_requested()
    if focus_hwnd:
        windows.bring_to_front(focus_hwnd)
    win32_api.set_cursor_pos(x, y)
    time.sleep(0.12)
    win32_api.mouse_event(win32_api.MOUSEEVENTF_LEFTDOWN)
    win32_api.mouse_event(win32_api.MOUSEEVENTF_LEFTUP)


def screen_double_click(x: int, y: int, focus_hwnd: int = 0,
                        pause_ctrl: Optional["PauseController"] = None) -> None:
    if pause_ctrl is not None:
        pause_ctrl.wait_if_pause_requested()
    if focus_hwnd:
        windows.bring_to_front(focus_hwnd)
        # 点击前确认焦点确实在目标窗口（最多重试 2 次）
        for _ in range(2):
            fg = win32_api.get_foreground_window()
            if fg == focus_hwnd:
                break
            windows.bring_to_front(focus_hwnd)
    win32_api.set_cursor_pos(x, y)
    time.sleep(0.12)
    # First click
    win32_api.mouse_event(win32_api.MOUSEEVENTF_LEFTDOWN)
    win32_api.mouse_event(win32_api.MOUSEEVENTF_LEFTUP)
    time.sleep(0.06)
    # Second click
    win32_api.mouse_event(win32_api.MOUSEEVENTF_LEFTDOWN)
    win32_api.mouse_event(win32_api.MOUSEEVENTF_LEFTUP)


def set_ime_english_for_foreground() -> None:
    hwnd = win32_api.get_foreground_window()
    if hwnd == 0:
        return
    ime_hwnd = win32_api.imm_get_default_ime_wnd(hwnd)
    if ime_hwnd != 0:
        win32_api.send_message(ime_hwnd, win32_api.WM_IME_CONTROL,
                               win32_api.IMC_SETOPENSTATUS, 0)


def _send_ctrl_key(vk: int) -> None:
    win32_api.send_key(win32_api.VK_CONTROL, key_up=False)
    win32_api.send_key(vk, key_up=False)
    win32_api.send_key(vk, key_up=True)
    win32_api.send_key(win32_api.VK_CONTROL, key_up=True)


def _send_single_key(vk: int) -> None:
    win32_api.send_key(vk, key_up=False)
    win32_api.send_key(vk, key_up=True)


def _send_alt_f4() -> None:
    win32_api.send_key(win32_api.VK_MENU, key_up=False)
    win32_api.send_key(win32_api.VK_F4, key_up=False)
    win32_api.send_key(win32_api.VK_F4, key_up=True)
    win32_api.send_key(win32_api.VK_MENU, key_up=True)


def type_text(text: str) -> None:
    """逐字符键入文本（用 SendInput + VkKeyScanW），适用于禁止粘贴的密码框。
    对 VkKeyScanW 无法映射的字符回退到 Unicode 输入。
    """
    for ch in text:
        code = win32_api.vk_key_scan(ch)
        if code == -1:
            # 无法映射到虚拟键码 → 用 Unicode 输入
            win32_api.send_unicode_key(ch, key_up=False)
            win32_api.send_unicode_key(ch, key_up=True)
        else:
            vk = code & 0xFF
            shift = (code >> 8) & 0x01
            if shift:
                win32_api.send_key(win32_api.VK_SHIFT, key_up=False)
            win32_api.send_key(vk, key_up=False)
            win32_api.send_key(vk, key_up=True)
            if shift:
                win32_api.send_key(win32_api.VK_SHIFT, key_up=True)
        time.sleep(0.02)


def _log_focus(tag: str) -> None:
    """诊断：打印当前前台窗口标题，便于排查焦点问题。"""
    try:
        hwnd = win32_api.get_foreground_window()
        title = win32_api.get_window_text(hwnd) if hwnd else ""
        print(f"  [焦点诊断] {tag}：前台窗口='{title}' hwnd={hwnd}")
    except Exception:
        pass


def click_and_type_text(
    x: int, y: int, text: str,
    focus_hwnd: int = 0,
    pause_ctrl: Optional["PauseController"] = None,
    clear_clipboard_after: bool = False,
) -> bool:
    """点击坐标后逐字符键入文本（不走剪贴板），用于密码框等禁止粘贴的控件。"""
    screen_click(x, y, focus_hwnd=focus_hwnd, pause_ctrl=pause_ctrl)
    time.sleep(0.2)
    _log_focus("点击密码框后")

    for attempt in range(2):
        _send_ctrl_key(win32_api.VK_A)
        time.sleep(0.1)
        _send_single_key(win32_api.VK_DELETE)
        time.sleep(0.12)
        type_text(text)
        time.sleep(0.2)

        current = windows.get_focused_element_value()
        # 密码框通常无法回读（返回 None），按成功处理
        if current is None:
            result = True
            break
        if current:
            result = True
            break
        result = False
        if attempt < 1:
            print("  Warning: 键入后输入框仍为空，重试一次。")
            screen_click(x, y, focus_hwnd=focus_hwnd, pause_ctrl=pause_ctrl)
            time.sleep(0.2)

    if clear_clipboard_after:
        try:
            pyperclip.copy("")
        except Exception:
            pass

    return result


def click_and_paste_text(
    x: int, y: int, text: str,
    focus_hwnd: int = 0,
    pause_ctrl: Optional["PauseController"] = None,
    clear_clipboard_after: bool = False,
) -> bool:
    """
    Click coordinate and paste text via clipboard.
    Returns True if write succeeded or value couldn't be read back.
    Returns False if value pattern supported but readback was empty.
    """
    screen_click(x, y, focus_hwnd=focus_hwnd, pause_ctrl=pause_ctrl)
    time.sleep(0.2)
    _log_focus("点击账号框后")

    for attempt in range(2):
        _send_ctrl_key(win32_api.VK_A)
        time.sleep(0.1)
        _send_single_key(win32_api.VK_DELETE)
        time.sleep(0.1)
        pyperclip.copy(text)
        time.sleep(0.1)
        _send_ctrl_key(win32_api.VK_V)
        time.sleep(0.15)

        current = windows.get_focused_element_value()
        if current is None:
            result = True
            break
        if current:
            result = True
            break
        result = False
        if attempt < 1:
            print("  Warning: 粘贴后输入框仍为空，重试一次。")
            screen_click(x, y, focus_hwnd=focus_hwnd, pause_ctrl=pause_ctrl)
            time.sleep(0.15)

    if clear_clipboard_after:
        try:
            pyperclip.copy("")
        except Exception:
            pass

    return result


def close_window_alt_f4(hwnd: int) -> None:
    """Alt+F4 关闭窗口，并轮询确认窗口已消失（最多 1 秒），
    避免下一行双击点到尚未关干净的详情窗。
    """
    windows.bring_to_front(hwnd)
    _send_alt_f4()
    time.sleep(0.4)
    # 验证窗口已关闭：轮询最多 1 秒
    deadline = time.time() + 1.0
    while time.time() < deadline:
        try:
            fg = win32_api.get_foreground_window()
            # 如果前台仍是该窗口，说明没关掉，再发一次 Alt+F4
            if fg == hwnd:
                _send_alt_f4()
                time.sleep(0.3)
                continue
        except Exception:
            pass
        # 检查窗口是否还可见
        try:
            if not win32_api.is_window_visible(hwnd):
                break
            title = win32_api.get_window_text(hwnd)
            if not title:
                break
        except Exception:
            break
        time.sleep(0.15)


def move_cursor_away(left: int, top: int, width: int, height: int) -> None:
    """Move cursor to bottom-left blank area to avoid hover tooltips."""
    away_x = int(left + 10)
    away_y = int(top + height - 10)
    win32_api.set_cursor_pos(away_x, away_y)
