"""Core capture loop — search, double-click rows, screenshot, OCR, save.
Replaces PS1 Capture-NameSeries + Invoke-CaptureNameSeriesWithRecovery.
"""

from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from . import error_popup, input as inp, ocr, screenshot, windows
from .login import MAIN_WINDOW_REGEX, enter_list_from_home, login_to_home, resolve_doctor_app_path
from .pause import PauseController
from .windows import WindowInfo

DETAIL_WINDOW_REGEX = r"信息展示|执业信息|详细信息"
DEFAULT_MAX_ROWS = 50
DEFAULT_SEARCH_WAIT_S = 3
DEFAULT_DETAIL_WAIT_S = 6
DEFAULT_CONTENT_TIMEOUT_S = 12
DEFAULT_STOP_AFTER_FAILURES = 3
DEFAULT_MAX_RESTARTS = 100
DEFAULT_RESTART_WAIT_S = 5
DEFAULT_REST_INTERVAL = 100
DEFAULT_REST_MINUTES = 5

# 列表表头常见词（首行 OCR 命中这些且无姓名 → 视为无数据）
_LIST_HEADER_WORDS = frozenset({
    "姓名", "性别", "年龄", "民族", "医师类别", "医师级别", "执业范围",
    "资格证书编码", "执业证书编码", "所在科室", "任职资格", "详细信息",
    "医师账户状态", "是否修改", "查看", "电子证照",
})


def _ocr_list_first_row(name_x: int, first_row_y: int, row_height: int) -> str:
    """OCR 列表第 1 行姓名列区域（使用校准屏幕坐标）。"""
    pad_x = 40
    width = max(280, row_height * 10)
    height = max(row_height, 28)
    left = max(0, name_x - pad_x)
    top = first_row_y
    img = screenshot.capture_screen_rect(left, top, width, height)
    try:
        return ocr.recognize_image(img)
    finally:
        img.close()


def _row_text_looks_like_name(text: str) -> bool:
    if not text or not text.strip():
        return False
    compact = re.sub(r"\s+", "", text)
    if re.search(
        r"执业证书编码|资格证书编码|详细信息|医师账户状态|医师类别|医师级别|是否修改",
        compact,
    ):
        return False
    for m in re.finditer(r"[\u4e00-\u9fa5·]{2,4}", compact):
        if m.group() not in _LIST_HEADER_WORDS:
            return True
    return False


def _is_search_result_empty(name_x: int, first_row_y: int, row_height: int) -> bool:
    """搜索后列表第 1 行无姓名 → 判定无结果。"""
    try:
        text = _ocr_list_first_row(name_x, first_row_y, row_height)
    except Exception:
        return False
    return not _row_text_looks_like_name(text)


@dataclass
class Person:
    name: str
    cert_code: str


@dataclass
class CaptureResult:
    total_saved: int = 0
    need_restart: bool = False
    saved_files: list[str] = field(default_factory=list)


def _sanitize_filename(value: str) -> str:
    if not value or not value.strip():
        return "unknown"
    invalid = set('<>:"/\\|?*') | set(chr(i) for i in range(32))
    clean = re.sub(r"\s+", "", "".join(c if c not in invalid else "_" for c in value.strip()))
    if len(clean) > 40:
        clean = clean[:40]
    return clean or "unknown"


def _person_output_base(person: Person) -> str:
    safe_name = _sanitize_filename(person.name)
    if not person.cert_code:
        return safe_name
    return f"{safe_name}_{_sanitize_filename(person.cert_code)}"


def _person_already_captured(output_dir: Path, person: Person) -> bool:
    if not person.cert_code:
        return False
    path = output_dir / f"{_person_output_base(person)}.png"
    if path.exists():
        return True
    # Fuzzy match: any file starting with name_
    prefix = f"{_sanitize_filename(person.name)}_"
    for p in output_dir.glob(f"{prefix}*.png"):
        return True
    return False


def _find_person_by_cert(candidates: list[Person], ocr_cert: str) -> Optional[Person]:
    norm = ocr.normalize_cert_code(ocr_cert)
    if not norm:
        return None
    for person in candidates:
        p_norm = ocr.normalize_cert_code(person.cert_code)
        if not p_norm:
            continue
        if p_norm == norm or norm in p_norm or p_norm in norm:
            return person
    return None


