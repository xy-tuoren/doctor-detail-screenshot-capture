"""Pause/resume controller — Ctrl+Space edge detection + foreground detection via ctypes.

Key advantage over PS1: no console dependency. GetAsyncKeyState and
GetForegroundWindow work regardless of subprocess/stdin redirection.

Hotkey detection runs in a background daemon thread polling every 50ms, so
pause is responsive even during click sequences (where the main thread is
busy with bring_to_front / mouse_event and cannot poll).
"""

from __future__ import annotations

import re
import threading
import time
from typing import Optional, Set

from . import win32_api

# 机构端窗口标题特征：登录窗口 / 主窗口都含此关键字
DOCTOR_APP_TITLE_REGEX = (
    r"医师电子化注册信息系统|医师电子化注册|"
    r"用户登录|"  # 登录窗口也属于机构端
    r"信息展示|执业信息|详细信息"  # 详情窗口也属于机构端
)

_PAUSE_HOTKEY_HINT = "Ctrl+空格"
# 轮询间隔（秒）
_POLL_INTERVAL = 0.05


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
        self._foreground_announced = False

        # Ctrl+Space 后台轮询
        self._hotkey_thread: Optional[threading.Thread] = None
        self._hotkey_thread_stop = threading.Event()
        self._hotkey_was_down = False
        self._hotkey_lock = threading.Lock()
        self._toggle_pending = False  # 热键边沿触发，待主线程处理

    def add_pid(self, pid: int) -> None:
        """Register a doctor-app PID (e.g. after launching the app mid-session)."""
        if pid:
            self._doctor_app_pids.add(pid)

    # ------------------------------------------------------------------
    # Ctrl+Space 后台轮询线程
    # ------------------------------------------------------------------
    @staticmethod
    def _is_hotkey_down() -> bool:
        ctrl = (win32_api.get_async_key_state(win32_api.VK_CONTROL) & 0x8000) != 0
        space = (win32_api.get_async_key_state(win32_api.VK_SPACE) & 0x8000) != 0
        return ctrl and space

    def _hotkey_poll_loop(self) -> None:
        """后台线程：每 50ms 检测 Ctrl+Space 边沿，触发后立即设置 toggle_pending。"""
        while not self._hotkey_thread_stop.is_set():
            try:
                down = self._is_hotkey_down()
                with self._hotkey_lock:
                    if down and not self._hotkey_was_down:
                        self._hotkey_was_down = True
                        if self.is_paused or self.is_foreground_paused:
                            # 已暂停 → 交给主线程处理恢复（需检查前台）
                            self._toggle_pending = True
                        else:
                            # 未暂停 → 立即暂停，不等到下一个检查点
                            self.is_paused = True
                            print(
                                f"[暂停] 已暂停，在机构端窗口前台再按 {_PAUSE_HOTKEY_HINT} 恢复。"
                            )
                    elif not down:
                        self._hotkey_was_down = False
            except Exception:
                pass
            self._hotkey_thread_stop.wait(_POLL_INTERVAL)

    def start_hotkey_thread(self) -> None:
        """启动 Ctrl+Space 后台轮询线程（daemon，进程退出自动结束）。"""
        if self._hotkey_thread is not None:
            return
        self._hotkey_thread = threading.Thread(
            target=self._hotkey_poll_loop, daemon=True, name="pause-hotkey-poll"
        )
        self._hotkey_thread.start()

    def start_esc_thread(self) -> None:
        """兼容旧调用名。"""
        self.start_hotkey_thread()

    def stop_hotkey_thread(self) -> None:
        self._hotkey_thread_stop.set()
        self._hotkey_thread = None

    # ------------------------------------------------------------------
    # 前台检测
    # ------------------------------------------------------------------
    def _is_doctor_app_in_foreground(self) -> bool:
        hwnd = win32_api.get_foreground_window()
        if hwnd == 0:
            return False
        _, pid = win32_api.get_window_thread_process_id(hwnd)
        if pid in self._doctor_app_pids:
            return True
        title = win32_api.get_window_text(hwnd)
        if title and self._title_pattern.search(title):
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
                print(f"[暂停] 机构端不在前台，切回前台后按 {_PAUSE_HOTKEY_HINT} 继续。")
                self._foreground_announced = True

    # ------------------------------------------------------------------
    # 暂停 / 恢复
    # ------------------------------------------------------------------
    def _handle_toggle(self) -> None:
        if self._is_doctor_app_in_foreground():
            if self.is_paused or self.is_foreground_paused:
                self.is_paused = False
                self.is_foreground_paused = False
                self._foreground_announced = False
                print("[恢复] 已恢复运行。")
            else:
                self.is_paused = True
                print(f"[暂停] 已暂停，在机构端窗口前台再按 {_PAUSE_HOTKEY_HINT} 恢复。")
        else:
            if not (self.is_paused or self.is_foreground_paused):
                self.is_paused = True
                print(f"[暂停] 已暂停，切回机构端窗口前台后按 {_PAUSE_HOTKEY_HINT} 恢复。")
            else:
                print(
                    f"[提示] 机构端不在前台，请先切回机构端窗口，再按 {_PAUSE_HOTKEY_HINT} 恢复。"
                )

    def _consume_toggle(self) -> bool:
        """消费热键 toggle 标志，返回 True 表示有待处理的 toggle。"""
        with self._hotkey_lock:
            if self._toggle_pending:
                self._toggle_pending = False
                return True
            return False

    def is_pause_active(self) -> bool:
        """快速检查是否处于暂停状态（不检测热键、不检测前台，只看标志）。
        用于点击函数执行前快速判断，避免在暂停时继续点击。
        """
        return self.is_paused or self.is_foreground_paused

    def wait_if_pause_requested(self) -> None:
        """主线程检查点：处理热键 toggle + 前台检测，若暂停则阻塞到恢复。"""
        if self._consume_toggle():
            self._handle_toggle()
        self._update_foreground_pause()
        if not self.is_paused and not self.is_foreground_paused:
            return
        if self.is_paused and not self.is_foreground_paused:
            print(f"[暂停] 已暂停（在机构端窗口前台再按 {_PAUSE_HOTKEY_HINT} 恢复）...")
        while self.is_paused or self.is_foreground_paused:
            time.sleep(0.1)
            if self._consume_toggle():
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
            time.sleep(min(0.1, remaining))

    def sleep_ms_with_pause(self, milliseconds: int) -> None:
        self.sleep_with_pause(milliseconds / 1000.0)
