"""Institution export directory layout under ``exports/``."""

from __future__ import annotations

from pathlib import Path

# 机构端客户端 UI 手动导出（.xls / .xlsx）
EXPORT_UI_DIR = "ui"

# SOAP 接口自动导出（.xlsx）
EXPORT_REG_API_DIR = "reg-api"

EXPORT_SOURCE_DIRS = (EXPORT_UI_DIR, EXPORT_REG_API_DIR)


def export_source_path(exports_dir: Path, source: str) -> Path:
    """Return ``exports/<source>/`` and ensure it exists."""
    path = exports_dir / source
    path.mkdir(parents=True, exist_ok=True)
    return path
