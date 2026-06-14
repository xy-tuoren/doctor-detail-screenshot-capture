from __future__ import annotations

import xml.etree.ElementTree as ET


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def parse_dataset_rows(soap_xml: str, row_tags: frozenset[str]) -> list[dict[str, str]]:
    root = ET.fromstring(soap_xml)
    rows: list[dict[str, str]] = []
    for elem in root.iter():
        if _local_name(elem.tag) not in row_tags:
            continue
        row = {
            _local_name(child.tag): (child.text or "").strip()
            for child in list(elem)
        }
        if row:
            rows.append(row)
    return rows
