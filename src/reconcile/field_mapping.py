from __future__ import annotations

from typing import Any

from src.institution_export.dates import format_cell_value

MAIN_PRACTICE = "main"
MULTI_PRACTICE = "multi"

# 主执业导出无结束日期，莲藕点名也不写入 to_submit
MAIN_PRACTICE_EXCLUDED_FIELDS = frozenset({"recordExpireDate"})

# 机构端导出无省/市/等级列时的业务默认值
DEFAULT_PRACTICE_PROVINCE = "广东省"
DEFAULT_PRACTICE_CITY = "广州市"
DEFAULT_HOSPITAL_LEVEL = 10  # 二级（见接口文档 hospitalLevel 枚举）

FIELD_LABELS: dict[str, str] = {
    "medicalInstitutionType": "医疗机构类型",
    "practiceProvince": "省份",
    "practiceCity": "城市",
    "hospital": "医院",
    "hospitalLevel": "医院等级",
    "departmentName": "科室名称",
    "recordDate": "备案日期",
    "recordExpireDate": "备案到期日期",
    "healthCommissionBase": "卫健委图片",
    "institutionBase": "机构端图片",
}

DATE_FIELDS = frozenset(
    {
        "recordDate",
        "recordExpireDate",
    }
)

_DEPARTMENT_EXPORT_KEY = "执业范围"


def map_department_name(export_row: dict[str, Any]) -> str:
    """departmentName ← 导出「执业范围」；列表分隔符逗号统一为分号。"""
    value = export_row.get(_DEPARTMENT_EXPORT_KEY)
    if value is None:
        return ""
    text = str(value).strip()
    if not text:
        return ""
    text = text.replace("，", ";").replace(",", ";")
    return text


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
    return values


def _cell(row: dict[str, Any], key: str) -> str:
    value = row.get(key)
    if value is None:
        return ""
    return format_cell_value(value)
