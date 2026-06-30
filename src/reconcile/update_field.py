from __future__ import annotations

import re

from .field_mapping import FIELD_LABELS

# docMedicalList[].updateField 可能出现的全部规范字段名（接口字段）
CANONICAL_FIELDS = frozenset(
    {
        "medicalInstitutionType",
        "practiceProvince",
        "practiceCity",
        "hospital",
        "hospitalLevel",
        "professionalList",
        "recordDate",
        "recordExpireDate",
        "healthCommissionBase",
        "institutionBase",
    }
)

_LABEL_TO_FIELD = {label: field for field, label in FIELD_LABELS.items()}
_FIELD_NAMES = set(FIELD_LABELS) | set(CANONICAL_FIELDS)

# 兼容旧 updateField 命名；身份证仅用于本地对账匹配，不参与写回
FIELD_ALIASES: dict[str, str] = {
    "healthCommissionUrl": "healthCommissionBase",
    "institutionUrl": "institutionBase",
    "healthCommissionExpireDate": "recordExpireDate",
    "institutionExpireDate": "recordExpireDate",
}

IGNORED_UPDATE_FIELDS = frozenset({"idCard", "iDCard", "身份证号码"})


def parse_update_fields(raw: str | list[str] | None) -> set[str]:
    """Parse updateField into canonical API field names."""
    if raw is None:
        return set()
    if isinstance(raw, list):
        parts = [str(item).strip() for item in raw if str(item).strip()]
    else:
        text = str(raw).strip()
        if not text:
            return set()
        parts = re.split(r"[,，;；\s]+", text)

    fields: set[str] = set()
    for part in parts:
        if part in IGNORED_UPDATE_FIELDS:
            continue
        if part in _FIELD_NAMES:
            fields.add(part)
            continue
        aliased = FIELD_ALIASES.get(part)
        if aliased:
            fields.add(aliased)
            continue
        mapped = _LABEL_TO_FIELD.get(part)
        if mapped:
            fields.add(mapped)
    return fields
