from __future__ import annotations

import re
from collections import Counter
from typing import Any

from src.institution_export import extract_cert_code as export_cert_code
from src.institution_export import normalize_cert_code

from .field_mapping import MAIN_PRACTICE, MAIN_PRACTICE_EXCLUDED_FIELDS, MULTI_PRACTICE
from .submit_payload import LIANOU_HOSPITAL, build_create_op, build_update_op, map_missing_update_values
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
    for key in ("idCard", "iDCard", "IdCard", "idcard", "doctorIdCard", "identityCard", "身份证"):
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


def extract_practicing_cert(record: dict[str, Any]) -> str:
    for key in ("practicingCertCode", "PracticingCertCode", "practicing_cert_code", "执业证书编码"):
        value = record.get(key)
        if value:
            return normalize_cert_code(value)
    return ""


def _export_name(row: dict[str, Any]) -> str:
    return normalize_name(row.get("姓名") or row.get("doctorName"))


def _export_id_card(row: dict[str, Any]) -> str:
    return normalize_id_card(row.get("身份证号") or row.get("iDCard") or row.get("idCard"))


def _display_id_card(api_id_card: str, export_row: dict[str, Any] | None) -> str:
    """核对名单展示用：优先莲藕 API 身份证，空则用机构端导出补充。"""
    if api_id_card:
        return api_id_card
    if export_row:
        return _export_id_card(export_row)
    return ""


def _find_export_row_by_cert(
    cert: str,
    main_index: dict[str, dict[str, Any]],
    multi_index: dict[str, list[dict[str, Any]]],
) -> dict[str, Any] | None:
    """仅按执业证书编码取导出行（不做姓名校验），供展示字段补充。"""
    row = main_index.get(cert)
    if row is not None:
        return row
    multi_rows = multi_index.get(cert, [])
    if multi_rows:
        return _pick_multi_row(multi_rows)
    return None


def _build_lianou_id_by_cert(doctors: list[dict[str, Any]]) -> dict[str, str]:
    out: dict[str, str] = {}
    for doctor in doctors:
        cert = extract_practicing_cert(doctor)
        if not cert:
            continue
        id_card = extract_id_card(doctor)
        if id_card and cert not in out:
            out[cert] = id_card
    return out


def _pick_multi_row(rows: list[dict[str, Any]]) -> dict[str, Any]:
    if len(rows) == 1:
        return rows[0]

    def start_key(row: dict[str, Any]) -> str:
        return str(row.get("开始日期") or "")

    return max(rows, key=start_key)


def _resolve_export_row(
    cert: str,
    name: str,
    main_index: dict[str, dict[str, Any]],
    multi_index: dict[str, list[dict[str, Any]]],
) -> tuple[dict[str, Any] | None, str | None]:
    """按执业证书编码定位导出行，再用姓名做第二字段校验。"""
    main_row = main_index.get(cert)
    if main_row is not None and _export_name(main_row) == name:
        return main_row, MAIN_PRACTICE

    multi_rows = multi_index.get(cert, [])
    if multi_rows:
        multi_row = _pick_multi_row(multi_rows)
        if _export_name(multi_row) == name:
            return multi_row, MULTI_PRACTICE
    return None, None


def _build_ops_for_doctor(
    *,
    doctor: dict[str, Any],
    doctor_name: str,
    doctor_file_id: str,
    id_card: str,
    cert: str,
    export_row: dict[str, Any],
    practice_source: str,
) -> tuple[list[dict[str, Any]], int, int, Counter]:
    normalized_doctor = {
        **doctor,
        "doctorName": doctor_name,
        "doctorFileId": doctor_file_id,
    }
    doc_list = doctor.get("docMedicalList") or []
    has_lianou = any(
        normalize_name(item.get("hospital")) == LIANOU_HOSPITAL for item in doc_list
    )

    ops: list[dict[str, Any]] = []
    create_count = 0
    update_count = 0
    dropped_fields: Counter = Counter()

    if not has_lianou:
        ops.append(
            build_create_op(
                doctor=normalized_doctor,
                export_row=export_row,
                practice_source=practice_source,
                id_card=id_card,
                cert_code=cert,
            )
        )
        create_count += 1

    for item in doc_list:
        # 仅对「莲藕健康医院」生成 update 操作体；其它医院即使点名缺失字段也不写入 to_submit
        if normalize_name(item.get("hospital")) != LIANOU_HOSPITAL:
            continue
        missing = parse_update_fields(item.get("updateField"))
        if practice_source == MAIN_PRACTICE:
            missing -= MAIN_PRACTICE_EXCLUDED_FIELDS
        if not missing:
            continue
        mapped = map_missing_update_values(
            missing_fields=missing,
            export_row=export_row,
            practice_source=practice_source,
        )
        for field in missing:
            if field not in mapped:
                dropped_fields[field] += 1
        if not mapped:
            continue
        ops.append(
            build_update_op(
                doctor=normalized_doctor,
                export_row=export_row,
                practice_source=practice_source,
                missing_fields=missing,
                id_card=id_card,
                cert_code=cert,
                a_id=item.get("aId"),
                hospital=normalize_name(item.get("hospital")),
            )
        )
        update_count += 1

    return ops, create_count, update_count, dropped_fields


