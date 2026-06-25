"""构建提交给 UpdateDoctorMedical 的操作体（含 operationType）。

中间 JSON 结构：
- 顶层：operationType、aId（更新时）、身份五件套
- updateField：本次实际要提交/待补的业务字段（键值对，非查询接口原始数组）
- _capture / _op：本地辅助，不提交接口
"""

from __future__ import annotations

from typing import Any

from src.institution_export.dates import normalize_api_date

from .field_mapping import (
    DEFAULT_HOSPITAL_LEVEL,
    DEFAULT_PRACTICE_CITY,
    DEFAULT_PRACTICE_PROVINCE,
    MAIN_PRACTICE,
    MAIN_PRACTICE_EXCLUDED_FIELDS,
    MULTI_PRACTICE,
    map_department_name,
    map_export_values,
)

LIANOU_HOSPITAL = "莲藕健康医院"

OPERATION_ADD = 0
OPERATION_UPDATE = 1

IMAGE_FIELDS = ("healthCommissionBase", "institutionBase")

_CREATE_OPTIONAL_FIELDS = (
    "medicalInstitutionType",
    "practiceProvince",
    "practiceCity",
    "hospital",
    "hospitalLevel",
    "departmentName",
    "recordDate",
    "recordExpireDate",
    "healthCommissionBase",
    "institutionBase",
)


def _str(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _practice_type(practice_source: str) -> int:
    return 2 if practice_source == MULTI_PRACTICE else 1


def _export_department(row: dict[str, Any]) -> str:
    return map_department_name(row)


def _required_identity(doctor: dict[str, Any], cert_code: str, id_card: str) -> dict[str, Any]:
    return {
        "doctorFileId": _str(doctor.get("doctorFileId")),
        "doctorName": _str(doctor.get("doctorName")),
        "iDCard": id_card,
        "qualificationCertCode": _str(doctor.get("qualificationCertCode")),
        "practicingCertCode": cert_code,
    }


def _capture_meta(id_card: str, cert_code: str, practice_source: str, hospital: str) -> dict[str, Any]:
    return {
        "idCard": id_card,
        "certCode": cert_code,
        "listEntry": "Multi" if practice_source == MULTI_PRACTICE else "Main",
        "hospital": hospital,
    }


def _map_missing_to_values(
    *,
    missing_fields: set[str],
    export_row: dict[str, Any],
    practice_source: str,
) -> dict[str, Any]:
    """将 API 点名的缺失字段映射为待提交键值（仅含本次会写入的项）。"""
    export_mapped = map_export_values(practice_source, export_row)
    department = _export_department(export_row)
    values: dict[str, Any] = {}

    for field in sorted(missing_fields):
        if practice_source == MAIN_PRACTICE and field in MAIN_PRACTICE_EXCLUDED_FIELDS:
            continue
        if field == "medicalInstitutionType":
            values["medicalInstitutionType"] = _practice_type(practice_source)
        elif field == "departmentName":
            if department:
                values["departmentName"] = department
        elif field == "practiceProvince":
            values["practiceProvince"] = DEFAULT_PRACTICE_PROVINCE
        elif field == "practiceCity":
            values["practiceCity"] = DEFAULT_PRACTICE_CITY
        elif field == "hospitalLevel":
            values["hospitalLevel"] = DEFAULT_HOSPITAL_LEVEL
        elif field in ("recordDate", "recordExpireDate"):
            value = export_mapped.get(field)
            if value:
                values[field] = normalize_api_date(value)
        elif field in IMAGE_FIELDS:
            values[field] = ""
        # hospital：导出无数据，忽略

    return values


map_missing_update_values = _map_missing_to_values


def _apply_export_dates(
    target: dict[str, Any],
    export_mapped: dict[str, str],
    practice_source: str,
) -> None:
    """仅当机构端导出有对应日期时才写入 updateField。"""
    record_date = normalize_api_date(export_mapped.get("recordDate", ""))
    if record_date:
        target["recordDate"] = record_date
    if practice_source == MULTI_PRACTICE:
        expire = normalize_api_date(export_mapped.get("recordExpireDate", ""))
        if expire:
            target["recordExpireDate"] = expire


def build_create_op(
    *,
    doctor: dict[str, Any],
    export_row: dict[str, Any],
    practice_source: str,
    id_card: str,
    cert_code: str,
    lianou_hospital: str = LIANOU_HOSPITAL,
) -> dict[str, Any]:
    """缺少莲藕健康医院 → 新增一条本院记录（operationType=0）。"""
    export_mapped = map_export_values(practice_source, export_row)
    department = _export_department(export_row)

    update_field: dict[str, Any] = {
        "medicalInstitutionType": _practice_type(practice_source),
        "practiceProvince": DEFAULT_PRACTICE_PROVINCE,
        "practiceCity": DEFAULT_PRACTICE_CITY,
        "hospitalLevel": DEFAULT_HOSPITAL_LEVEL,
        "hospital": lianou_hospital,
        "departmentName": department,
        "healthCommissionBase": "",
        "institutionBase": "",
    }
    _apply_export_dates(update_field, export_mapped, practice_source)

    payload: dict[str, Any] = {"operationType": OPERATION_ADD}
    payload.update(_required_identity(doctor, cert_code, id_card))
    payload["updateField"] = update_field
    payload["_capture"] = _capture_meta(id_card, cert_code, practice_source, lianou_hospital)
    payload["_op"] = "create"
    return payload


def build_update_op(
    *,
    doctor: dict[str, Any],
    export_row: dict[str, Any],
    practice_source: str,
    missing_fields: set[str],
    id_card: str,
    cert_code: str,
    a_id: Any,
    hospital: str,
) -> dict[str, Any]:
    """已存在的医院 → 按 updateField 点名映射为待提交键值（operationType=1）。"""
    payload: dict[str, Any] = {"operationType": OPERATION_UPDATE, "aId": a_id}
    payload.update(_required_identity(doctor, cert_code, id_card))
    payload["updateField"] = _map_missing_to_values(
        missing_fields=missing_fields,
        export_row=export_row,
        practice_source=practice_source,
    )
    payload["_capture"] = _capture_meta(id_card, cert_code, practice_source, hospital)
    payload["_op"] = "update"
    return payload
