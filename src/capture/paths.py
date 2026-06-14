from __future__ import annotations

from pathlib import Path

from src.api.config import project_root


def default_nhc_captures_dir(root: Path | None = None) -> Path:
    """Default directory for NHC (卫健委) screenshots."""
    return (root or project_root()) / "captures" / "卫健委"
