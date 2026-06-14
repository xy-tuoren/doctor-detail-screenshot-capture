"""Parse institution UI export .xls files (OOXML disguised as .xls)."""

from __future__ import annotations

import re
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Any

MAIN_HEADERS = frozenset({"审核日期"})
MULTI_HEADERS = frozenset({"开始日期", "结束日期"})


@dataclass(frozen=True)
class ExportFiles:
    main: Path | None
    multi: Path | None


def find_latest_exports(exports_dir: Path) -> ExportFiles:
    main_files = sorted(exports_dir.glob("主执业导出-*.xls"), key=lambda p: p.stat().st_mtime)
    multi_files = sorted(exports_dir.glob("多执业导出-*.xls"), key=lambda p: p.stat().st_mtime)
    main = main_files[-1] if main_files and main_files[-1].stat().st_size > 0 else None
    multi = multi_files[-1] if multi_files and multi_files[-1].stat().st_size > 0 else None
    return ExportFiles(main=main, multi=multi)


def parse_export_file(path: Path) -> list[dict[str, Any]]:
    if not path.exists() or path.stat().st_size == 0:
        return []

    with zipfile.ZipFile(path) as zf:
        shared_strings = _read_shared_strings(zf)
        rows = _read_sheet_rows(zf, shared_strings)

    if not rows:
        return []

    headers = [str(cell).strip() if cell is not None else "" for cell in rows[0]]
    records: list[dict[str, Any]] = []
    for row in rows[1:]:
        record: dict[str, Any] = {}
        for idx, header in enumerate(headers):
            if not header:
                continue
            value = row[idx] if idx < len(row) else None
            if value is None:
                continue
            record[header] = value
        if record:
            records.append(record)
    return records


def classify_export(headers: list[str]) -> str:
    header_set = set(headers)
    if MULTI_HEADERS.issubset(header_set):
        return "multi"
    if MAIN_HEADERS.intersection(header_set):
        return "main"
    raise ValueError(f"无法识别导出类型，表头: {headers}")


def build_export_index(exports_dir: Path) -> dict[str, Any]:
    files = find_latest_exports(exports_dir)
    main_records = parse_export_file(files.main) if files.main else []
    multi_records = parse_export_file(files.multi) if files.multi else []

    main_index: dict[str, dict[str, Any]] = {}
    for row in main_records:
        id_card = _normalize_id(row.get("身份证号"))
        if id_card:
            main_index[id_card] = row

    multi_index: dict[str, list[dict[str, Any]]] = {}
    for row in multi_records:
        id_card = _normalize_id(row.get("身份证号"))
        if not id_card:
            continue
        multi_index.setdefault(id_card, []).append(row)

    return {
        "sources": {
            "main": str(files.main) if files.main else None,
            "multi": str(files.multi) if files.multi else None,
        },
        "counts": {
            "main": len(main_records),
            "multi": len(multi_records),
        },
        "main": main_index,
        "multi": multi_index,
    }


def _normalize_id(value: Any) -> str:
    if value is None:
        return ""
    return re.sub(r"\s+", "", str(value).strip().upper())


def _read_shared_strings(zf: zipfile.ZipFile) -> list[str]:
    if "xl/sharedStrings.xml" not in zf.namelist():
        return []
    root = ET.fromstring(zf.read("xl/sharedStrings.xml"))
    ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    strings: list[str] = []
    for si in root.findall(f"{ns}si"):
        strings.append("".join(t.text or "" for t in si.iter(f"{ns}t")))
    return strings


def _read_sheet_rows(zf: zipfile.ZipFile, shared_strings: list[str]) -> list[list[Any]]:
    root = ET.fromstring(zf.read("xl/worksheets/sheet1.xml"))
    ns = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
    sheet_data = root.find(f"{ns}sheetData")
    if sheet_data is None:
        return []

    rows: list[list[Any]] = []
    for row in sheet_data.findall(f"{ns}row"):
        cells: dict[int, Any] = {}
        for cell in row.findall(f"{ns}c"):
            ref = cell.get("r", "")
            col_idx = _column_index(ref)
            value_node = cell.find(f"{ns}v")
            if value_node is None:
                continue
            cell_type = cell.get("t")
            if cell_type == "s":
                cells[col_idx] = shared_strings[int(value_node.text)]
            else:
                cells[col_idx] = value_node.text
        if not cells:
            rows.append([])
            continue
        max_col = max(cells)
        rows.append([cells.get(i) for i in range(max_col + 1)])
    return rows


def _column_index(cell_ref: str) -> int:
    letters = "".join(ch for ch in cell_ref if ch.isalpha())
    index = 0
    for ch in letters:
        index = index * 26 + (ord(ch.upper()) - ord("A") + 1)
    return index - 1
