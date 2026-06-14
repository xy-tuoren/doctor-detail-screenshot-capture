from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

from src.api.config import project_root
from src.capture.paths import default_nhc_captures_dir
from src.cli.automation import PS1, run_task, AutomationTask


def build_capture_config(
    base_config: Path,
    persons: list[dict[str, str]],
    list_entry: str,
    output_path: Path,
) -> None:
    with base_config.open(encoding="utf-8-sig") as f:
        cfg = json.load(f)

    key = "namesMulti" if list_entry == "Multi" else "namesMain"
    cfg[key] = [{"name": p["name"], "idCard": p.get("idCard", "")} for p in persons]
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def run_institution_capture(
    targets: list[dict[str, Any]],
    *,
    config_path: Path,
    workspace: Path,
    dry_run: bool = False,
) -> int:
    if not targets:
        print("no institution capture targets")
        return 0

    grouped: dict[str, list[dict[str, str]]] = {"Main": [], "Multi": []}
    for item in targets:
        entry = item.get("listEntry") or "Main"
        grouped.setdefault(entry, []).append(
            {
                "name": str(item.get("name") or ""),
                "idCard": str(item.get("idCard") or ""),
            }
        )

    root = project_root()
    exit_code = 0
    for list_entry, persons in grouped.items():
        if not persons:
            continue
        temp_config = workspace / f"capture-config-{list_entry.lower()}.json"
        build_capture_config(config_path, persons, list_entry, temp_config)
        task = AutomationTask(ps1_mode="LoginAndSearchNames", list_entry=list_entry)
        extra = ["-ConfigPath", str(temp_config)]
        if dry_run:
            print(f"would capture {len(persons)} {list_entry} doctors via {PS1}")
            continue
        code = run_task(task, extra)
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
    failure_log = workspace / "nhc-failures.log"

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


def find_institution_image(captures_root: Path, name: str, id_card: str) -> Path | None:
    for sub in ("主执业", "多执业"):
        folder = captures_root / sub
        if not folder.exists():
            continue
        exact = folder / f"{name}_{id_card}.png"
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
