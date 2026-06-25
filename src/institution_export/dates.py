from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any


def format_cell_value(value: Any) -> str:
    if value is None:
        return ""
    if isinstance(value, datetime):
        return value.strftime("%Y-%m-%d")
    if isinstance(value, date):
        return value.strftime("%Y-%m-%d")
    text = str(value).strip()
    if not text:
        return ""
    converted = _excel_serial_to_date(text)
    if converted:
        return converted
    if len(text) >= 10 and text[4] == "-" and text[7] == "-":
        prefix = text[:10]
        try:
            datetime.strptime(prefix, "%Y-%m-%d")
            return prefix
        except ValueError:
            pass
    return text


def normalize_api_date(value: Any) -> str:
    """Normalize date strings in payloads (e.g. to_submit updateField) to YYYY-MM-DD."""
    return format_cell_value(value)


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
