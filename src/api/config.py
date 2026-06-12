from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .constants import DEFAULT_API_CONFIG


def project_root() -> Path:
    return Path(__file__).resolve().parent.parent.parent


def load_api_config(config_path: Path) -> dict[str, Any]:
    if not config_path.exists():
        raise FileNotFoundError(f"config not found: {config_path}")
    with config_path.open(encoding="utf-8-sig") as f:
        data = json.load(f)
    api_cfg = data.get("doctorApi")
    if not isinstance(api_cfg, dict):
        raise ValueError("config.json missing doctorApi section")
    return api_cfg


def merge_api_config(api_cfg: dict[str, Any]) -> dict[str, Any]:
    merged = dict(DEFAULT_API_CONFIG)
    merged.update(api_cfg)
    return merged
