"""Pause/resume controller — ESC edge detection + foreground detection via ctypes.

Key advantage over PS1: no console dependency. GetAsyncKeyState and
GetForegroundWindow work regardless of subprocess/stdin redirection.
"""

from __future__ import annotations

import re
import time
from typing import Optional, Set

from . import win32_api

# 机构端窗口标题特征：登录窗口 / 主窗口都含此关键字
DOCTOR_APP_TITLE_REGEX = (
    r"医师电子化注册信息系统|医师电子化注册|"
    r"用户登录|"  # 登录窗口也属于机构端
    r"信息展示|执业信息|详细信息"  # 详情窗口也属于机构端
)


class PauseController:
    def __init__(
        self,
        doctor_app_pids: Optional[Set[int]] = None,
        pause_when_not_foreground: bool = True,
        title_regex: str = DOCTOR_APP_TITLE_REGEX,
    ):
        self.is_paused = False
        self.is_foreground_paused = False
        self.pause_when_not_foreground = pause_when_not_foreground
        self._doctor_app_pids: Set[int] = doctor_app_pids or set()
        self._title_pattern = re.compile(title_regex)
        self._escape_was_down = False
        self._foreground_announced = False

    def add_pid(self, pid: int) -> None:
        """Register a doctor-app PID (e.g. after launching the app mid-session)."""
        if pid:
            self._doctor_app_pids.add(pid)

    def _check_esc_edge(self) -> bool:
        state = win32_api.get_async_key_state(win32_api.VK_ESCAPE)
        down = (state & 0x8000) != 0
        if down and not self._escape_was_down:
            self._escape_was_down = True
            return True
        if not down:
            self._escape_was_down = False
        return False

    def _is_doctor_app_in_foreground(self) -> bool:
        hwnd = win32_api.get_foreground_window()
        if hwnd == 0:
            return False
        # 1) PID 匹配（精确，但要求 PID 已注册）
        _, pid = win32_api.get_window_thread_process_id(hwnd)
        if pid in self._doctor_app_pids:
            return True
        # 2) 标题匹配（不依赖启动时机抓 PID，应用中途启动也能识别）
        title = win32_api.get_window_text(hwnd)
        if title and self._title_pattern.search(title):
            # 顺手把这个 PID 记下来，后续走精确匹配
            self._doctor_app_pids.add(pid)
            return True
        return False

    def _update_foreground_pause(self) -> None:
        if not self.pause_when_not_foreground:
            return
        if not self._is_doctor_app_in_foreground():
            if not self.is_foreground_paused:
                self.is_foreground_paused = True
            if not self._foreground_announced:
                print("[暂停] 机构端不在前台，切回前台后按 ESC 继续。")
                self._foreground_announced = True

    def _handle_toggle(self) -> None:
        if self._is_doctor_app_in_foreground():
            if self.is_paused or self.is_foreground_paused:
                self.is_paused = False
                self.is_foreground_paused = False
                self._foreground_announced = False
                print("[恢复] 已恢复运行。")
            else:
                self.is_paused = True
                print("[暂停] 已暂停，在机构端窗口前台再按 ESC 恢复。")
        else:
            if not (self.is_paused or self.is_foreground_paused):
                self.is_paused = True
                print("[暂停] 已暂停，切回机构端窗口前台后按 ESC 恢复。")
            else:
                print("[提示] 机构端不在前台，请先切回机构端窗口，再按 ESC 恢复。")

    def wait_if_pause_requested(self) -> None:
        toggle = self._check_esc_edge()
        if toggle:
            self._handle_toggle()
        self._update_foreground_pause()
        if not self.is_paused and not self.is_foreground_paused:
            return
        if self.is_paused and not self.is_foreground_paused:
            print("[暂停] 已暂停（在机构端窗口前台再按 ESC 恢复）...")
        while self.is_paused or self.is_foreground_paused:
            time.sleep(0.15)
            if self._check_esc_edge():
                self._handle_toggle()
            self._update_foreground_pause()

    def sleep_with_pause(self, seconds: float) -> None:
        if seconds <= 0:
            return
        deadline = time.time() + seconds
        while time.time() < deadline:
            self.wait_if_pause_requested()
            remaining = deadline - time.time()
            if remaining <= 0:
                break
            time.sleep(min(0.15, remaining))

    def sleep_ms_with_pause(self, milliseconds: int) -> None:
        self.sleep_with_pause(milliseconds / 1000.0)
