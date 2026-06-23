from __future__ import annotations

from pathlib import Path
from typing import Any

from openpyxl import Workbook
from openpyxl.styles import Font

_ROSTER_HEADERS = ["name", "certCode", "idCard"]
_ROSTER_LABELS = ["姓名", "执业证书编号", "身份证"]

_SHEET_LIANOU_HAS = "莲藕有机构端无"
_SHEET_EXPORT_HAS = "机构端有莲藕无"


def _write_roster_sheet(ws, records: list[dict[str, Any]]) -> None:
    header_font = Font(bold=True)
    for col_idx, label in enumerate(_ROSTER_LABELS, start=1):
        cell = ws.cell(row=1, column=col_idx, value=label)
        cell.font = header_font

    for row_idx, record in enumerate(records, start=2):
        for col_idx, key in enumerate(_ROSTER_HEADERS, start=1):
            value = record.get(key, "")
            if value is None:
                value = ""
            ws.cell(row=row_idx, column=col_idx, value=value)

    ws.freeze_panes = "A2"


def save_reconcile_report(
    *,
    lianou_only: list[dict[str, Any]],
    export_only: list[dict[str, Any]],
    output_path: Path,
) -> None:
    """写入单份核对报告 xlsx：两个 sheet 对应两类未匹配名单。"""
    output_path.parent.mkdir(parents=True, exist_ok=True)

    wb = Workbook()
    wb.remove(wb.active)

    ws_lianou = wb.create_sheet(title=_SHEET_LIANOU_HAS[:31])
    _write_roster_sheet(ws_lianou, lianou_only)

    ws_export = wb.create_sheet(title=_SHEET_EXPORT_HAS[:31])
    _write_roster_sheet(ws_export, export_only)

    wb.save(output_path)


def save_missing_roster(
    records: list[dict[str, Any]],
    output_path: Path,
    *,
    title: str = "未匹配名单",
) -> None:
    """单 sheet 名单（保留供特殊导出场景）。"""
    output_path.parent.mkdir(parents=True, exist_ok=True)

    wb = Workbook()
    ws = wb.active
    ws.title = title[:31]
    _write_roster_sheet(ws, records)
    wb.save(output_path)
