"""坐标校准（Python 重写，替代 PS1 Invoke-LoginCalibration / Invoke-Calibration / Invoke-AllCalibration）。

交互式：倒计时读鼠标坐标 → Y 确认 / R 重录 / S 跳过(有已有值) / Q 退出。
结果写入 config.json 的 loginCalibration / listCalibration 段，字段名与 PS1 完全一致。
"""

from __future__ import annotations

import json
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

from . import win32_api

_COUNTDOWN_SECONDS = 5


def _print_step(msg: str) -> None:
    print(f"[INFO] {msg}")


def _read_int_existing(section: dict, x_field: str, y_field: str) -> Optional[tuple[int, int]]:
    try:
        x = int(section.get(x_field, 0))
        y = int(section.get(y_field, 0))
    except (TypeError, ValueError):
        return None
    if x <= 0 and y <= 0:
        return None
    return (x, y)


def _read_row_height_existing(section: dict) -> Optional[int]:
    try:
        h = int(section.get("RowHeight", 0))
    except (TypeError, ValueError):
        return None
    if h < 8:
        return None
    return h


def _countdown(seconds: int) -> None:
    for i in range(seconds, 0, -1):
        print(f"  {i}...")
        time.sleep(1)


def _confirm_prompt(default_yes: bool = True) -> str:
    """返回 'y' / 'r' / 'q' / 's'。空输入按 default_yes。"""
    while True:
        ans = input("  确认使用这个坐标吗？输入 Y 确认，R 重新记录，Q 退出：").strip().upper()
        if ans == "":
            return "y" if default_yes else ""
        if ans in ("Y", "R", "Q"):
            return ans.lower()
        print("  请输入 Y / R / Q。")


def _skip_or_redo_prompt(has_existing: bool) -> str:
    """有已有值时：S 跳过 / Enter 开始 / Q 退出。无已有值：Enter 开始 / Q 退出。"""
    prompt = "  准备开始时按 Enter"
    if has_existing:
        prompt += "（S 跳过保留已有值"
    prompt += "，Q 退出）"
    while True:
        ans = input(prompt + "：").strip().upper()
        if ans == "":
            return "start"
        if ans == "Q":
            return "quit"
        if has_existing and ans == "S":
            return "skip"
        if not has_existing:
            print("  请按 Enter 开始，或输入 Q 退出。")
            continue
        print("  请按 Enter，或输入 S / Q。")


def read_cursor_point_with_confirm(
    title: str,
    instruction: str,
    *,
    existing: Optional[tuple[int, int]] = None,
    countdown_seconds: int = _COUNTDOWN_SECONDS,
) -> tuple[int, int]:
    """倒计时读鼠标坐标；支持 Y 确认 / R 重录 / S 跳过(有已有值) / Q 退出。
    Q 退出抛 RuntimeError；S 跳过返回 existing。
    """
    has_existing = existing is not None and existing[0] > 0 and existing[1] > 0

    while True:
        print()
        _print_step(title)
        print(f"  {instruction}")
        if has_existing:
            print(f"  已有坐标：({existing[0]},{existing[1]})")
        choice = _skip_or_redo_prompt(has_existing)
        if choice == "quit":
            raise RuntimeError("用户取消坐标校准。")
        if choice == "skip":
            _print_step(f"  已跳过，保留已有坐标：({existing[0]},{existing[1]})")
            return existing  # type: ignore[return-value]

        _countdown(countdown_seconds)
        x, y = win32_api.get_cursor_pos()
        _print_step(f"  已记录坐标：{x},{y}")
        conf = _confirm_prompt(default_yes=True)
        if conf == "y":
            return (x, y)
        if conf == "q":
            raise RuntimeError("用户取消坐标校准。")
        # 'r' → 重新记录


def read_row_height_with_confirm(
    title: str,
    instruction: str,
    *,
    first_row_y: int,
    existing_height: Optional[int] = None,
    countdown_seconds: int = _COUNTDOWN_SECONDS,
) -> int:
    """读第 2 行 Y，返回 row_height = y - first_row_y。"""
    has_existing = existing_height is not None and existing_height >= 8

    while True:
        print()
        _print_step(title)
        print(f"  {instruction}")
        if has_existing:
            print(f"  已有行高：{existing_height}px")
        choice = _skip_or_redo_prompt(has_existing)
        if choice == "quit":
            raise RuntimeError("用户取消坐标校准。")
        if choice == "skip":
            _print_step(f"  已跳过，保留已有行高：{existing_height}px")
            return existing_height  # type: ignore[return-value]

        _countdown(countdown_seconds)
        _, y = win32_api.get_cursor_pos()
        _print_step(f"  已记录坐标：Y={y}")
        conf = _confirm_prompt(default_yes=True)
        if conf == "y":
            return max(8, y - first_row_y)
        if conf == "q":
            raise RuntimeError("用户取消坐标校准。")


# ---------------------------------------------------------------------------
# 配置读写
# ---------------------------------------------------------------------------

def _load_config(config_path: Path) -> dict:
    with config_path.open(encoding="utf-8-sig") as f:
        return json.load(f)


