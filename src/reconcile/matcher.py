from __future__ import annotations

import re
from typing import Any

from .field_mapping import MAIN_PRACTICE, MULTI_PRACTICE, map_export_values
from .api_payload import build_update_payload
from .update_field import parse_update_fields


def normalize_id_card(value: str | None) -> str:
    if not value:
        return ""
    return re.sub(r"\s+", "", str(value).strip().upper())


def normalize_name(value: str | None) -> str:
    if not value:
        return ""
    return str(value).strip()


def extract_id_card(record: dict[str, Any]) -> str:
    for key in ("idCard", "IdCard", "idcard", "doctorIdCard", "identityCard", "身份证"):
        if key in record and record[key]:
            return normalize_id_card(str(record[key]))
    return ""


def extract_doctor_name(record: dict[str, Any]) -> str:
    for key in ("doctorName", "name", "Name", "姓名"):
        if key in record and record[key]:
            return str(record[key]).strip()
    return ""


def extract_doctor_file_id(record: dict[str, Any]) -> str:
    for key in ("doctorFileId", "DoctorFileId", "doctor_file_id"):
        if key in record and record[key]:
            return str(record[key]).strip()
    return ""


def extract_cert_code(export_row: dict[str, Any]) -> str:
    for key in ("执业证书编码", "资格证书编码"):
        value = export_row.get(key)
        if value:
            return str(value).strip()
    return ""


def _pick_multi_row(rows: list[dict[str, Any]]) -> dict[str, Any]:
    if len(rows) == 1:
        return rows[0]

    def start_key(row: dict[str, Any]) -> str:
        return str(row.get("开始日期") or "")

    return max(rows, key=start_key)


def _build_name_to_id_cards(
    main_index: dict[str, dict[str, Any]],
    multi_index: dict[str, list[dict[str, Any]]],
) -> dict[str, set[str]]:
    name_map: dict[str, set[str]] = {}
    for id_card, row in main_index.items():
        name = normalize_name(row.get("姓名"))
        if name:
            name_map.setdefault(name, set()).add(id_card)
    for id_card, rows in multi_index.items():
        for row in rows:
            name = normalize_name(row.get("姓名"))
            if name:
                name_map.setdefault(name, set()).add(id_card)
    return name_map


def _supplement_id_card_from_export(
    doctor_name: str,
    name_to_id_cards: dict[str, set[str]],
) -> str:
    """When Lianou has no idCard, look up institution export by name (unique hit only)."""
    ids = name_to_id_cards.get(normalize_name(doctor_name), set())
    if len(ids) == 1:
        return next(iter(ids))
    return ""


def _resolve_export_row(
    id_card: str,
    main_index: dict[str, dict[str, Any]],
    multi_index: dict[str, list[dict[str, Any]]],
) -> tuple[dict[str, Any] | None, str | None]:
    main_row = main_index.get(id_card)
    multi_rows = multi_index.get(id_card, [])
    multi_row = _pick_multi_row(multi_rows) if multi_rows else None

    if main_row and multi_row:
        return main_row, MAIN_PRACTICE
    if main_row:
        return main_row, MAIN_PRACTICE
    if multi_row:
        return multi_row, MULTI_PRACTICE
    return None, None


def _dedupe_missing(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    seen: set[tuple[str, str]] = set()
    out: list[dict[str, str]] = []
    for row in rows:
        token = (row.get("name") or "", row.get("idCard") or "")
        if token in seen:
            continue
        seen.add(token)
        out.append(row)
    return out


def reconcile_doctors(
    doctors: list[dict[str, Any]],
    export_index: dict[str, Any],
) -> dict[str, Any]:
    """Reconcile Lianou doctors against institution exports.

    Match requires both idCard and doctorName to align with export 身份证号/姓名.
    When Lianou has no idCard, supplement from institution export by name (unique
    hit only) before matching or filling the missing roster.
    """
    main_index: dict[str, dict[str, Any]] = export_index.get("main", {})
    multi_index: dict[str, list[dict[str, Any]]] = export_index.get("multi", {})
    name_to_id_cards = _build_name_to_id_cards(main_index, multi_index)

    to_supplement: list[dict[str, Any]] = []
    missing_rows: list[dict[str, str]] = []
    missing_no_id_card = 0
    id_card_from_export = 0
    name_mismatch = 0

    for doctor in doctors:
        id_card = extract_id_card(doctor)
        doctor_name = extract_doctor_name(doctor)
        doctor_file_id = extract_doctor_file_id(doctor)
        missing_fields = parse_update_fields(doctor.get("updateField"))

        if not id_card:
            missing_no_id_card += 1
            id_card = _supplement_id_card_from_export(doctor_name, name_to_id_cards)
            if id_card:
                id_card_from_export += 1
            else:
                missing_rows.append({"name": doctor_name, "idCard": ""})
                continue

        export_row, practice_source = _resolve_export_row(id_card, main_index, multi_index)
        if export_row is None or practice_source is None:
            missing_rows.append({"name": doctor_name, "idCard": id_card})
            continue

        export_name = normalize_name(export_row.get("姓名"))
        if normalize_name(doctor_name) != export_name:
            name_mismatch += 1
            missing_rows.append({"name": doctor_name, "idCard": id_card})
            continue

        if not missing_fields:
            continue

        cert_code = extract_cert_code(export_row) or None
        payload = build_update_payload(
            doctor={**doctor, "doctorName": doctor_name, "doctorFileId": doctor_file_id},
            export_row=export_row,
            practice_source=practice_source,
            missing_fields=missing_fields,
            id_card=id_card,
            cert_code=cert_code,
        )
        to_supplement.append(payload)

    missing = _dedupe_missing(missing_rows)
    matched_keys = len({capture_key(p) for p in to_supplement})
    record_count = len(to_supplement)

    return {
        "summary": {
            "doctors": len(doctors),
            "matchedKeys": matched_keys,
            "matchedRecords": record_count,
            "missing": len(missing),
            "missingNoIdCard": missing_no_id_card,
            "idCardFromExport": id_card_from_export,
            "nameMismatch": name_mismatch,
        },
        "payloads": to_supplement,
        "missing": missing,
    }


def capture_key(payload: dict[str, Any]) -> str:
    meta = payload.get("_capture") or {}
    return f"{payload.get('doctorName')}|{meta.get('idCard', '')}"
