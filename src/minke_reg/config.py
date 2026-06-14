from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .constants import DEFAULT_MINKE_REG_CONFIG


def project_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def load_minke_reg_config(config_path: Path) -> dict[str, Any]:
    if not config_path.exists():
        raise FileNotFoundError(f"config not found: {config_path}")
    with config_path.open(encoding="utf-8-sig") as f:
        data = json.load(f)

    section = data.get("minkeRegApi")
    if not isinstance(section, dict):
        raise ValueError("config.json missing minkeRegApi section")

    merged = dict(DEFAULT_MINKE_REG_CONFIG)
    merged.update(section)

    if not merged.get("loginUser"):
        merged["loginUser"] = data.get("loginUser") or ""
    if not merged.get("loginPassword"):
        merged["loginPassword"] = data.get("loginPassword") or ""

    if not str(merged.get("loginUser", "")).strip():
        raise ValueError("minkeRegApi.loginUser or loginUser is required")
    if not str(merged.get("loginPassword", "")).strip():
        raise ValueError("minkeRegApi.loginPassword or loginPassword is required")

    return merged
