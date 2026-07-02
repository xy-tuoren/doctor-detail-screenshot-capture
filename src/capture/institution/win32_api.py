"""Win32 API wrappers via ctypes — mirrors PS1 NativeWin32 class."""

from __future__ import annotations

import ctypes
import time
from ctypes import wintypes
from typing import Optional

user32 = ctypes.windll.user32
imm32 = ctypes.windll.imm32
kernel32 = ctypes.windll.kernel32

# --- Key codes ---
VK_ESCAPE = 0x1B
VK_CONTROL = 0x11
VK_SPACE = 0x20
VK_MENU = 0x12  # Alt
VK_DELETE = 0x2E
VK_A = 0x41
VK_V = 0x56
VK_F4 = 0x73

# --- ShowWindow commands ---
SW_RESTORE = 5
SW_MAXIMIZE = 3

# --- SetWindowPos flags ---
SWP_NOMOVE = 0x0002
SWP_NOSIZE = 0x0001
SWP_NOACTIVATE = 0x0010
SWP_SHOWWINDOW = 0x0040
HWND_TOPMOST = ctypes.c_void_p(-1)
HWND_NOTOPMOST = ctypes.c_void_p(-2)

# --- mouse_event flags ---
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004

# --- IME ---
WM_IME_CONTROL = 0x0283
IMC_SETOPENSTATUS = 0x0006

# --- SendInput ---
INPUT_KEYBOARD = 1
KEYEVENTF_KEYUP = 0x0002
KEYEVENTF_EXTENDEDKEY = 0x0001

# --- Function prototypes ---
user32.SetForegroundWindow.argtypes = [wintypes.HWND]
user32.SetForegroundWindow.restype = wintypes.BOOL

user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
user32.ShowWindow.restype = wintypes.BOOL

user32.IsZoomed.argtypes = [wintypes.HWND]
user32.IsZoomed.restype = wintypes.BOOL

user32.IsIconic.argtypes = [wintypes.HWND]
user32.IsIconic.restype = wintypes.BOOL

user32.SetWindowPos.argtypes = [
    wintypes.HWND, ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
    ctypes.c_int, ctypes.c_int, ctypes.c_uint,
]
user32.SetWindowPos.restype = wintypes.BOOL

user32.SetCursorPos.argtypes = [ctypes.c_int, ctypes.c_int]
user32.SetCursorPos.restype = wintypes.BOOL

user32.mouse_event.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p]
user32.mouse_event.restype = None

user32.GetAsyncKeyState.argtypes = [ctypes.c_int]
user32.GetAsyncKeyState.restype = ctypes.c_short

user32.GetForegroundWindow.argtypes = []
user32.GetForegroundWindow.restype = wintypes.HWND

user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD

user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL

user32.SendMessageW.argtypes = [wintypes.HWND, ctypes.c_uint, wintypes.WPARAM, wintypes.LPARAM]
user32.SendMessageW.restype = wintypes.LPARAM

user32.ImmGetDefaultIMEWnd = imm32.ImmGetDefaultIMEWnd
imm32.ImmGetDefaultIMEWnd.argtypes = [wintypes.HWND]
imm32.ImmGetDefaultIMEWnd.restype = wintypes.HWND

# EnumWindows
WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
user32.EnumWindows.restype = wintypes.BOOL

user32.GetWindowTextLengthW.argtypes = [wintypes.HWND]
user32.GetWindowTextLengthW.restype = ctypes.c_int

user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.GetWindowTextW.restype = ctypes.c_int

user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetWindowRect.restype = wintypes.BOOL

# EnumChildWindows — enumerate child windows (for reading dialog text without UIA)
user32.EnumChildWindows.argtypes = [wintypes.HWND, WNDENUMPROC, wintypes.LPARAM]
user32.EnumChildWindows.restype = wintypes.BOOL

# WM_GETTEXT — retrieve window text (works for Static/Label/Edit controls)
WM_GETTEXT = 0x000D
WM_GETTEXTLENGTH = 0x000E

# AttachThreadInput — for reliable SetForegroundWindow from background process
user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]
user32.AttachThreadInput.restype = wintypes.BOOL

kernel32.GetCurrentThreadId.argtypes = []
kernel32.GetCurrentThreadId.restype = wintypes.DWORD

# SwitchToThisWindow — undocumented but widely used for forcing foreground
user32.SwitchToThisWindow.argtypes = [wintypes.HWND, wintypes.BOOL]
user32.SwitchToThisWindow.restype = None

