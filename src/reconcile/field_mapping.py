from __future__ import annotations

from typing import Any

from src.institution_export.dates import format_cell_value

MAIN_PRACTICE = "main"
MULTI_PRACTICE = "multi"

FIELD_LABELS: dict[str, str] = {
    "recordDate": "备案日期",
    "recordExpireDate": "备案到期日期",
    "healthCommissionExpireDate": "卫健委到期日期",
    "institutionExpireDate": "机构端到期日期",
    "healthCommissionUrl": "卫健委图片",
    "institutionUrl": "机构端图片",
}

DATE_FIELDS = frozenset(
    {
        "recordDate",
        "recordExpireDate",
        "healthCommissionExpireDate",
        "institutionExpireDate",
    }
)


def map_export_values(practice_source: str, export_row: dict[str, Any]) -> dict[str, str]:
    """Map institution export columns to Lianou API field values."""
    values: dict[str, str] = {}
    if practice_source == MAIN_PRACTICE:
        audit_date = _cell(export_row, "审核日期")
        if audit_date:
            values["recordDate"] = audit_date
    elif practice_source == MULTI_PRACTICE:
        start_date = _cell(export_row, "开始日期")
        end_date = _cell(export_row, "结束日期")
        if start_date:
            values["recordDate"] = start_date
        if end_date:
            values["recordExpireDate"] = end_date
            values["healthCommissionExpireDate"] = end_date
            values["institutionExpireDate"] = end_date
    return values


def _cell(row: dict[str, Any], key: str) -> str:
    value = row.get(key)
    if value is None:
        return ""
    return format_cell_value(value)
