from __future__ import annotations

import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .constants import MAIN_ROW_TAGS, MULTI_ROW_TAGS, NS_DOCTOR_UNIT
from .dataset import parse_dataset_rows
from .session import MinkeSession
from .soap import SoapClient, extract_error_message

_SLIM_KEY_THRESHOLD = 30
_AUDIT_MARKERS = ("LastApprovalTime", "IfModified", "Add_UpdateApproval_Time")
_DEFAULT_STALE_MD5 = "b89e27ea88d737585917bfce57a85201"


def _cache_path(cfg: dict[str, Any]) -> Path:
    raw = str(cfg.get("mainListMd5CachePath", "workspace/cache/main_list_md5.json"))
    path = Path(raw)
    if not path.is_absolute():
        path = Path.cwd() / path
    return path


def _load_cached_md5(cfg: dict[str, Any], search_type: int) -> str:
    path = _cache_path(cfg)
    if not path.is_file():
        return ""
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError):
        return ""
    entry = data.get(str(search_type), {})
    return str(entry.get("md5", "")).strip()


def _save_cached_md5(cfg: dict[str, Any], search_type: int, md5_str: str) -> None:
    if not md5_str:
        return
    path = _cache_path(cfg)
    path.parent.mkdir(parents=True, exist_ok=True)
    data: dict[str, Any] = {}
    if path.is_file():
        try:
            data = json.loads(path.read_text(encoding="utf-8-sig"))
        except (OSError, json.JSONDecodeError):
            data = {}
    data[str(search_type)] = {
        "md5": md5_str,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
    }
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def _audit_count(rows: list[dict[str, str]]) -> int:
    return sum(1 for row in rows if str(row.get("LastApprovalTime", "")).strip())


def _is_full_main_list(rows: list[dict[str, str]]) -> bool:
    if not rows:
        return False
    if len(rows[0]) >= _SLIM_KEY_THRESHOLD:
        return True
    return any(marker in rows[0] for marker in _AUDIT_MARKERS)


def _md5_candidates(cfg: dict[str, Any], search_type: int) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []

    def add(value: str) -> None:
        value = value.strip()
        if not value or value in seen:
            return
        seen.add(value)
        ordered.append(value)

    add(str(cfg.get("forceRefreshMd5", "")))
    add(_load_cached_md5(cfg, search_type))
    add(_DEFAULT_STALE_MD5)
    add("00000000000000000000000000000000")
    add("")
    return ordered


def fetch_doctor_unit_list(
    cfg: dict[str, Any],
    session: MinkeSession,
    search_type: int,
    md5_str: str = "",
) -> list[dict[str, str]]:
    rows, _ = _fetch_doctor_unit_list_once(cfg, session, search_type, md5_str)
    return rows


def _fetch_doctor_unit_list_once(
    cfg: dict[str, Any],
    session: MinkeSession,
    search_type: int,
    md5_str: str,
) -> tuple[list[dict[str, str]], str]:
    client = SoapClient(
        str(cfg["docUnitServiceUrl"]),
        NS_DOCTOR_UNIT,
        timeout=int(cfg.get("requestTimeoutSeconds", 120)),
    )
    resp = client.call_operation(
        "DoctorUnitGetList",
        {"aSeachType": search_type, "aMd5Str": md5_str},
        header_xml=session.doctor_header(),
    )
    err = extract_error_message(resp)
    if err:
        raise RuntimeError(f"DoctorUnitGetList error: {err}")
    rows = parse_dataset_rows(resp, MAIN_ROW_TAGS)
    if not rows:
        rows = parse_dataset_rows(resp, MULTI_ROW_TAGS)
    return rows, resp


def fetch_main_list_for_export(
    cfg: dict[str, Any],
    session: MinkeSession,
    search_type: int,
) -> list[dict[str, str]]:
    """Fetch main-practice list with full UI columns (audit date, IfModified, etc.)."""
    best_rows: list[dict[str, str]] = []
    best_md5 = ""
    best_audit = -1

    for md5_str in _md5_candidates(cfg, search_type):
        rows, _ = _fetch_doctor_unit_list_once(cfg, session, search_type, md5_str)
        if not rows:
            continue
        audit = _audit_count(rows)
        full = _is_full_main_list(rows)
        if full and audit >= best_audit:
            best_rows = rows
            best_md5 = md5_str
            best_audit = audit
            if audit > 0:
                break
        elif not best_rows and len(rows) > len(best_rows):
            best_rows = rows
            best_md5 = md5_str
            best_audit = audit

    if not best_rows:
        raise RuntimeError("DoctorUnitGetList returned no rows")

    if best_md5:
        _save_cached_md5(cfg, search_type, best_md5)

    keys = len(best_rows[0])
    audit = _audit_count(best_rows)
    print(
        f"  列表字段 {keys} 个，审核日期 {audit}/{len(best_rows)}（md5={best_md5 or '(empty)'}）",
        file=sys.stderr,
    )
    if audit == 0:
        print(
            "  警告：未拿到审核日期。请在机构端 UI 点「获取最新」后再导出，"
            "或配置 minkeRegApi.forceRefreshMd5 为本地缓存 md5。",
            file=sys.stderr,
        )
    return best_rows