def _save_section(config_path: Path, section_name: str, section_data: dict) -> None:
    """合并 section 到 config.json，保留其它键和格式。"""
    cfg = _load_config(config_path)
    cfg[section_name] = section_data
    with config_path.open("w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def _wait_enter(prompt: str) -> None:
    input(prompt)


# ---------------------------------------------------------------------------
# 校准编排
# ---------------------------------------------------------------------------

def _upsert_and_save(config_path: Path, section_name: str, section: dict, updates: dict) -> None:
    """合并 updates 到 section，更新 SavedAt，立即写盘。"""
    section.update(updates)
    section["SavedAt"] = datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    _save_section(config_path, section_name, section)


def calibrate_login(config_path: Path) -> None:
    """登录坐标校准 6 步 → loginCalibration（每步确认后立即落盘）。"""
    cfg = _load_config(config_path)
    section: dict = dict(cfg.get("loginCalibration") or {})

    print()
    _print_step("登录坐标校准开始。请打开医师系统登录页。")
    _print_step("每一步都会等待你按 Enter 后才记录坐标，并允许确认或重录。")
    _print_step("已有坐标的步骤可输入 S 跳过（每步确认后立即保存，可随时中断单独改某步）。")
    _wait_enter("登录页准备好后按 Enter 开始校准：")

    def step(n: int, total: int, title: str, instr: str, x_field: str, y_field: str) -> None:
        ex = _read_int_existing(section, x_field, y_field)
        x, y = read_cursor_point_with_confirm(
            f"登录校准 第{n}/{total}步：{title}", instr, existing=ex,
        )
        _upsert_and_save(config_path, "loginCalibration", section, {x_field: x, y_field: y})
        _print_step(f"  已保存 {x_field}/{y_field} = ({x},{y}) 到 config.json")

    step(1, 6, "切换登录方式", "把鼠标移到右上角【切换登录方式】链接中间。", "SwitchLoginX", "SwitchLoginY")
    step(2, 6, "账号输入框", "切换到账号登录界面后，把鼠标移到【账号输入框】中间。", "UserX", "UserY")
    step(3, 6, "密码输入框", "把鼠标移到【密码输入框】中间。", "PasswordX", "PasswordY")
    step(4, 6, "登录按钮", "把鼠标移到【登录】按钮中间。", "LoginButtonX", "LoginButtonY")

    print()
    _print_step("第5、6步需要校准登录后的两个列表入口。")
    _print_step("请先手动登录，等待主页加载完成，然后继续。")
    _wait_enter("主页已经加载完成后按 Enter 继续：")

    step(5, 6, "主执业机构在本院医师入口", "把鼠标移到主页左侧【主执业机构在本院医师】入口中间。", "MainInstitutionX", "MainInstitutionY")
    step(6, 6, "外院在本院多执业医师入口", "把鼠标移到【外院在本院多执业医师】入口中间。", "MultiInstitutionX", "MultiInstitutionY")

    _print_step(f"登录坐标已全部保存到 {config_path} 的 loginCalibration")


def calibrate_list(config_path: Path) -> None:
    """列表坐标校准 3 步 → listCalibration（每步确认后立即落盘）。"""
    cfg = _load_config(config_path)
    section: dict = dict(cfg.get("listCalibration") or {})

    print()
    _print_step("列表坐标校准开始。请保证医师系统已打开，并停留在医师列表页。")
    _print_step("请先随便搜索一个常见姓名/姓氏，让列表至少显示两行结果。")
    _print_step("已有坐标的步骤可输入 S 跳过（每步确认后立即保存，可随时中断单独改某步）。")
    _wait_enter("列表准备好后按 Enter 开始校准：")

    # 第1步：搜索框
    ex_search = _read_int_existing(section, "SearchBoxX", "SearchBoxY")
    search = read_cursor_point_with_confirm(
        "列表校准 第1/3步：医师姓名输入框",
        "把鼠标移到【医师姓名】输入框中间。",
        existing=ex_search,
    )
    _upsert_and_save(config_path, "listCalibration", section,
                     {"SearchBoxX": search[0], "SearchBoxY": search[1]})
    _print_step(f"  已保存 SearchBoxX/SearchBoxY = ({search[0]},{search[1]})")

    # 第2步：第1行姓名格
    ex_row1 = _read_int_existing(section, "NameX", "FirstRowY")
    row1 = read_cursor_point_with_confirm(
        "列表校准 第2/3步：第1行姓名单元格",
        "把鼠标移到列表【第 1 行】的【姓名】单元格中间。",
        existing=ex_row1,
    )
    _upsert_and_save(config_path, "listCalibration", section,
                     {"NameX": row1[0], "FirstRowY": row1[1]})
    _print_step(f"  已保存 NameX/FirstRowY = ({row1[0]},{row1[1]})")

    # 第3步：第2行 → 行高
    ex_height = _read_row_height_existing(section)
    row_height = read_row_height_with_confirm(
        "列表校准 第3/3步：第2行姓名单元格",
        "把鼠标移到列表【第 2 行】的【姓名】单元格中间。",
        first_row_y=row1[1],
        existing_height=ex_height,
    )
    _upsert_and_save(config_path, "listCalibration", section, {"RowHeight": row_height})
    _print_step(f"  已保存 RowHeight = {row_height}")

    _print_step(f"列表坐标已全部保存到 {config_path} 的 listCalibration")
    _print_step(
        f"搜索框=({search[0]},{search[1]}) 姓名列X={row1[0]} "
        f"首行Y={row1[1]} 行高={row_height}"
    )
    _print_step("现在可以运行：python -m src.cli capture-institution")


def calibrate_all(config_path: Path) -> None:
    """登录 + 列表 串跑（= PS1 CalibrateAll）。"""
    calibrate_login(config_path)
    print()
    _print_step("登录校准已完成。下面开始列表截图坐标校准。")
    _print_step("请确保已经进入【主执业机构在本院医师】列表页，并让列表至少显示两行结果。")
    _wait_enter("列表页准备好后按 Enter 开始列表坐标校准：")
    calibrate_list(config_path)
    print()
    _print_step(f"所有坐标已保存到 {config_path}")
