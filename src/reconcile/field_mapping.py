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
    "professionalList": "执业范围",
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

_PROFESSIONAL_EXPORT_KEY = "执业范围"
_CATEGORY_EXPORT_KEY = "医师类别"

# 机构端「医师类别」→ 莲藕 professionalType（1=临床 2=中医 3=口腔 4=公共卫生）
# 「中西医结合」按业务约定归入中医(2)
PROFESSIONAL_TYPE_MAP: dict[str, int] = {
    "临床": 1,
    "中医": 2,
    "中西医结合": 2,
    "口腔": 3,
    "公共卫生": 4,
}


def _professional_type(export_row: dict[str, Any]) -> int:
    raw = export_row.get(_CATEGORY_EXPORT_KEY)
    if raw is None:
        return 0
    key = str(raw).strip()
    if not key:
        return 0
    # 容错：去掉「医师」后缀再匹配，如「临床医师」→「临床」
    if key in PROFESSIONAL_TYPE_MAP:
        return PROFESSIONAL_TYPE_MAP[key]
    for needle, code in PROFESSIONAL_TYPE_MAP.items():
        if needle in key:
            return code
    return 0


def _split_professional_names(value: Any) -> list[str]:
    if value is None:
        return []
    text = str(value).strip()
    if not text:
        return []
    for sep in (";", "；", ",", "，", "、"):
        text = text.replace(sep, "\n")
    return [part.strip() for part in text.splitlines() if part.strip()]


def map_professional_list(export_row: dict[str, Any]) -> list[dict[str, Any]]:
    """professionalList ← 导出「执业范围」(可多项) + 「医师类别」→ professionalType。

    返回 [{"professionalType": int, "professionalName": str}, ...]；
    无执业范围数据时返回空列表。
    """
    names = _split_professional_names(export_row.get(_PROFESSIONAL_EXPORT_KEY))
    if not names:
        return []
    professional_type = _professional_type(export_row)
    return [{"professionalType": professional_type, "professionalName": name} for name in names]


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
