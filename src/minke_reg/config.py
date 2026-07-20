from __future__ import annotations

import json
import os
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

    merged["loginUser"] = str(merged.get("loginUser", "")).strip()
    merged["loginPassword"] = str(merged.get("loginPassword", "")).strip()

    env_user = os.environ.get("MINKE_REG_USER", "").strip()
    env_password = os.environ.get("MINKE_REG_PASSWORD", "").strip()
    if env_user:
        merged["loginUser"] = env_user
    if env_password:
        merged["loginPassword"] = env_password

    if not merged["loginUser"]:
        raise ValueError("minkeRegApi.loginUser or loginUser is required")
    if not merged["loginPassword"]:
        raise ValueError(
            "minkeRegApi.loginPassword or loginPassword is required "
            "(or set MINKE_REG_PASSWORD)"
        )

    return merged


def apply_minke_credential_overrides(
    cfg: dict[str, Any],
    *,
    login_user: str | None = None,
    login_password: str | None = None,
) -> dict[str, Any]:
    updated = dict(cfg)
    if login_user is not None and str(login_user).strip():
        updated["loginUser"] = str(login_user).strip()
    if login_password is not None and str(login_password).strip():
        updated["loginPassword"] = str(login_password).strip()
    return updated
