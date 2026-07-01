"""Login flow and list navigation. Replaces PS1 Invoke-LoginToHome + Invoke-EnterListFromHome."""

from __future__ import annotations

import os
import re
import subprocess
import time
from pathlib import Path
from typing import Optional, Set

import psutil

from . import input as inp
from . import screenshot, windows
from .pause import PauseController

DOCTOR_APP_EXE = "医师电子化注册信息系统（机构版）.exe"
LOGIN_WINDOW_REGEX = r"用户登录|医师电子化注册信息系统"
MAIN_WINDOW_REGEX = r"医师电子化注册信息系统|机构版"


def _resolve_shortcut(lnk_path: str) -> Optional[str]:
    try:
        import pythoncom
        from win32com.shell import shell
        shortcut = pythoncom.CoCreateInstance(
            shell.CLSID_ShellLink, None, pythoncom.CLSCTX_INPROC_SERVER, shell.IID_IShellLink
        )
        shortcut.QueryInterface(pythoncom.IID_IPersistFile).Load(lnk_path)
        return shortcut.GetPath(0)[0]
    except Exception:
        return None


def resolve_doctor_app_path(config_app_path: str = "") -> Optional[str]:
    """Resolve app path: config → running process → shortcuts → drive search."""
    if config_app_path and os.path.isfile(config_app_path):
        return config_app_path
    if config_app_path:
        print(f"[INFO] 配置的 appPath 不存在，将自动查找：{config_app_path}")

    # 1. Running process — match by name, then resolve exe path (handle AccessDenied)
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            name = proc.info["name"] or ""
            if DOCTOR_APP_EXE.lower() not in name.lower():
                continue
            exe = None
            try:
                exe = proc.exe()  # may raise AccessDenied for elevated procs
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                exe = None
            if exe and os.path.isfile(exe):
                print(f"[INFO] 自动找到应用（运行中的进程）：{exe}")
                return exe
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue

    # 1b. Fallback: find via window title → PID → exe (handles elevated processes)
    import re as _re
    from . import win32_api
    for hwnd in win32_api.enum_windows():
        if not win32_api.is_window_visible(hwnd):
            continue
        title = win32_api.get_window_text(hwnd)
        if not title:
            continue
        if _re.search(LOGIN_WINDOW_REGEX, title) or _re.search(MAIN_WINDOW_REGEX, title):
            _, pid = win32_api.get_window_thread_process_id(hwnd)
            try:
                p = psutil.Process(pid)
                exe = p.exe()
                if exe and os.path.isfile(exe):
                    print(f"[INFO] 自动找到应用（窗口标题→进程）：{exe}")
                    return exe
            except (psutil.AccessDenied, psutil.NoSuchProcess):
                continue

    # 2. Shortcuts — resolve Start Menu / Desktop folders via env vars (reliable)
    shortcut_roots: list[str] = []
    _candidates = [
        os.path.join(os.environ.get("APPDATA", ""), "Microsoft", "Windows", "Start Menu", "Programs"),
        os.path.join(os.environ.get("ProgramData", ""), "Microsoft", "Windows", "Start Menu", "Programs"),
        os.path.join(os.environ.get("USERPROFILE", ""), "Desktop"),
        os.path.join(os.environ.get("PUBLIC", ""), "Desktop"),
    ]
    for p in _candidates:
        if p and os.path.isdir(p) and p not in shortcut_roots:
            shortcut_roots.append(p)

    for root in shortcut_roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirs, files in os.walk(root):
            for f in files:
                if not f.lower().endswith(".lnk"):
                    continue
                if "医师电子化注册" not in f and DOCTOR_APP_EXE not in f:
                    continue
                target = _resolve_shortcut(os.path.join(dirpath, f))
                if target and os.path.isfile(target):
                    print(f"[INFO] 自动找到应用（开始菜单/桌面快捷方式）：{target}")
                    return target

    # 3. Common install dirs on fixed drives
    import string
    drives = [f"{d}:\\" for d in string.ascii_uppercase if os.path.exists(f"{d}:\\")]
    relative_paths = [
        os.path.join("医师电子化注册信息系统（机构版）", DOCTOR_APP_EXE),
        os.path.join("北京民科医疗科技有限公司", "医师电子化注册信息系统（机构版）", DOCTOR_APP_EXE),
    ]
    for drive in drives:
        for rel in relative_paths:
            candidate = os.path.join(drive, rel)
            if os.path.isfile(candidate):
                print(f"[INFO] 自动找到应用（磁盘搜索）：{candidate}")
                return candidate

    return None