def _wait_detail_content_ready(
    hwnd: int,
    pause_ctrl: PauseController,
    timeout_s: int = DEFAULT_CONTENT_TIMEOUT_S,
) -> tuple[Optional[object], Optional[dict]]:
    """
    Wait for detail window content to finish loading.
    Returns (PIL Image, OCR fields dict) or (last_image, None) on timeout.
    """
    deadline = time.time() + timeout_s
    prev_hash = ""
    stable_count = 0
    last_image = None
    last_fields: Optional[dict] = None

    while time.time() < deadline:
        pause_ctrl.wait_if_pause_requested()
        try:
            img = screenshot.capture_window_bitmap(hwnd)
        except Exception:
            time.sleep(0.35)
            continue

        h = screenshot.get_bitmap_hash(img)
        if h == prev_hash:
            stable_count += 1
        else:
            stable_count = 0
            prev_hash = h

        if last_image is not None:
            last_image.close()
        last_image = img

        if stable_count >= 1:
            # 画面稳定后 OCR 一次：证书区判定加载完成，并顺带提取姓名
            cert_text = ocr.recognize_cert_region(img)
            if not ocr.test_loading_text(cert_text):
                fields = ocr.recognize_detail_fields(img, cert_text=cert_text)
                if fields.get("certCode"):
                    return img, fields
                last_fields = fields

        pause_ctrl.sleep_with_pause(0.25)

    return last_image, last_fields


def _detect_error_popup(
    context: str,
    main_hwnd: int = 0,
    *,
    deep_scan: bool = False,
) -> Optional[str]:
    """检测接口异常弹窗；若发现则关闭弹窗并返回弹窗文本，否则返回 None。"""
    popup = error_popup.find_error_popup(main_hwnd=main_hwnd, deep_scan=deep_scan)
    if not popup:
        return None
    print(f"  [ERROR] 检测到接口异常弹窗（{context}）：{popup[:120]}")
    error_popup.dismiss_error_popup()
    return popup


def _handle_error_popup_restart(
    result: CaptureResult,
    context: str,
    main_hwnd: int,
    *,
    error_log_path: Optional[Path],
    error_count: int,
    captured_since_last_popup: int,
    last_error_time: Optional[object],
    deep_scan: bool = False,
) -> tuple[bool, int, int, Optional[object]]:
    """若检测到接口异常弹窗则标记 need_restart。返回 (triggered, error_count, captured_since, last_time)。"""
    popup = _detect_error_popup(context, main_hwnd, deep_scan=deep_scan)
    if not popup:
        return False, error_count, captured_since_last_popup, last_error_time
    error_count += 1
    if error_log_path:
        last_error_time = error_popup.write_error_popup_log(
            error_log_path, context, popup, error_count,
            captured_since_last_popup, last_error_time,
        )
    print("  检测到接口异常弹窗，将重启应用并恢复抓取。")
    result.need_restart = True
    return True, error_count, 0, last_error_time


