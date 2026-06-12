from __future__ import annotations

import argparse
import sys
from pathlib import Path

from src.api import (
    default_output_path,
    fetch_all_records,
    load_api_config,
    merge_api_config,
    project_root,
    save_xlsx,
)
from src.cli.automation import AUTOMATION_TASKS, describe_task, run_task


def cmd_fetch_doctors(args: argparse.Namespace) -> int:
    try:
        api_cfg = merge_api_config(load_api_config(args.config))
        if args.page_size is not None:
            api_cfg["pageSize"] = args.page_size

        records = fetch_all_records(api_cfg, max_pages=args.max_pages)
        output_path = args.output or default_output_path(api_cfg)
        save_xlsx(records, output_path)
        print(f"saved {len(records)} records to {output_path}")
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_run_automation(args: argparse.Namespace) -> int:
    key = (args.task, args.entry)
    task = AUTOMATION_TASKS.get(key)
    if not task:
        print(f"[ERROR] unknown automation task: {args.task} / {args.entry}", file=sys.stderr)
        return 1

    if args.dry_run:
        print(f"would run: {describe_task(task, project_root())}")
        return 0

    extra = list(args.extra)
    if extra and extra[0] == "--":
        extra = extra[1:]
    return run_task(task, extra)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Doctor detail screenshot capture CLI")
    subparsers = parser.add_subparsers(dest="command", required=True)

    fetch = subparsers.add_parser("fetch-doctors", help="Fetch doctor medical records via API")
    fetch.add_argument(
        "--config",
        type=Path,
        default=project_root() / "config.json",
        help="Path to config.json",
    )
    fetch.add_argument("--output", type=Path, default=None, help="Output xlsx path")
    fetch.add_argument("--page-size", type=int, default=None, help="Override doctorApi.pageSize")
    fetch.add_argument("--max-pages", type=int, default=None, help="Fetch only first N pages")
    fetch.set_defaults(func=cmd_fetch_doctors)

    run_auto = subparsers.add_parser(
        "run-automation",
        help="Run lower-layer automation cmd via subprocess",
    )
    run_auto.add_argument(
        "task",
        choices=sorted({task for task, _ in AUTOMATION_TASKS}),
        help="Automation task name",
    )
    run_auto.add_argument(
        "--entry",
        choices=["Main", "Multi"],
        default="Main",
        help="List entry for tasks that support Main/Multi",
    )
    run_auto.add_argument(
        "--dry-run",
        action="store_true",
        help="Print target command without executing",
    )
    run_auto.add_argument("extra", nargs="*", default=[], help="Extra args passed to automation")
    run_auto.set_defaults(func=cmd_run_automation)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