def get_doctor_app_pids(app_path: str = "") -> Set[int]:
    """Get all PIDs related to the doctor application."""
    pids: Set[int] = set()
    proc_name = os.path.splitext(os.path.basename(app_path))[0] if app_path else ""
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            name = proc.info["name"] or ""
            if proc_name and proc_name.lower() in name.lower():
                pids.add(proc.info["pid"])
                continue
            # Also check by window title via Win32
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    # Also add PIDs whose windows match doctor app title
    from . import win32_api
    for hwnd in win32_api.enum_windows():
        if not win32_api.is_window_visible(hwnd):
            continue
        title = win32_api.get_window_text(hwnd)
        if not title:
            continue
        if re.search(MAIN_WINDOW_REGEX, title) or re.search(LOGIN_WINDOW_REGEX, title):
            _, pid = win32_api.get_window_thread_process_id(hwnd)
            pids.add(pid)
    return pids


def start_doctor_application(app_path: str) -> None:
    if not app_path or not os.path.isfile(app_path):
        print("[INFO] 未找到 appPath，将使用当前已打开的医师系统窗口。")
        return
    print(f"[INFO] 启动应用：{app_path}")
    subprocess.Popen([app_path])


def _register_app_pid(pause_ctrl: PauseController, hwnd: int) -> None:
    """Register a window's PID with the pause controller for foreground detection."""
    if hwnd == 0:
        return
    try:
        from . import win32_api
        _, pid = win32_api.get_window_thread_process_id(hwnd)
        if pid:
            pause_ctrl.add_pid(pid)
    except Exception:
        pass


def detect_app_state() -> tuple[str, Optional[windows.WindowInfo]]:
    """探测机构端当前所处阶段。
    返回 (state, window):
      - "not_running"  应用未启动（无匹配窗口）
      - "login_screen" 处于登录界面（窗口标题含"用户登录"）
      - "logged_in"    已登录主窗口（标题不含"用户登录"，尺寸足够大）
    """
    # 先查登录窗口（标题含"用户登录"）
    login_win = windows.find_window_by_title(LOGIN_WINDOW_REGEX)
    if login_win is not None and login_win.hwnd != 0:
        if "用户登录" in login_win.title or login_win.width < 800:
            return ("login_screen", login_win)

    # 再查主窗口（已登录）
    main = windows.find_main_window(MAIN_WINDOW_REGEX)
    if main is not None and main.hwnd != 0:
        if "用户登录" not in main.title and main.width > 800 and main.height > 500:
            return ("logged_in", main)
        # 主窗口但标题含"用户登录"或尺寸小 → 视为登录界面
        if "用户登录" in main.title:
            return ("login_screen", main)

    return ("not_running", None)


def detect_list_page(main_hwnd: int, list_cfg: dict) -> bool:
    """探测是否已在列表页：用 UIA 在主窗口内找 Edit 控件（搜索框）。
    找到 → 已在列表页；找不到或异常 → 无法确认，返回 False（保守，让调用方重新进列表）。
    """
    if main_hwnd == 0:
        return False
    try:
        import uiautomation as ua
        ctrl = ua.ControlFromHandle(main_hwnd)
        if ctrl is None:
            return False
        # 在主窗口子孙中找 Edit 控件（搜索输入框），限时避免卡死
        edit = ctrl.EditControl(searchDepth=10, timeout=1.0)
        if edit is not None and edit.Exists(0.5, 0.1):
            return True
    except Exception:
        pass
    return False


def _dismiss_blocking_popups(pause_ctrl: PauseController, max_rounds: int = 5) -> None:
    """清除挡在前台的「提示」「错误」等弹窗（上次登录失败遗留的）。
    通过发 Enter/Escape 关闭有焦点的弹窗，直到前台不再是弹窗。
    """
    from . import win32_api
    for _ in range(max_rounds):
        hwnd = win32_api.get_foreground_window()
        if hwnd == 0:
            return
        title = win32_api.get_window_text(hwnd)
        # 登录窗口/主窗口不是弹窗，无需清除
        if not title or title in ("", "用户登录") or re.search(MAIN_WINDOW_REGEX, title):
            return
        # 标题是「提示」「错误」「警告」等 → 弹窗，发 Enter 关闭
        if re.search(r"提示|错误|警告|异常|信息", title):
            print(f"[INFO] 检测到弹窗「{title}」，发送 Enter 关闭。")
            win32_api.send_key(win32_api.VK_CONTROL, key_up=False)  # Ctrl (for 确定(O))
            # 实际上"确定(O)"的快捷键是 Alt+O，但 Enter 也能激活默认按钮
            win32_api.send_key(win32_api.VK_CONTROL, key_up=True)
            import time as _t
            _t.sleep(0.05)
            win32_api.send_key(0x0D, key_up=False)  # VK_RETURN
            win32_api.send_key(0x0D, key_up=True)
            _t.sleep(0.3)
            continue
        # 其他未知窗口标题 → 不处理
        return


