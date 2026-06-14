from __future__ import annotations

from typing import Any, Iterator

from .api_payload import IMAGE_API_FIELDS, REQUIRED_API_KEYS


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
        elif "AId" in entry:
            out.append(entry)
    return out


def iter_payloads(data: list[dict[str, Any]] | dict[str, Any]) -> Iterator[dict[str, Any]]:
    for payload in normalize_payloads(data):
        yield payload


def capture_meta(payload: dict[str, Any]) -> dict[str, Any]:
    return dict(payload.get("_capture") or {})


def strip_capture(payload: dict[str, Any]) -> dict[str, Any]:
    return {k: v for k, v in payload.items() if not k.startswith("_")}


def postable_body(payload: dict[str, Any], *, include_images: bool = True) -> dict[str, Any]:
    """Body for UpdateDoctorMedical: drop _capture and empty strings."""
    body: dict[str, Any] = {}
    for key, value in strip_capture(payload).items():
        if not include_images and key in IMAGE_API_FIELDS:
            continue
        if value == "" or value is None:
            continue
        body[key] = value
    return body


def has_writable_fields(payload: dict[str, Any], *, include_images: bool = False) -> bool:
    body = postable_body(payload, include_images=include_images)
    return len(body.keys() - REQUIRED_API_KEYS) > 0


def needs_institution_capture(payload: dict[str, Any]) -> bool:
    return "InstitutionUrl" in payload and not payload.get("InstitutionUrl")


def needs_nhc_capture(payload: dict[str, Any]) -> bool:
    return "HealthCommissionUrl" in payload and not payload.get("HealthCommissionUrl")


def iter_institution_capture_targets(data: list[dict[str, Any]] | dict[str, Any]) -> list[dict[str, Any]]:
    targets: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for payload in iter_payloads(data):
        if not needs_institution_capture(payload):
            continue
        meta = capture_meta(payload)
        name = str(payload.get("doctorName") or "")
        id_card = str(meta.get("idCard") or "")
        list_entry = str(meta.get("listEntry") or "Main")
        token = (name, id_card, list_entry)
        if token in seen:
            continue
        seen.add(token)
        targets.append({"name": name, "idCard": id_card, "listEntry": list_entry})
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
