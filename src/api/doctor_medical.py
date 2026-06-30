from __future__ import annotations

import math
from typing import Any

from .client import request_page
from .constants import HOSPITAL_LEVEL_LABELS, MEDICAL_INSTITUTION_TYPE_LABELS


def normalize_row(item: dict[str, Any]) -> dict[str, Any]:
    row = dict(item)
    update_field = row.get("updateField")
    if isinstance(update_field, list):
        row["updateField"] = ", ".join(str(v) for v in update_field)
    elif update_field is None:
        row["updateField"] = ""

    institution_type = row.get("medicalInstitutionType")
    row["_medicalInstitutionTypeLabel"] = MEDICAL_INSTITUTION_TYPE_LABELS.get(
        institution_type, ""
    )

    hospital_level = row.get("hospitalLevel")
    row["_hospitalLevelLabel"] = HOSPITAL_LEVEL_LABELS.get(hospital_level, "")

    professional_list = row.get("professionalList")
    if isinstance(professional_list, list):
        row["_professionalListLabel"] = ";".join(
            str(item.get("professionalName", "")).strip()
            for item in professional_list
            if isinstance(item, dict) and str(item.get("professionalName", "")).strip()
        )
    else:
        row["_professionalListLabel"] = ""

    return row


def fetch_all_records(
    api_cfg: dict[str, Any],
    max_pages: int | None = None,
) -> list[dict[str, Any]]:
    page_size = int(api_cfg.get("pageSize", 100))
    if page_size <= 0:
        raise ValueError("doctorApi.pageSize must be > 0")

    first_page = request_page(api_cfg, 1, page_size)
    total = int(first_page.get("total") or 0)
    records = [normalize_row(item) for item in first_page.get("list") or []]
    total_pages = max(1, math.ceil(total / page_size)) if total else 1

    if max_pages is not None:
        total_pages = min(total_pages, max_pages)

    print(f"total={total}, pageSize={page_size}, pages={total_pages}")
    print(f"page 1/{total_pages}: fetched {len(records)} records")

    for page_index in range(2, total_pages + 1):
        page_data = request_page(api_cfg, page_index, page_size)
        page_list = page_data.get("list") or []
        records.extend(normalize_row(item) for item in page_list)
        print(f"page {page_index}/{total_pages}: fetched {len(page_list)} records")

    return records
