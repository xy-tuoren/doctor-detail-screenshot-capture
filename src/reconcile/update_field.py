from __future__ import annotations

import re

from .field_mapping import FIELD_LABELS

_LABEL_TO_FIELD = {label: field for field, label in FIELD_LABELS.items()}
_FIELD_NAMES = set(FIELD_LABELS)


def parse_update_fields(raw: str | list[str] | None) -> set[str]:
    """Parse updateField into canonical API field names."""
    if raw is None:
        return set()
    if isinstance(raw, list):
        parts = [str(item).strip() for item in raw if str(item).strip()]
    else:
        text = str(raw).strip()
        if not text:
            return set()
        parts = re.split(r"[,，;；\s]+", text)

    fields: set[str] = set()
    for part in parts:
        if part in _FIELD_NAMES:
            fields.add(part)
            continue
        mapped = _LABEL_TO_FIELD.get(part)
        if mapped:
            fields.add(mapped)
    return fields
