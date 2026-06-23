from __future__ import annotations

import re
import sys
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from typing import Any

from .constants import NS_DOCTOR_UNIT
from .session import MinkeSession
from .soap import SoapClient, extract_error_message

MAIN_UI_HEADERS: tuple[str, ...] = (
    "姓名",
    "身份证号",
    "性别",
    "年龄",
    "医师类别",
    "医师级别",
    "执业范围",
    "资格证书编码",
    "所在科室",
    "执业证书编码",
    "任职资格",
    "医师账户状态",
    "是否修改过信息",
    "审核日期",
    "医通办注册",
)

_DETAIL_FIELDS = (
    "IDCard",
    "WorkLicenceCode",
    "CPETLicenceCode",
    "PostCpetName",
    "WorkCpetName",
)

_print_lock = threading.Lock()
_client_local = threading.local()


def _detail_client(cfg: dict[str, Any]) -> SoapClient:
    client = getattr(_client_local, "client", None)
    if client is None:
        timeout = int(cfg.get("requestTimeoutSeconds", 120))
        client = SoapClient(
            str(cfg["docUnitServiceUrl"]),
            NS_DOCTOR_UNIT,
            timeout=timeout,
            reuse_connection=bool(cfg.get("detailReuseConnection", True)),
        )
        _client_local.client = client
    return client


def _first_tag(soap_xml: str, tag: str) -> str:
    pattern = re.compile(rf"<{re.escape(tag)}>([^<]*)</", re.I)
    match = pattern.search(soap_xml)
    if not match:
        return ""
    return match.group(1).strip()


def _parse_reg_detail(soap_xml: str) -> dict[str, str]:
    return {field: _first_tag(soap_xml, field) for field in _DETAIL_FIELDS}


def _parse_iso_datetime(value: str) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("+08:00", ""))
    except ValueError:
        return None


def datetime_to_excel_serial(value: datetime) -> float:
    base = datetime(1899, 12, 30)
    return (value - base).total_seconds() / 86400


def format_audit_date(value: str) -> str | float:
    dt = _parse_iso_datetime(value)
    if dt is None:
        return ""
    return datetime_to_excel_serial(dt)


def fetch_reg_detail_for_unit(
    client: SoapClient,
    session: MinkeSession,
    doctor_gid: str,
    register_gid: str,
) -> dict[str, str]:
    resp = client.call_operation(
        "GetRegDetailForUnit",
        {
            "aDoctorId": doctor_gid,
            "aRegisterID": register_gid,
            "aIdCard": "",
            "aPhoto": "false",
        },
        header_xml=session.doctor_header(),
    )
    err = extract_error_message(resp)
    if err:
        raise RuntimeError(f"GetRegDetailForUnit error: {err}")
    return _parse_reg_detail(resp)


def _fetch_one_with_retry(
    client: SoapClient,
    session: MinkeSession,
    doctor_gid: str,
    register_gid: str,
    retries: int,
) -> dict[str, str]:
    last_exc: Exception | None = None
    for _ in range(retries + 1):
        try:
            return fetch_reg_detail_for_unit(client, session, doctor_gid, register_gid)
        except Exception as exc:
            last_exc = exc
    if last_exc is not None:
        raise last_exc
    return {field: "" for field in _DETAIL_FIELDS}


def enrich_main_rows(
    cfg: dict[str, Any],
    session: MinkeSession,
    rows: list[dict[str, str]],
    *,
    progress: bool = True,
) -> list[dict[str, str]]:
    if not rows:
        return rows

    workers = max(1, int(cfg.get("detailFetchWorkers", 48)))
    retries = max(0, int(cfg.get("detailFetchRetries", 2)))
    total = len(rows)
    done = 0
    failed = 0
    progress_step = max(50, min(200, total // 20 or 50))

    def task(index: int, row: dict[str, str]) -> tuple[int, dict[str, str]]:
        detail = _fetch_one_with_retry(
            _detail_client(cfg),
            session,
            str(row.get("Doctor_GID", "")),
            str(row.get("Doctor_RegisterGID", "")),
            retries,
        )
        merged = dict(row)
        merged.update(detail)
        return index, merged

    enriched: list[dict[str, str] | None] = [None] * total
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {
            pool.submit(task, idx, row): idx for idx, row in enumerate(rows)
        }
        for future in as_completed(futures):
            idx = futures[future]
            try:
                _, merged = future.result()
                enriched[idx] = merged
            except Exception:
                failed += 1
                merged = dict(rows[idx])
                for field in _DETAIL_FIELDS:
                    merged.setdefault(field, "")
                enriched[idx] = merged
            done += 1
            if progress and (done == total or done % progress_step == 0):
                with _print_lock:
                    print(
                        f"  证号补全进度 {done}/{total}"
                        + (f"，失败 {failed}" if failed else ""),
                        file=sys.stderr,
                    )

    return [row for row in enriched if row is not None]


def format_main_row_ui(row: dict[str, str]) -> dict[str, str]:
    post_name = row.get("PostCpetName", "") or row.get("WorkCpetName", "")
    audit_raw = row.get("LastApprovalTime", "") or row.get("Add_UpdateApproval_Time", "")
    audit_value = format_audit_date(audit_raw)
    return {
        "姓名": row.get("Doctor_Name", ""),
        "身份证号": row.get("IDCard", ""),
        "性别": row.get("Sex", ""),
        "年龄": str(row.get("Age", "")),
        "医师类别": row.get("Doctor_SortName", ""),
        "医师级别": row.get("Doctor_LevelName", ""),
        "执业范围": row.get("Subject_Name", ""),
        "资格证书编码": row.get("CPETLicenceCode", ""),
        "所在科室": "",
        "执业证书编码": row.get("WorkLicenceCode", ""),
        "任职资格": post_name,
        "医师账户状态": row.get("Account_ActiveName", ""),
        "是否修改过信息": row.get("IfModified", ""),
        "审核日期": audit_value,
        "医通办注册": row.get("YtbRegStatus", ""),
    }