SWP_SHOWWINDOW = 0x0040


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_void_p),
    ]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", wintypes.LONG),
        ("dy", wintypes.LONG),
        ("mouseData", wintypes.DWORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ctypes.c_void_p),
    ]


class INPUT_UNION(ctypes.Union):
    _fields_ = [
        ("ki", KEYBDINPUT),
        ("mi", MOUSEINPUT),
    ]


class INPUT(ctypes.Structure):
    _fields_ = [
        ("type", wintypes.DWORD),
        ("union", INPUT_UNION),
    ]


user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wintypes.UINT

# VkKeyScanW — map a character to a virtual-key code + shift state
user32.VkKeyScanW.argtypes = [wintypes.WCHAR]
user32.VkKeyScanW.restype = ctypes.c_short

KEYEVENTF_UNICODE = 0x0004


def set_cursor_pos(x: int, y: int) -> bool:
    return bool(user32.SetCursorPos(x, y))


def mouse_event(flags: int, dx: int = 0, dy: int = 0, data: int = 0) -> None:
    user32.mouse_event(flags, dx, dy, data, None)


def get_foreground_window() -> int:
    return user32.GetForegroundWindow() or 0


def set_foreground_window(hwnd: int) -> bool:
    return bool(user32.SetForegroundWindow(hwnd))


def show_window(hwnd: int, cmd: int) -> bool:
    return bool(user32.ShowWindow(hwnd, cmd))


def is_zoomed(hwnd: int) -> bool:
    return bool(user32.IsZoomed(hwnd))


def is_iconic(hwnd: int) -> bool:
    return bool(user32.IsIconic(hwnd))


def set_window_pos(hwnd: int, after: int, x: int = 0, y: int = 0,
                   cx: int = 0, cy: int = 0, flags: int = 0) -> bool:
    return bool(user32.SetWindowPos(hwnd, after, x, y, cx, cy, flags))


def get_async_key_state(vkey: int) -> int:
    return user32.GetAsyncKeyState(vkey)


def get_window_thread_process_id(hwnd: int) -> tuple[int, int]:
    pid = wintypes.DWORD()
    tid = user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
    return tid, pid.value


def get_window_text(hwnd: int) -> str:
    length = user32.GetWindowTextLengthW(hwnd)
    if length <= 0:
        return ""
    buf = ctypes.create_unicode_buffer(length + 1)
    user32.GetWindowTextW(hwnd, buf, length + 1)
    return buf.value


def send_message(hwnd: int, msg: int, wparam: int, lparam: int) -> int:
    return user32.SendMessageW(hwnd, msg, wparam, lparam)


def imm_get_default_ime_wnd(hwnd: int) -> int:
    return imm32.ImmGetDefaultIMEWnd(hwnd) or 0


def is_window_visible(hwnd: int) -> bool:
    return bool(user32.IsWindowVisible(hwnd))


def enum_windows() -> list[int]:
    handles: list[int] = []

    def _callback(hwnd: int, _lparam: int) -> bool:
        handles.append(hwnd)
        return True

    user32.EnumWindows(WNDENUMPROC(_callback), 0)
    return handles


def send_key(vk: int, key_up: bool = False) -> None:
    inp = INPUT()
    inp.type = INPUT_KEYBOARD
    inp.union.ki.wVk = vk
    inp.union.ki.dwFlags = KEYEVENTF_KEYUP if key_up else 0
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def send_key_combo_press(vk: int, *, hold: bool = False, release: bool = True) -> None:
    send_key(vk, key_up=False)
    if release:
        send_key(vk, key_up=True)


def send_key_sequence(keys_down: list[int], keys_up: list[int]) -> None:
    for vk in keys_down:
        send_key(vk, key_up=False)
    for vk in reversed(keys_up):
        send_key(vk, key_up=True)


def vk_key_scan(char: str) -> int:
    """Map a character to (shift_state << 8) | vk_code. Returns -1 if unmappable."""
    return user32.VkKeyScanW(char)


def send_unicode_key(char: str, key_up: bool = False) -> None:
    """Send a character as Unicode input (for chars VkKeyScanW can't map)."""
    inp = INPUT()
    inp.type = INPUT_KEYBOARD
    inp.union.ki.wVk = 0
    inp.union.ki.wScan = ord(char)
    flags = KEYEVENTF_UNICODE
    if key_up:
        flags |= KEYEVENTF_KEYUP
    inp.union.ki.dwFlags = flags
    user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))


