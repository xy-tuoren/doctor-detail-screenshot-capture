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


def workspace_cache_dir(workspace: Path) -> Path:
    path = workspace / "cache"
    path.mkdir(parents=True, exist_ok=True)
    return path


def workspace_debug_dir(workspace: Path) -> Path:
    path = workspace / "debug"
    path.mkdir(parents=True, exist_ok=True)
    return path


def workspace_tmp_dir(workspace: Path) -> Path:
    path = workspace / "tmp"
    path.mkdir(parents=True, exist_ok=True)
    return path


# --- 管线主产物（固定文件名，每次覆盖）---

def to_submit_json(workspace: Path) -> Path:
    return workspace / "to_submit.json"


def reconcile_report_xlsx(workspace: Path) -> Path:
    """核对名单：单文件三 sheet（莲藕有机构端无 / 机构端有莲藕无 / 需补充名单）。"""
    return workspace / "reconcile_report.xlsx"


def reconcile_summary_json(workspace: Path) -> Path:
    """核对摘要：条数统计与导出来源，不含完整操作体。"""
    return workspace / "reconcile_summary.json"


def doctors_api_cache_json(workspace: Path) -> Path:
    return workspace_cache_dir(workspace) / "doctors_api_cache.json"


# --- 仅 --debug 时写入 debug/ ---

def doctors_json(workspace: Path) -> Path:
    return workspace_debug_dir(workspace) / "doctors.json"


def export_index_json(workspace: Path) -> Path:
    return workspace_debug_dir(workspace) / "export_index.json"


def reconcile_result_json(workspace: Path) -> Path:
    return workspace_debug_dir(workspace) / "reconcile_result.json"


# --- 采图等临时文件 tmp/ ---

def capture_config_json(workspace: Path, list_entry: str) -> Path:
    return workspace_tmp_dir(workspace) / f"capture-config-{list_entry.lower()}.json"


def nhc_failures_log(workspace: Path) -> Path:
    return workspace_tmp_dir(workspace) / "nhc-failures.log"


# --- 已废弃路径（兼容旧脚本引用）---

def to_supplement_json(workspace: Path) -> Path:
    return workspace / "to_supplement.json"


def to_create_json(workspace: Path) -> Path:
    return workspace / "to_create.json"


def supplement_plan_json(workspace: Path) -> Path:
    return workspace / "supplement_plan.json"


def capture_targets_json(workspace: Path) -> Path:
    return workspace / "capture_targets.json"


def missing_roster_xlsx(workspace: Path, timestamp: str | None = None) -> Path:
    return reconcile_report_xlsx(workspace)


def roster_lianou_has_export_missing_xlsx(workspace: Path, timestamp: str | None = None) -> Path:
    return reconcile_report_xlsx(workspace)


def roster_export_has_lianou_missing_xlsx(workspace: Path, timestamp: str | None = None) -> Path:
    return reconcile_report_xlsx(workspace)


def lianou_only_xlsx(workspace: Path, timestamp: str | None = None) -> Path:
    return reconcile_report_xlsx(workspace)


def export_only_xlsx(workspace: Path, timestamp: str | None = None) -> Path:
    return reconcile_report_xlsx(workspace)