def _do_login_clicks(
    login_win: windows.WindowInfo,
    config: dict,
    pause_ctrl: PauseController,
    *,
    switch_login_method: bool = True,
) -> None:
    """在已找到的登录窗口上执行登录点击（纯坐标点击，与 PS1 一致）。
    switch_login_method=True 时先点「切换登录方式」（用于新启动的应用，默认扫码模式→切到账号密码模式）；
    switch_login_method=False 时跳过切换（用于已在登录界面的应用，避免 toggle 切回扫码模式）。
    """
    login_cfg = config.get("loginCalibration") or {}

    # 先清除可能遗留的弹窗（上次登录失败的「请您输入密码」等）
    _dismiss_blocking_popups(pause_ctrl)

    windows.bring_to_front(login_win.hwnd)

    if switch_login_method:
        print("[INFO] 点击\"切换登录方式\"（新启动应用，从扫码模式切到账号密码模式）。")
        inp.screen_click(
            int(login_cfg["SwitchLoginX"]), int(login_cfg["SwitchLoginY"]),
            focus_hwnd=login_win.hwnd, pause_ctrl=pause_ctrl,
        )
        time.sleep(1.0)
        screenshot.wait_rect_stable(
            login_win.left, login_win.top, login_win.width, login_win.height,
            timeout_s=4, stable_checks=1,
        )
    else:
        print("[INFO] 跳过\"切换登录方式\"（应用已在登录界面，避免 toggle 切回扫码模式）。")

    user_x = int(login_cfg["UserX"])
    user_y = int(login_cfg["UserY"])
    pwd_x = int(login_cfg["PasswordX"])
    pwd_y = int(login_cfg["PasswordY"])

    print(f"[INFO] 输入账号（校准坐标 {user_x},{user_y}）。")
    inp.click_and_paste_text(
        user_x, user_y,
        config.get("loginUser", ""),
        focus_hwnd=login_win.hwnd, pause_ctrl=pause_ctrl,
    )

    print(f"[INFO] 输入密码（校准坐标 {pwd_x},{pwd_y}，逐字符键入）。")
    inp.click_and_type_text(
        pwd_x, pwd_y,
        config.get("loginPassword", ""),
        focus_hwnd=login_win.hwnd, pause_ctrl=pause_ctrl,
        clear_clipboard_after=True,
    )

    print("[INFO] 点击登录。")
    inp.screen_click(
        int(login_cfg["LoginButtonX"]), int(login_cfg["LoginButtonY"]),
        focus_hwnd=login_win.hwnd, pause_ctrl=pause_ctrl,
    )


def _finalize_main_window(
    main_win: windows.WindowInfo,
    pause_ctrl: PauseController,
    post_login_wait_s: int,
) -> windows.WindowInfo:
    """注册 PID + 前台 + 最大化 + 等稳定，返回最终主窗口。"""
    _register_app_pid(pause_ctrl, main_win.hwnd)
    windows.bring_to_front(main_win.hwnd)
    windows.maximize_window(main_win.hwnd)
    main_win = windows.find_main_window(MAIN_WINDOW_REGEX)
    if main_win is None:
        raise RuntimeError("最大化主窗口后主窗口丢失。")
    _register_app_pid(pause_ctrl, main_win.hwnd)
    screenshot.wait_rect_stable(
        main_win.left, main_win.top, main_win.width, main_win.height,
        timeout_s=post_login_wait_s, stable_checks=2,
    )
    print("[INFO] 主页已稳定。")
    return main_win


