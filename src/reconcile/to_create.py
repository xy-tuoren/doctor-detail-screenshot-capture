from __future__ import annotations

from typing import Any, Iterator

from .field_mapping import MAIN_PRACTICE, MAIN_PRACTICE_EXCLUDED_FIELDS, MULTI_PRACTICE, map_department_name, map_export_values

IMAGE_PLACEHOLDER_FIELDS = frozenset({"healthCommissionBase", "institutionBase"})

_CERT_KEYS = ("执业证书编码", "资格证书编码")


def _normalize_name(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _extract_cert_code(export_row: dict[str, Any]) -> str | None:
    for key in _CERT_KEYS:
        value = export_row.get(key)
        if value:
            return str(value).strip()
    return None


def _export_department(row: dict[str, Any]) -> str:
    return map_department_name(row)


def build_create_payload(
    *,
    export_row: dict[str, Any],
    practice_source: str,
    id_card: str,
) -> dict[str, Any]:
    """Build a sparse create-doctor body from an institution export row."""
    export_mapped = map_export_values(practice_source, export_row)
    cert_code = _extract_cert_code(export_row)
    doctor_name = _normalize_name(export_row.get("姓名"))

    payload: dict[str, Any] = {
        "doctorName": doctor_name,
        "iDCard": id_card,
        "medicalInstitutionType": 2 if practice_source == MULTI_PRACTICE else 1,
    }

    department = _export_department(export_row)
    if department:
        payload["departmentName"] = department

    date_fields = ("recordDate",)
    if practice_source == MULTI_PRACTICE:
        date_fields = ("recordDate", "recordExpireDate")
    for field in date_fields:
        value = export_mapped.get(field)
        if value:
            payload[field] = value

    for field in sorted(IMAGE_PLACEHOLDER_FIELDS):
        payload[field] = ""

    payload["_capture"] = {
        "idCard": id_card,
        "certCode": cert_code,
        "listEntry": "Multi" if practice_source == MULTI_PRACTICE else "Main",
    }
    payload["_export"] = {
        "practiceSource": practice_source,
        "row": dict(export_row),
    }
    return payload


def iter_create_payloads(data: list[dict[str, Any]]) -> Iterator[dict[str, Any]]:
    yield from data