def capture_name_series(
    main_win: WindowInfo,
    persons: list[Person],
    config: dict,
    output_dir: Path,
    pause_ctrl: PauseController,
    *,
    search_wait_s: int = DEFAULT_SEARCH_WAIT_S,
    detail_wait_s: int = DEFAULT_DETAIL_WAIT_S,
    max_rows: int = DEFAULT_MAX_ROWS,
    content_timeout_s: int = DEFAULT_CONTENT_TIMEOUT_S,
    stop_after_failures: int = DEFAULT_STOP_AFTER_FAILURES,
    rest_interval: int = DEFAULT_REST_INTERVAL,
    rest_minutes: int = DEFAULT_REST_MINUTES,
    error_log_path: Optional[Path] = None,
) -> CaptureResult:
    """Main capture loop: search by name, iterate rows, screenshot, save."""
    result = CaptureResult()
    list_cfg = config.get("listCalibration") or {}
    required = ["SearchBoxX", "SearchBoxY", "NameX", "FirstRowY", "RowHeight"]
    missing = [f for f in required if f not in list_cfg]
    if missing:
        raise RuntimeError(f"列表坐标缺失: {missing}，请在 config.json listCalibration 中配置。")

    search_x = int(list_cfg["SearchBoxX"])
    search_y = int(list_cfg["SearchBoxY"])
    name_x = int(list_cfg["NameX"])
    first_row_y = int(list_cfg["FirstRowY"])
    row_height = int(list_cfg["RowHeight"])

    output_dir.mkdir(parents=True, exist_ok=True)

    # Filter out already captured
    pending = [p for p in persons if not _person_already_captured(output_dir, p)]
    skipped = len(persons) - len(pending)
    if skipped:
        print(f"[INFO] 跳过已有截图 {skipped} 人。")

    print(f"[INFO] 截图保存目录：{output_dir}")
    print(f"[INFO] 待抓取 {len(pending)} 人，OCR=True")

    # Group by name
    groups: dict[str, list[Person]] = {}
    for p in pending:
        groups.setdefault(p.name, []).append(p)

    error_count = 0
    last_error_time = None
    captured_since_last_popup = 0
    main_hwnd = main_win.hwnd
    popup_checked_recently = False
    last_capture_saved = False

    for search_name, group_persons in groups.items():
        pause_ctrl.wait_if_pause_requested()
        remaining = list(group_persons)

        print(f"=== 搜索姓名：{search_name}（待抓取 {len(remaining)} 人）===")

        # 搜索前检测遗留弹窗（若上一轮关详情刚查过则跳过，避免重复 OCR）
        if not popup_checked_recently:
            triggered, error_count, captured_since_last_popup, last_error_time = _handle_error_popup_restart(
                result, f"搜索前 name={search_name}", main_hwnd,
                error_log_path=error_log_path,
                error_count=error_count,
                captured_since_last_popup=captured_since_last_popup,
                last_error_time=last_error_time,
                deep_scan=False,
            )
            if triggered:
                return result
        popup_checked_recently = False

        # Search（与 PS1 一致：粘贴后按 Enter 触发查询，再等待列表刷新）
        try:
            inp.click_and_paste_text(
                search_x, search_y, search_name,
                focus_hwnd=main_hwnd, pause_ctrl=pause_ctrl,
            )
            inp.press_enter(pause_ctrl=pause_ctrl)
        except Exception as e:
            print(f"  输入姓名失败：{e}")
            continue

        # Readback verification
        val = windows.get_focused_element_value()
        if val is not None:
            print(f"  [诊断] 姓名框回读值='{val}'")
            if not val:
                print(f"  [ERROR] 姓名搜索框未能写入内容，跳过。")
                continue

        pause_ctrl.sleep_with_pause(search_wait_s)

        # 上一轮已成功采图时列表通常正常，跳过空列表 OCR（省 ~4s）
        if not last_capture_saved and _is_search_result_empty(name_x, first_row_y, row_height):
            print(f"  搜索 '{search_name}' 列表无结果，跳过该姓名。")
            continue
        last_capture_saved = False

        seen_signatures: set[str] = set()
        seen_ocr_certs: set[str] = set()
        consecutive_failures = 0
        previous_detail_hash = ""

        for row in range(max_rows):
            if not remaining:
                break

            pause_ctrl.wait_if_pause_requested()
            x = name_x
            y = first_row_y + row * row_height

            before_handles = windows.get_window_handles()

            # Double-click row
            inp.screen_double_click(x, y, focus_hwnd=main_hwnd, pause_ctrl=pause_ctrl)

            # Wait for detail window
            detail = windows.wait_detail_window(
                before_handles, main_hwnd, DETAIL_WINDOW_REGEX, detail_wait_s,
            )

            # 首行未检测到详情：若已有新窗口（详情加载中），继续等，不要立刻再双击
            if detail is None and row == 0:
                if windows.has_new_sizable_window(before_handles, main_hwnd):
                    print("  检测到新窗口（详情加载中），延长等待，不重复双击。")
                    detail = windows.wait_detail_window(
                        before_handles, main_hwnd, DETAIL_WINDOW_REGEX, detail_wait_s + 4,
                    )
                if detail is None:
                    pause_ctrl.sleep_with_pause(1.5)
                    # 只有完全没有新窗口时才重试双击
                    if not windows.has_new_sizable_window(before_handles, main_hwnd):
                        print("  未检测到详情窗口，重试双击第 1 行。")
                        before_handles = windows.get_window_handles()
                        inp.screen_double_click(
                            x, y, focus_hwnd=main_hwnd, pause_ctrl=pause_ctrl,
                        )
                        detail = windows.wait_detail_window(
                            before_handles, main_hwnd, DETAIL_WINDOW_REGEX, detail_wait_s,
                        )
                    else:
                        detail = windows.wait_detail_window(
                            before_handles, main_hwnd, DETAIL_WINDOW_REGEX, detail_wait_s + 2,
                        )

            if detail is None:
                triggered, error_count, captured_since_last_popup, last_error_time = _handle_error_popup_restart(
                    result, f"name={search_name};row={row + 1}", main_hwnd,
                    error_log_path=error_log_path,
                    error_count=error_count,
                    captured_since_last_popup=captured_since_last_popup,
                    last_error_time=last_error_time,
                    deep_scan=True,
                )
                if triggered:
                    return result
                if row == 0:
                    print(f"  未出现详情窗口，'{search_name}' 可能无结果。")
                else:
                    print(f"  第 {row + 1} 行无更多结果，结束该姓名。")
                break

            detail_hwnd = detail.hwnd
            file_name = None
            target_person = None

            try:
                # Wait for content ready（稳定后 OCR 一次，结果复用）
                img, ready_fields = _wait_detail_content_ready(
                    detail_hwnd, pause_ctrl, content_timeout_s,
                )
                if img is None:
                    triggered, error_count, captured_since_last_popup, last_error_time = _handle_error_popup_restart(
                        result, f"content-timeout name={search_name};row={row + 1}", main_hwnd,
                        error_log_path=error_log_path,
                        error_count=error_count,
                        captured_since_last_popup=captured_since_last_popup,
                        last_error_time=last_error_time,
                        deep_scan=True,
                    )
                    if triggered:
                        return result
                    print(f"  第 {row + 1} 行详情内容等待超时。")
                    if row == 0:
                        print(f"  搜索 '{search_name}' 列表无有效详情，跳过该姓名。")
                        break
                    consecutive_failures += 1
                    if consecutive_failures >= stop_after_failures:
                        print(f"  连续 {consecutive_failures} 行失败，停止该姓名。")
                        break
                    continue

                detail_hash = screenshot.get_bitmap_hash(img)
                if previous_detail_hash and detail_hash == previous_detail_hash:
                    print(f"  第 {row + 1} 行详情与上一行相同，判定为空行重复，结束该姓名。")
                    img.close()
                    break
                previous_detail_hash = detail_hash

                fields = ready_fields or ocr.recognize_detail_fields(img)
                ocr_cert = fields.get("certCode")
                ocr_name = fields.get("name")

                if ocr_name and ocr_name != search_name:
                    print(
                        f"  [提示] 第 {row + 1} 行 OCR 姓名={ocr_name} 与搜索名 {search_name} 不一致，"
                        f"改以证书编号为准继续判断。"
                    )

                if not ocr_cert:
                    triggered, error_count, captured_since_last_popup, last_error_time = _handle_error_popup_restart(
                        result, f"no-cert name={search_name};row={row + 1}", main_hwnd,
                        error_log_path=error_log_path,
                        error_count=error_count,
                        captured_since_last_popup=captured_since_last_popup,
                        last_error_time=last_error_time,
                        deep_scan=True,
                    )
                    if triggered:
                        return result
                    print(f"  第 {row + 1} 行未识别到执业证书编号，跳过。")
                    img.close()
                    if row == 0:
                        print(f"  搜索 '{search_name}' 列表无有效详情，跳过该姓名。")
                        break
                    consecutive_failures += 1
                    if consecutive_failures >= stop_after_failures:
                        print(f"  连续 {consecutive_failures} 行失败，停止该姓名。")
                        break
                    continue

                norm_cert = ocr.normalize_cert_code(ocr_cert)
                if norm_cert in seen_ocr_certs:
                    print(f"  第 {row + 1} 行再次出现证书编号 {norm_cert}，结束该姓名。")
                    img.close()
                    break
                seen_ocr_certs.add(norm_cert)

                target_person = _find_person_by_cert(remaining, ocr_cert)
                if target_person is None:
                    print(f"  第 {row + 1} 行证书编号 {norm_cert} 不在待抓取名单，跳过。")
                    img.close()
                    # Check if already captured
                    probe = Person(search_name, norm_cert)
                    if len(remaining) == 1 and _person_already_captured(output_dir, probe):
                        print(f"  搜索结果为已截图人员；待抓取的未出现在列表中，结束。")
                        break
                    continue

                # Check duplicate
                sig = f"cert:{ocr.normalize_cert_code(target_person.cert_code)}"
                if sig in seen_signatures:
                    print(f"  第 {row + 1} 行与已截取的记录重复，停止该姓名。")
                    img.close()
                    break
                if _person_already_captured(output_dir, target_person):
                    print(f"  第 {row + 1} 行对应人员已有截图，停止该姓名。")
                    img.close()
                    break

                seen_signatures.add(sig)
                base_name = _person_output_base(target_person)
                save_path = output_dir / f"{base_name}.png"
                img.save(str(save_path), format="PNG")
                file_name = save_path.name
                remaining.remove(target_person)
                print(f"  已保存：{file_name}")
                result.total_saved += 1
                result.saved_files.append(file_name)
                captured_since_last_popup += 1
                consecutive_failures = 0
                last_capture_saved = True

                # Batch rest
                if rest_interval > 0 and rest_minutes > 0 and result.total_saved % rest_interval == 0:
                    print(f"  已累计成功截图 {result.total_saved} 张，休息 {rest_minutes} 分钟...")
                    pause_ctrl.sleep_with_pause(rest_minutes * 60)
                    print("  休息结束，继续抓取。")

            except Exception as e:
                print(f"  第 {row + 1} 行截图失败：{e}")
                consecutive_failures += 1
                if consecutive_failures >= stop_after_failures:
                    print(f"  连续 {consecutive_failures} 行失败，停止该姓名。")
                    break
            finally:
                try:
                    inp.close_window_alt_f4(detail_hwnd)
                except Exception:
                    pass
                pause_ctrl.sleep_ms_with_pause(250)
                windows.bring_to_front(main_hwnd)
                pause_ctrl.sleep_ms_with_pause(200)
                if 'img' in dir() and img is not None:
                    try:
                        img.close()
                    except Exception:
                        pass

            # 关闭详情窗口后检测弹窗（详情页内触发接口异常但弹窗遗留）
            triggered, error_count, captured_since_last_popup, last_error_time = _handle_error_popup_restart(
                result, f"关详情后 name={search_name};row={row + 1}", main_hwnd,
                error_log_path=error_log_path,
                error_count=error_count,
                captured_since_last_popup=captured_since_last_popup,
                last_error_time=last_error_time,
                deep_scan=False,
            )
            if triggered:
                return result
            popup_checked_recently = True

        print(f"  '{search_name}' 完成，本次截图 {result.total_saved} 张。")

    return result


