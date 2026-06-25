from __future__ import annotations

from typing import Any, Iterator

from .api_payload import IMAGE_API_FIELDS, REQUIRED_API_KEYS

# 提交体顶层身份/控制字段（不含 updateField 内的业务字段）
META_KEYS = frozenset(
    {
        "operationType",
        "aId",
        "AId",
        "doctorFileId",
        "DoctorFileId",
        "doctorName",
        "iDCard",
        "qualificationCertCode",
        "practicingCertCode",
    }
)

_SUPPLEMENT_KEYS = frozenset(
    {
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
    }
)


def normalize_payloads(data: list[dict[str, Any]] | dict[str, Any]) -> list[dict[str, Any]]:
    """Accept new list format or legacy keyed dict with records[]."""
    if isinstance(data, list):
        return data
    if not isinstance(data, dict):
        return []
    out: list[dict[str, Any]] = []
    for entry in data.values():
        if not isinstance(entry, dict):
            continue
        if "records" in entry:
            out.extend(entry.get("records") or [])
        elif "AId" in entry or "aId" in entry or "operationType" in entry:
            out.append(entry)
    return out


def iter_payloads(data: list[dict[str, Any]] | dict[str, Any]) -> Iterator[dict[str, Any]]:
    for payload in normalize_payloads(data):
        yield payload


def capture_meta(payload: dict[str, Any]) -> dict[str, Any]:
    return dict(payload.get("_capture") or {})


def strip_capture(payload: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in payload.items() if not k.startswith("_")}


def supplement_fields(payload: dict[str, Any]) -> dict[str, Any]:
    """读取待补/待提交业务字段（updateField 对象层）。"""
    nested = payload.get("updateField")
    if isinstance(nested, dict):
        return dict(nested)

    # 兼容旧版平铺在顶层的格式
    out: dict[str, Any] = {}
    for key, value in strip_capture(payload).items():
        if key in _SUPPLEMENT_KEYS:
            out[key] = value
    return out


def set_supplement_field(payload: dict[str, Any], field: str, value: Any) -> None:
    nested = payload.get("updateField")
    if not isinstance(nested, dict):
        nested = supplement_fields(payload)
        payload["updateField"] = nested
    nested[field] = value


def is_create_op(payload: dict[str, Any]) -> bool:
    return int(payload.get("operationType", 0)) == 0


def postable_body(payload: dict[str, Any], *, include_images: bool = True) -> dict[str, Any]:
    """展平为 UpdateDoctorMedical 请求体：顶层身份字段 + updateField 内业务字段。"""
    create = is_create_op(payload)
    body: dict[str, Any] = {}

    for key in (
        "operationType",
        "aId",
        "doctorFileId",
        "doctorName",
        "iDCard",
        "qualificationCertCode",
        "practicingCertCode",
    ):
        if key not in payload:
            continue
        value = payload[key]
        if value is None:
            value = ""
        body[key] = value

    for key, value in supplement_fields(payload).items():
        if not include_images and key in IMAGE_API_FIELDS:
            continue
        if (value == "" or value is None) and not create:
            continue
        if value is None:
            value = ""
        body[key] = value

    return body


def has_writable_fields(payload: dict[str, Any], *, include_images: bool = False) -> bool:
    if is_create_op(payload):
        return True
    body = postable_body(payload, include_images=include_images)
    return len(set(body.keys()) - META_KEYS) > 0


def needs_institution_capture(payload: dict[str, Any]) -> bool:
    fields = supplement_fields(payload)
    return "institutionBase" in fields and not fields.get("institutionBase")


def needs_nhc_capture(payload: dict[str, Any]) -> bool:
    fields = supplement_fields(payload)
    return "healthCommissionBase" in fields and not fields.get("healthCommissionBase")


def iter_institution_capture_targets(data: list[dict[str, Any]] | dict[str, Any]) -> list[dict[str, Any]]:
    targets: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for payload in iter_payloads(data):
        if not needs_institution_capture(payload):
            continue
        meta = capture_meta(payload)
        name = str(payload.get("doctorName") or "")
        cert_code = str(meta.get("certCode") or "")
        list_entry = str(meta.get("listEntry") or "Main")
        token = (name, cert_code, list_entry)
        if token in seen:
            continue
        seen.add(token)
        targets.append({"name": name, "certCode": cert_code, "listEntry": list_entry})
    return targets


def iter_nhc_capture_targets(data: list[dict[str, Any]] | dict[str, Any]) -> list[dict[str, Any]]:
    targets: list[dict[str, Any]] = []
    seen: set[tuple[str, str | None]] = set()
    for payload in iter_payloads(data):
        if not needs_nhc_capture(payload):
            continue
        meta = capture_meta(payload)
        name = str(payload.get("doctorName") or "")
        cert = meta.get("certCode")
        token = (name, cert)
        if token in seen:
            continue
        seen.add(token)
        targets.append({"name": name, "certCode": cert})
    return targets
