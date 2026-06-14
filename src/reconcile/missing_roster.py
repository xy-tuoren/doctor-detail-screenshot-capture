from __future__ import annotations

from pathlib import Path
from typing import Any

from openpyxl import Workbook
from openpyxl.styles import Font


def save_missing_roster(records: list[dict[str, Any]], output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)

    headers = ["name", "idCard"]
    labels = ["姓名", "身份证"]

    wb = Workbook()
    ws = wb.active
    ws.title = "缺失名单"

    header_font = Font(bold=True)
    for col_idx, label in enumerate(labels, start=1):
        cell = ws.cell(row=1, column=col_idx, value=label)
        cell.font = header_font

    for row_idx, record in enumerate(records, start=2):
        for col_idx, key in enumerate(headers, start=1):
            value = record.get(key, "")
            if value is None:
                value = ""
            ws.cell(row=row_idx, column=col_idx, value=value)

    ws.freeze_panes = "A2"
    wb.save(output_path)
