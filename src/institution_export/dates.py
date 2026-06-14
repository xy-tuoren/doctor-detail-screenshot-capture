from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any


def format_cell_value(value: Any) -> str:
    if value is None:
        return ""
    text = str(value).strip()
    if not text:
        return ""
    converted = _excel_serial_to_date(text)
    return converted or text


def _excel_serial_to_date(text: str) -> str | None:
    try:
        serial = float(text)
    except ValueError:
        return None
    if serial < 1 or serial > 100000:
        return None
    base = datetime(1899, 12, 30)
    dt = base + timedelta(days=serial)
    return dt.strftime("%Y-%m-%d")