def restart_doctor_and_enter_list(
    config: dict,
    list_entry: str,
    pause_ctrl: PauseController,
    *,
    restart_wait_s: int = DEFAULT_RESTART_WAIT_S,
) -> WindowInfo:
    """Stop app, wait, re-login, re-enter list."""
    app_path = resolve_doctor_app_path(config.get("appPath", ""))
    if not app_path:
        raise RuntimeError("未找到医师系统应用路径，无法自动重启。")
    error_popup.stop_doctor_application(app_path, post_wait_s=restart_wait_s)
    main_win = login_to_home(config, pause_ctrl)
    return enter_list_from_home(main_win, list_entry, config, pause_ctrl)


def invoke_capture_with_recovery(
    persons: list[Person],
    config: dict,
    list_entry: str,
    output_dir: Path,
    pause_ctrl: PauseController,
    main_win: WindowInfo,
    *,
    max_restarts: int = DEFAULT_MAX_RESTARTS,
    error_log_path: Optional[Path] = None,
) -> CaptureResult:
    """Capture with auto-restart on error popup."""
    total_result = CaptureResult()
    for attempt in range(max_restarts + 1):
        result = capture_name_series(
            main_win, persons, config, output_dir, pause_ctrl,
            error_log_path=error_log_path,
        )
        total_result.total_saved += result.total_saved
        total_result.saved_files.extend(result.saved_files)

        if not result.need_restart:
            return total_result

        if attempt >= max_restarts:
            print(f"已达到最大自动重启次数 {max_restarts}，停止。")
            return total_result

        print(f"第 {attempt + 1} 次自动重启：重启应用并恢复抓取...")
        try:
            main_win = restart_doctor_and_enter_list(config, list_entry, pause_ctrl)
        except Exception as e:
            print(f"重启失败：{e}")
            return total_result

    return total_result
