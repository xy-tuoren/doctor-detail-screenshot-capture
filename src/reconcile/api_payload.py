from __future__ import annotations

from typing import Any

from .field_mapping import map_export_values

# updateField 可点名的字段 → UpdateDoctorMedical 请求体属性名
CAMEL_TO_API: dict[str, str] = {
    "recordDate": "RecordDate",
    "recordExpireDate": "RecordExpireDate",
    "healthCommissionExpireDate": "HealthCommissionExpireDate",
    "healthCommissionUrl": "HealthCommissionUrl",
    "institutionExpireDate": "InstitutionExpireDate",
    "institutionUrl": "InstitutionUrl",
}

REQUIRED_API_KEYS = frozenset({"AId", "DoctorFileId", "doctorName"})
IMAGE_API_FIELDS = frozenset({"HealthCommissionUrl", "InstitutionUrl"})


def _str(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def build_update_payload(
    *,
    doctor: dict[str, Any],
    export_row: dict[str, Any],
    practice_source: str,
    missing_fields: set[str],
    id_card: str,
    cert_code: str | None,
) -> dict[str, Any]:
    """Build sparse UpdateDoctorMedical body: required ids + only fields to supplement."""
    export_mapped = map_export_values(practice_source, export_row)

    payload: dict[str, Any] = {
        "AId": doctor.get("aId"),
        "DoctorFileId": _str(doctor.get("doctorFileId")),
        "doctorName": _str(doctor.get("doctorName")),
    }

    for field in sorted(missing_fields):
        api_key = CAMEL_TO_API.get(field)
        if not api_key:
            continue
        if field.endswith("Url"):
            # 占位，供后续截图脚本填入 base64
            payload[api_key] = ""
            continue
        value = export_mapped.get(field)
        if value:
            payload[api_key] = value

    payload["_capture"] = {
        "idCard": id_card,
        "certCode": cert_code,
        "listEntry": "Multi" if practice_source == "multi" else "Main",
    }
    return payload