def _dedupe_roster(rows: list[dict[str, str]]) -> list[dict[str, str]]:
    seen: set[tuple[str, str, str]] = set()
    out: list[dict[str, str]] = []
    for row in rows:
        token = (row.get("name") or "", row.get("certCode") or "", row.get("idCard") or "")
        if token in seen:
            continue
        seen.add(token)
        out.append(row)
    return out


def reconcile_doctors(
    doctors: list[dict[str, Any]],
    export_index: dict[str, Any],
) -> dict[str, Any]:
    """以执业证书编号 + 姓名核对莲藕与机构端导出。

    - 莲藕无 practicingCertCode、导出无该证书号、或姓名不一致 → 莲藕未匹配名单。
    - 双匹配成功 → 按 docMedicalList 生成 CREATE/UPDATE 操作。
    - 机构端导出有、莲藕无对应证书号 → 机构端未匹配名单。
    """
    main_index: dict[str, dict[str, Any]] = export_index.get("main", {})
    multi_index: dict[str, list[dict[str, Any]]] = export_index.get("multi", {})

    to_submit: list[dict[str, Any]] = []
    lianou_only: list[dict[str, str]] = []

    matched_certs: set[str] = set()
    lianou_certs: set[str] = set()

    missing_no_cert = 0
    missing_not_in_export = 0
    name_mismatch = 0
    matched_doctors = 0
    create_ops = 0
    update_ops = 0
    dropped_fields: Counter = Counter()

    for doctor in doctors:
        cert = extract_practicing_cert(doctor)
        doctor_name = extract_doctor_name(doctor)
        doctor_file_id = extract_doctor_file_id(doctor)
        id_card = extract_id_card(doctor)

        if not cert:
            missing_no_cert += 1
            lianou_only.append(
                {
                    "name": doctor_name,
                    "certCode": "",
                    "idCard": _display_id_card(id_card, None),
                }
            )
            continue

        lianou_certs.add(cert)

        export_row, practice_source = _resolve_export_row(
            cert, normalize_name(doctor_name), main_index, multi_index
        )
        if export_row is None or practice_source is None:
            if cert in main_index or cert in multi_index:
                name_mismatch += 1
            else:
                missing_not_in_export += 1
            export_row_for_id = _find_export_row_by_cert(cert, main_index, multi_index)
            lianou_only.append(
                {
                    "name": doctor_name,
                    "certCode": cert,
                    "idCard": _display_id_card(id_card, export_row_for_id),
                }
            )
            continue

        matched_certs.add(cert)
        matched_doctors += 1

        # export_row 已通过 姓名+执业证书编号 双字段匹配；API 无身份证时用该导出行补充
        submit_id_card = _display_id_card(id_card, export_row)

        ops, c_count, u_count, doc_dropped = _build_ops_for_doctor(
            doctor=doctor,
            doctor_name=doctor_name,
            doctor_file_id=doctor_file_id,
            id_card=submit_id_card,
            cert=cert,
            export_row=export_row,
            practice_source=practice_source,
        )
        to_submit.extend(ops)
        create_ops += c_count
        update_ops += u_count
        dropped_fields.update(doc_dropped)

    lianou_id_by_cert = _build_lianou_id_by_cert(doctors)
    export_only = _collect_export_only(
        matched_certs, main_index, multi_index, lianou_id_by_cert=lianou_id_by_cert
    )

    lianou_only = _dedupe_roster(lianou_only)

    return {
        "summary": {
            "doctors": len(doctors),
            "matchedDoctors": matched_doctors,
            "createOps": create_ops,
            "updateOps": update_ops,
            "submitOps": len(to_submit),
            "lianouOnly": len(lianou_only),
            "missingNoCert": missing_no_cert,
            "missingNotInExport": missing_not_in_export,
            "nameMismatch": name_mismatch,
            "exportOnly": len(export_only),
            "droppedFields": dict(dropped_fields),
        },
        "toSubmit": to_submit,
        "exportOnly": export_only,
        "lianouOnly": lianou_only,
    }


def _collect_export_only(
    matched_certs: set[str],
    main_index: dict[str, dict[str, Any]],
    multi_index: dict[str, list[dict[str, Any]]],
    *,
    lianou_id_by_cert: dict[str, str] | None = None,
) -> list[dict[str, str]]:
    api_ids = lianou_id_by_cert or {}
    rows: list[dict[str, str]] = []
    export_certs = set(main_index.keys()) | set(multi_index.keys())
    for cert in sorted(export_certs - matched_certs):
        row = main_index.get(cert)
        if row is None:
            multi_rows = multi_index.get(cert, [])
            row = _pick_multi_row(multi_rows) if multi_rows else None
        if row is None:
            continue
        rows.append(
            {
                "name": _export_name(row),
                "certCode": cert,
                "idCard": _display_id_card(api_ids.get(cert, ""), row),
            }
        )
    return _dedupe_roster(rows)


def capture_key(payload: dict[str, Any]) -> str:
    meta = payload.get("_capture") or {}
    return f"{payload.get('doctorName')}|{meta.get('certCode', '')}"
