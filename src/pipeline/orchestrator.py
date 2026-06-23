from __future__ import annotations

from pathlib import Path

from src.pipeline.paths import ensure_workspace


def run_pipeline(
    *,
    workspace: Path | None = None,
    steps: list[str] | None = None,
) -> int:
    """Programmatic entry for future orchestration hooks."""
    from src.cli.pipeline_cmds import (
        cmd_capture_institution,
        cmd_capture_nhc,
        cmd_export_reg,
        cmd_fetch,
        cmd_fill_images,
        cmd_parse_exports,
        cmd_reconcile,
        cmd_submit,
    )
    import argparse

    ws = ensure_workspace(workspace)
    args = argparse.Namespace(
        config=Path("config.json"),
        workspace=ws,
        debug=False,
        refresh_cache=False,
        output_json=None,
        save_json=False,
        page_size=None,
        max_pages=None,
        exports_dir=None,
        doctors=None,
        export_index=None,
        output=None,
        lianou_output=None,
        export_output=None,
        plan=None,
        include_images=False,
        captures_dir=None,
        nhc_dir=None,
        output_dir=None,
        province=None,
        hospital=None,
        interval=None,
        show_browser=False,
        dry_run=False,
        commit=False,
        skip_main=False,
        skip_multi=False,
        skip_submit=False,
        skip_capture=False,
    )

    handlers = {
        "export-reg": cmd_export_reg,
        "fetch": cmd_fetch,
        "parse-exports": cmd_parse_exports,
        "reconcile": cmd_reconcile,
        "capture-institution": cmd_capture_institution,
        "capture-nhc": cmd_capture_nhc,
        "fill-images": cmd_fill_images,
        "submit": cmd_submit,
    }
    selected = steps or ["reconcile", "capture-institution", "capture-nhc", "fill-images", "submit"]
    for name in selected:
        handler = handlers.get(name)
        if not handler:
            raise ValueError(f"unknown pipeline step: {name}")
        code = handler(args)
        if code != 0:
            return code
    return 0