def login_to_home(
    config: dict,
    pause_ctrl: PauseController,
    *,
    login_wait_s: int = 90,
    post_login_wait_s: int = 8,
) -> windows.WindowInfo:
    """根据机构端当前阶段智能登录：已登录→跳过；登录界面→直接登录；未启动→启动+登录。"""
    login_cfg = config.get("loginCalibration") or {}
    required = ["SwitchLoginX", "SwitchLoginY", "UserX", "UserY",
                "PasswordX", "PasswordY", "LoginButtonX", "LoginButtonY"]
    missing = [f for f in required if f not in login_cfg]
    if missing:
        raise RuntimeError(f"登录坐标缺失: {missing}，请在 config.json loginCalibration 中配置。")

    app_path = resolve_doctor_app_path(config.get("appPath", ""))
    state, win = detect_app_state()
    print(f"[INFO] 探测到当前阶段：{state}")

    # ── 已登录：跳过登录 ──
    if state == "logged_in" and win is not None:
        print("[INFO] 医师系统已登录，跳过登录流程。")
        return _finalize_main_window(win, pause_ctrl, post_login_wait_s)

    # ── 登录界面：直接登录，不重新启动应用，跳过「切换登录方式」避免 toggle ──
    if state == "login_screen" and win is not None:
        print("[INFO] 检测到登录窗口，开始登录（不重新启动应用）。")
        _register_app_pid(pause_ctrl, win.hwnd)
        _do_login_clicks(win, config, pause_ctrl, switch_login_method=False)
        print("[INFO] 等待主页加载完成。")
        main_win = _wait_logged_in_main_window(login_wait_s)
        if main_win is None:
            raise RuntimeError("登录后未检测到主窗口，请检查账号密码或网络加载状态。")
        return _finalize_main_window(main_win, pause_ctrl, post_login_wait_s)

    # ── 未启动：启动应用 + 登录 ──
    print("[INFO] 医师系统未运行，启动应用。")
    start_doctor_application(app_path or "")
    login_win = windows.wait_window_by_title(LOGIN_WINDOW_REGEX, login_wait_s)
    if login_win is None or login_win.hwnd == 0:
        # 启动后可能直接进主窗口（免密/已登录）
        main_check = windows.find_main_window(MAIN_WINDOW_REGEX)
        if main_check is not None and "用户登录" not in main_check.title \
                and main_check.width > 800 and main_check.height > 500:
            print("[INFO] 应用启动后直接进入主窗口，跳过登录。")
            return _finalize_main_window(main_check, pause_ctrl, post_login_wait_s)
        raise RuntimeError("登录窗口未出现。请检查 appPath 或登录窗口标题。")

    _register_app_pid(pause_ctrl, login_win.hwnd)
    _do_login_clicks(login_win, config, pause_ctrl, switch_login_method=True)
    print("[INFO] 等待主页加载完成。")
    main_win = _wait_logged_in_main_window(login_wait_s)
    if main_win is None:
        raise RuntimeError("登录后未检测到主窗口，请检查账号密码或网络加载状态。")
    return _finalize_main_window(main_win, pause_ctrl, post_login_wait_s)


def _wait_logged_in_main_window(timeout_s: int) -> Optional[windows.WindowInfo]:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            main = windows.find_main_window(MAIN_WINDOW_REGEX)
            if main is not None:
                title = main.title
                if "用户登录" not in title and main.width > 800 and main.height > 500:
                    return main
        except Exception as e:
            # UIA COM 错误时静默重试（find_main_window 内部已有 Win32 回退）
            print(f"  [诊断] 等待主窗口时异常（将重试）：{e}")
        time.sleep(0.7)
    return None


def enter_list_from_home(
    main_win: windows.WindowInfo,
    list_entry: str,
    config: dict,
    pause_ctrl: PauseController,
    *,
    post_login_wait_s: int = 8,
) -> windows.WindowInfo:
    """从主页进入医生列表；若已在列表页则跳过入口点击。"""
    login_cfg = config.get("loginCalibration") or {}
    list_cfg = config.get("listCalibration") or {}

    print("[INFO] 激活并最大化医师系统窗口。")
    windows.bring_to_front(main_win.hwnd)
    windows.maximize_window(main_win.hwnd)
    main_win = windows.find_main_window(MAIN_WINDOW_REGEX)
    if main_win is None:
        raise RuntimeError("最大化窗口后主窗口丢失。")
    windows.bring_to_front(main_win.hwnd)
    screenshot.wait_rect_stable(
        main_win.left, main_win.top, main_win.width, main_win.height,
        timeout_s=post_login_wait_s, stable_checks=2,
    )

    # 探测是否已在列表页（UIA 找到搜索框 Edit 控件）
    if detect_list_page(main_win.hwnd, list_cfg):
        print("[INFO] 探测到已在列表页，跳过入口点击。")
        return main_win

    if list_entry == "Multi":
        entry_x = int(login_cfg.get("MultiInstitutionX", 0))
        entry_y = int(login_cfg.get("MultiInstitutionY", 0))
        if entry_x <= 0 and entry_y <= 0:
            raise RuntimeError("未找到【外院在本院多执业医师】入口坐标。请先完成登录校准第6步。")
        print("[INFO] 点击\"外院在本院多执业医师\"。")
    else:
        entry_x = int(login_cfg.get("MainInstitutionX", 0))
        entry_y = int(login_cfg.get("MainInstitutionY", 0))
        print("[INFO] 点击\"主执业机构在本院医师\"。")

    inp.screen_click(entry_x, entry_y, focus_hwnd=main_win.hwnd, pause_ctrl=pause_ctrl)
    time.sleep(2)

    main_win = windows.find_main_window(MAIN_WINDOW_REGEX)
    if main_win is None:
        raise RuntimeError("点击入口后主窗口丢失。")
    windows.bring_to_front(main_win.hwnd)

    # Wait for list to stabilize — use main window area
    if screenshot.wait_rect_stable(
        main_win.left, main_win.top, main_win.width, main_win.height,
        timeout_s=post_login_wait_s, stable_checks=2,
    ):
        print("[INFO] 列表页已稳定。")
    else:
        print("[WARN] 列表区域未完全稳定，仍将继续执行。")

    return main_win
