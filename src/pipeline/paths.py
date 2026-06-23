from __future__ import annotations

from datetime import datetime
from pathlib import Path

from src.api.config import project_root


def default_workspace(root: Path | None = None) -> Path:
    return (root or project_root()) / "workspace"


def ensure_workspace(root: Path | None = None) -> Path:
    path = default_workspace(root)
    path.mkdir(parents=True, exist_ok=True)
    return path


def to_supplement_json(workspace: Path) -> Path:
    return workspace / "to_supplement.json"


def to_create_json(workspace: Path) -> Path:
    return workspace / "to_create.json"


def doctors_json(workspace: Path) -> Path:
    return workspace / "doctors.json"


def export_index_json(workspace: Path) -> Path:
    return workspace / "export_index.json"


def reconcile_result_json(workspace: Path) -> Path:
    return workspace / "reconcile_result.json"


def supplement_plan_json(workspace: Path) -> Path:
    return workspace / "supplement_plan.json"


def capture_targets_json(workspace: Path) -> Path:
    return workspace / "capture_targets.json"


def missing_roster_xlsx(exports_dir: Path, timestamp: str | None = None) -> Path:
    ts = timestamp or datetime.now().strftime("%Y-%m-%d_%H%M%S")
    return exports_dir / f"缺失名单-{ts}.xlsx"
