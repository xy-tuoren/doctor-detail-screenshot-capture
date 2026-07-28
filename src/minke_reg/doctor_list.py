from __future__ import annotations

from typing import Any

from .constants import MULTI_ROW_TAGS, NS_DOCTOR_UNIT
from .dataset import parse_dataset_rows
from .doctor_detail import enrich_main_rows, format_main_row_ui, format_multi_row_ui
from .list_fetch import fetch_main_list_ex, fetch_main_list_for_export
from .session import MinkeSession
from .soap import SoapClient, extract_error_message


def fetch_doctor_unit_list(
    cfg: dict[str, Any],
    session: MinkeSession,
    search_type: int,
    md5_str: str = "",
) -> list[dict[str, str]]:
    from .list_fetch import _fetch_doctor_unit_list_once

    rows, _ = _fetch_doctor_unit_list_once(cfg, session, search_type, md5_str)
    return rows


def fetch_doctor_unit_list_for_other(
    cfg: dict[str, Any],
    session: MinkeSession,
    search_type: int,
    md5_str: str = "",
) -> list[dict[str, str]]:
    client = SoapClient(
        str(cfg["docUnitServiceUrl"]),
        NS_DOCTOR_UNIT,
        timeout=int(cfg.get("requestTimeoutSeconds", 120)),
    )
    resp = client.call_operation(
        "DoctorUnitGetListForOther",
        {"aSeachType": search_type, "aMd5Str": md5_str},
        header_xml=session.doctor_header(),
    )
    err = extract_error_message(resp)
    if err:
        raise RuntimeError(f"DoctorUnitGetListForOther error: {err}")
    rows = parse_dataset_rows(resp, MULTI_ROW_TAGS)
    if rows:
        return rows
    return parse_dataset_rows(resp, frozenset({"vDoctor_RegMain", "tDoctor_RegMain"}))


def export_main_records(cfg: dict[str, Any], session: MinkeSession) -> dict[str, list[dict[str, str]]]:
    search_type = int(cfg.get("mainSearchType", 1))
    # 默认走 DoctorUnitGetListEx：直接返回含 WorkLicenceCode/CpetCode 的列表。
    # GetListEx 不含任职资格；默认再调 GetRegDetailForUnit 补 PostCpetName（mainEnrichDetail）。
    # 配置 mainUseGetListEx=false 时回退到 DoctorUnitGetList + enrich（仍拿不到审核日期）。
    if cfg.get("mainUseGetListEx", True):
        rows = fetch_main_list_ex(cfg, session, search_type)
        if cfg.get("mainEnrichDetail", True):
            rows = enrich_main_rows(cfg, session, rows)
    else:
        rows = fetch_main_list_for_export(cfg, session, search_type)
        rows = enrich_main_rows(cfg, session, rows)
    rows = [format_main_row_ui(row) for row in rows]
    return {"主执业": rows}


def export_multi_records(cfg: dict[str, Any], session: MinkeSession) -> list[dict[str, str]]:
    md5_str = str(cfg.get("forceRefreshMd5", ""))
    search_type = int(cfg.get("multiSearchType", 8))
    if cfg.get("useDoctorUnitGetListForOther", False):
        rows = fetch_doctor_unit_list_for_other(cfg, session, search_type, md5_str)
    else:
        rows = fetch_doctor_unit_list(cfg, session, search_type, md5_str)
    # 多执业列表不含执业证书编码/身份证号，需调详情接口补全；并转成 UI 列名
    rows = enrich_main_rows(cfg, session, rows)
    return [format_multi_row_ui(row) for row in rows]
