from __future__ import annotations

from datetime import datetime
from pathlib import Path

from openpyxl import Workbook
from openpyxl.utils import get_column_letter


def default_output_path(cfg: dict, label: str) -> Path:
    root = Path(__file__).resolve().parent.parent.parent
    out_dir = root / str(cfg.get("outputDir", "exports/reg-api"))
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    return out_dir / f"{label}导出-{stamp}.xlsx"


def save_reg_xlsx(records: list[dict[str, str]], output_path: Path) -> None:
    save_reg_workbook({"Sheet1": records}, output_path)


def save_reg_workbook(sheets: dict[str, list[dict[str, str]]], output_path: Path) -> int:
    wb = Workbook()
    wb.remove(wb.active)
    total = 0
    for sheet_name, rows in sheets.items():
        ws = wb.create_sheet(title=sheet_name[:31])
        if not rows:
            continue
        headers = list(rows[0].keys())
        ws.append(headers)
        for row in rows:
            ws.append([row.get(h, "") for h in headers])
            total += 1
        for idx, _ in enumerate(headers, start=1):
            ws.column_dimensions[get_column_letter(idx)].width = 18
    output_path.parent.mkdir(parents=True, exist_ok=True)
    wb.save(output_path)
    return total
