"""In-process wrapper around the inlined NHC capture core.

Optional heavy deps (playwright / ddddocr) are imported lazily so the rest of
the pipeline works without the `capture-nhc` extra installed.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any


class NhcDependencyError(RuntimeError):
    """Raised when optional capture-nhc dependencies are missing."""


def _load_core():
    try:
        from . import nhc_core
    except ImportError as exc:  # pragma: no cover - depends on optional extras
        raise NhcDependencyError(
            "卫健委采集依赖未安装。请先安装可选依赖组：\n"
            "  pip install -e .[capture-nhc]\n"
            "  playwright install chromium\n"
            f"（导入失败：{exc}）"
        ) from exc
    return nhc_core


def _normalize_targets(targets: list[dict[str, Any]]) -> list[dict[str, Any]]:
    doctors: list[dict[str, Any]] = []
    seen: set[str] = set()
    for item in targets:
        name = str(item.get("name") or "").strip()
        if not name:
            continue
        cert = item.get("certCode") or None
        key = f"{name}_{cert or ''}"
        if key in seen:
            continue
        seen.add(key)
        doctors.append({"name": name, "certCode": cert})
    return doctors


def _filter_existing(doctors: list[dict[str, Any]], output_dir: Path) -> list[dict[str, Any]]:
    pending = []
    for doc in doctors:
        cert = doc.get("certCode")
        if cert and (output_dir / f"{doc['name']}_{cert}.png").exists():
            continue
        if not cert and list(output_dir.glob(f"{doc['name']}_*.png")):
            continue
        pending.append(doc)
    return pending


def run_nhc_capture(
    targets: list[dict[str, Any]],
    *,
    output_dir: Path,
    failure_log: Path | None = None,
    province: str | None = None,
    hospital: str | None = None,
    interval: int | None = None,
    headless: bool = True,
    proxy: str | None = None,
    dry_run: bool = False,
) -> dict[str, Any]:
    doctors = _normalize_targets(targets)
    output_dir.mkdir(parents=True, exist_ok=True)
    pending = _filter_existing(doctors, output_dir)

    summary = {
        "total": len(doctors),
        "skippedExisting": len(doctors) - len(pending),
        "pending": len(pending),
    }

    if dry_run:
        summary["mode"] = "dry-run"
        return summary

    if not pending:
        summary["mode"] = "noop"
        return summary

    core = _load_core()
    core.set_output_dir(str(output_dir))
    if failure_log is not None:
        core.set_failure_log(str(failure_log))

    results = core.batch_query(
        pending,
        province=province or core.DEFAULT_PROVINCE,
        hospital=hospital or core.DEFAULT_HOSPITAL,
        interval=interval if interval is not None else core.DEFAULT_INTERVAL,
        headless=headless,
        proxy=proxy,
    )
    summary["mode"] = "captured"
    summary["result"] = {
        "success": len(results.get("success", [])),
        "failed": len(results.get("failed", [])),
        "screenshots": results.get("total_screenshots", 0),
    }
    return summary
