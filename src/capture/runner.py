from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from src.api.config import project_root
from src.capture.paths import default_nhc_captures_dir
from src.pipeline.paths import nhc_failures_log


def institution_list_folder(list_entry: str) -> str:
    return "多执业" if list_entry == "Multi" else "主执业"


def institution_capture_exists(
    captures_root: Path,
    name: str,
    cert_code: str,
    list_entry: str,
) -> bool:
    """Match PS1 Test-PersonAlreadyCaptured: requires cert_code; checks list-specific folder."""
    if not cert_code.strip():
        return False
    folder = captures_root / institution_list_folder(list_entry)
    if not folder.exists():
        return False
    exact = folder / f"{name}_{cert_code}.png"
    if exact.exists():
        return True
    prefix = f"{name}_"
    for path in folder.glob(f"{name}_*.png"):
        if path.name.startswith(prefix):
            return True
    return False


def filter_institution_capture_targets(
    targets: list[dict[str, Any]],
    captures_root: Path,
) -> tuple[list[dict[str, Any]], int]:
    pending: list[dict[str, Any]] = []
    for item in targets:
        name = str(item.get("name") or "")
        cert_code = str(item.get("certCode") or "")
        list_entry = str(item.get("listEntry") or "Main")
        if institution_capture_exists(captures_root, name, cert_code, list_entry):
            continue
        pending.append(item)
    return pending, len(targets) - len(pending)


def build_capture_config(
    base_config: Path,
    persons: list[dict[str, str]],
    list_entry: str,
    output_path: Path,
) -> None:
    with base_config.open(encoding="utf-8-sig") as f:
        cfg = json.load(f)

    key = "namesMulti" if list_entry == "Multi" else "namesMain"
    cfg[key] = [{"name": p["name"], "certCode": p.get("certCode", "")} for p in persons]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def run_institution_capture(
    targets: list[dict[str, Any]],
    *,
    config_path: Path,
    workspace: Path,
    captures_root: Path | None = None,
    dry_run: bool = False,
) -> int:
    if not targets:
        print("no institution capture targets")
        return 0

    root = project_root()
    captures = captures_root or (root / "captures")
    pending_targets, skipped = filter_institution_capture_targets(targets, captures)
    if skipped:
        print(
            f"institution capture: skipped {skipped}/{len(targets)} "
            f"with existing screenshots under {captures}"
        )
    if not pending_targets:
        print("no institution capture targets (all have existing screenshots)")
        return 0

    grouped: dict[str, list[dict[str, str]]] = {"Main": [], "Multi": []}
    for item in pending_targets:
        entry = item.get("listEntry") or "Main"
        grouped.setdefault(entry, []).append(
            {
                "name": str(item.get("name") or ""),
                "certCode": str(item.get("certCode") or ""),
            }
        )

    exit_code = 0
    for list_entry, persons in grouped.items():
        if not persons:
            continue
        # Load base config.json and inject the target persons list
        with config_path.open(encoding="utf-8-sig") as f:
            config = json.load(f)
        # Inject persons into config so the capture session has the target list
        key = "namesMulti" if list_entry == "Multi" else "namesMain"
        config[key] = persons

        output_dir = captures / institution_list_folder(list_entry)
        error_log = root / "logs" / "error-popup-log.csv"

        from src.capture.institution.runner import run_capture_session
        code = run_capture_session(
            persons=persons,
            list_entry=list_entry,
            config=config,
            output_dir=output_dir,
            dry_run=dry_run,
            error_log_path=error_log,
        )
        if code != 0:
            exit_code = code
    return exit_code


def run_nhc_capture(
    targets: list[dict[str, Any]],
    *,
    workspace: Path,
    output_dir: Path | None = None,
    province: str | None = None,
    hospital: str | None = None,
    interval: int | None = None,
    headless: bool = True,
    dry_run: bool = False,
) -> int:
    if not targets:
        print("no nhc capture targets")
        return 0

    from src.capture.nhc import NhcDependencyError, run_nhc_capture as _run

    root = project_root()
    out_dir = output_dir or default_nhc_captures_dir(root)
    failure_log = nhc_failures_log(workspace)

    try:
        summary = _run(
            targets,
            output_dir=out_dir,
            failure_log=failure_log,
            province=province,
            hospital=hospital,
            interval=interval,
            headless=headless,
            dry_run=dry_run,
        )
    except NhcDependencyError as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1

    print(f"nhc capture summary: {summary}")
    return 0


def find_institution_image(captures_root: Path, name: str, cert_code: str) -> Path | None:
    for sub in ("主执业", "多执业"):
        folder = captures_root / sub
        if not folder.exists():
            continue
        exact = folder / f"{name}_{cert_code}.png"
        if exact.exists():
            return exact
        prefix = f"{name}_"
        for path in folder.glob(f"{name}_*.png"):
            if path.name.startswith(prefix):
                return path
    return None


def find_nhc_image(screenshots_root: Path, name: str, cert_code: str | None) -> Path | None:
    if cert_code:
        exact = screenshots_root / f"{name}_{cert_code}.png"
        if exact.exists():
            return exact
    prefix = f"{name}_"
    if screenshots_root.exists():
        for path in screenshots_root.glob(f"{name}_*.png"):
            if path.name.startswith(prefix):
                return path
    return None