def get_window_rect(hwnd: int) -> tuple[int, int, int, int] | None:
    """返回 (left, top, width, height)，失败返回 None。"""
    rect = wintypes.RECT()
    if not user32.GetWindowRect(hwnd, ctypes.byref(rect)):
        return None
    return (rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top)


def enum_child_windows(hwnd: int) -> list[int]:
    """枚举指定窗口的所有子窗口句柄（纯 Win32，不依赖 UIA/COM）。"""
    handles: list[int] = []

    def _callback(child: int, _lparam: int) -> bool:
        handles.append(child)
        return True

    user32.EnumChildWindows(hwnd, WNDENUMPROC(_callback), 0)
    return handles


def get_window_text_via_message(hwnd: int) -> str:
    """通过 WM_GETTEXT 读取控件文本（对 Static/Label/Edit 有效）。
    比 GetWindowTextW 更可靠地获取对话框内文本。
    """
    length = user32.SendMessageW(hwnd, WM_GETTEXTLENGTH, 0, 0)
    if length <= 0:
        return ""
    buf = ctypes.create_unicode_buffer(length + 1)
    user32.SendMessageW(hwnd, WM_GETTEXT, length + 1, ctypes.addressof(buf))
    return buf.value


def get_child_window_texts(hwnd: int) -> list[str]:
    """收集窗口内所有子控件的文本（用于弹窗内容检测，纯 Win32）。"""
    texts: list[str] = []
    for child in enum_child_windows(hwnd):
        if not is_window_visible(child):
            continue
        txt = get_window_text_via_message(child)
        if txt and txt.strip():
            texts.append(txt.strip())
    return texts


def attach_thread_input(tid_attach: int, tid_attach_to: int, attach: bool) -> bool:
    """AttachThreadInput — 共享输入队列，用于绕过 Windows 前台焦点限制。"""
    return bool(user32.AttachThreadInput(tid_attach, tid_attach_to, attach))


def get_current_thread_id() -> int:
    return kernel32.GetCurrentThreadId()


def switch_to_this_window(hwnd: int) -> None:
    """Undocumented API — often succeeds when SetForegroundWindow is blocked."""
    if hwnd:
        user32.SwitchToThisWindow(hwnd, True)


def force_foreground_window(hwnd: int, *, max_attempts: int = 6) -> bool:
    """Force a window to the foreground from a background Python process.

    Combines PS1 TOPMOST dance, Alt-key trick, dual AttachThreadInput, and
    SwitchToThisWindow. Returns True if foreground hwnd matches target.
    """
    if hwnd == 0:
        return False

    swp_flags = SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW
    target_tid, _ = get_window_thread_process_id(hwnd)
    cur_tid = get_current_thread_id()

    for _ in range(max_attempts):
        show_window(hwnd, SW_RESTORE)
        set_window_pos(hwnd, HWND_TOPMOST, flags=swp_flags)
        time.sleep(0.05)
        set_window_pos(hwnd, HWND_NOTOPMOST, flags=swp_flags)

        # Alt trick — grants SetForegroundWindow permission in many cases
        send_key(VK_MENU, key_up=False)
        send_key(VK_MENU, key_up=True)

        fg_hwnd = get_foreground_window()
        fg_tid = 0
        if fg_hwnd:
            fg_tid, _ = get_window_thread_process_id(fg_hwnd)

        attached_fg = False
        attached_target = False
        try:
            if fg_tid and fg_tid != cur_tid:
                attach_thread_input(cur_tid, fg_tid, True)
                attached_fg = True
            if target_tid and target_tid != cur_tid:
                attach_thread_input(cur_tid, target_tid, True)
                attached_target = True
            set_foreground_window(hwnd)
            switch_to_this_window(hwnd)
        finally:
            if attached_target:
                attach_thread_input(cur_tid, target_tid, False)
            if attached_fg:
                attach_thread_input(cur_tid, fg_tid, False)

        time.sleep(0.12)
        if get_foreground_window() == hwnd:
            return True

        # 最后手段：点击窗口标题栏区域（模拟用户操作，Windows 通常允许激活）
        rect = get_window_rect(hwnd)
        if rect is not None:
            left, top, w, _h = rect
            if w > 50:
                set_cursor_pos(left + w // 2, top + 12)
                time.sleep(0.05)
                mouse_event(MOUSEEVENTF_LEFTDOWN)
                mouse_event(MOUSEEVENTF_LEFTUP)
                time.sleep(0.12)
                if get_foreground_window() == hwnd:
                    return True

    return get_foreground_window() == hwnd
