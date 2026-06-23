from __future__ import annotations



from typing import Any



from .constants import MAIN_ROW_TAGS, MULTI_ROW_TAGS, NS_DOCTOR_UNIT

from .dataset import parse_dataset_rows

from .doctor_detail import enrich_main_rows, format_main_row_ui

from .session import MinkeSession

from .soap import SoapClient, extract_error_message





def fetch_doctor_unit_list(

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

        "DoctorUnitGetList",

        {"aSeachType": search_type, "aMd5Str": md5_str},

        header_xml=session.doctor_header(),

    )

    err = extract_error_message(resp)

    if err:

        raise RuntimeError(f"DoctorUnitGetList error: {err}")

    rows = parse_dataset_rows(resp, MAIN_ROW_TAGS)

    if rows:

        return rows

    return parse_dataset_rows(resp, MULTI_ROW_TAGS)





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

    return parse_dataset_rows(resp, MAIN_ROW_TAGS)





def export_main_records(cfg: dict[str, Any], session: MinkeSession) -> dict[str, list[dict[str, str]]]:

    md5_str = str(cfg.get("forceRefreshMd5", ""))

    search_type = int(cfg.get("mainSearchType", 1))

    rows = fetch_doctor_unit_list(cfg, session, search_type, md5_str)

    rows = enrich_main_rows(cfg, session, rows)

    rows = [format_main_row_ui(row) for row in rows]

    return {"主执业": rows}





def export_multi_records(cfg: dict[str, Any], session: MinkeSession) -> list[dict[str, str]]:

    md5_str = str(cfg.get("forceRefreshMd5", ""))

    search_type = int(cfg.get("multiSearchType", 8))

    if cfg.get("useDoctorUnitGetListForOther", False):

        return fetch_doctor_unit_list_for_other(cfg, session, search_type, md5_str)

    return fetch_doctor_unit_list(cfg, session, search_type, md5_str)

