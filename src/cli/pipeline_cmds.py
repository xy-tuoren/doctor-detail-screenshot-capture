from __future__ import annotations

import argparse
import sys
from pathlib import Path

from src.api import (
    default_output_path,
    fetch_doctors_with_cache,
    load_api_config,
    merge_api_config,
    project_root,
    save_xlsx,
)
from src.capture.runner import (
    find_institution_image,
    find_nhc_image,
    run_institution_capture,
    run_nhc_capture,
)
from src.capture.paths import default_nhc_captures_dir
from src.institution_export import build_export_index
from src.lianou.writeback import LianouWritebackClient, apply_supplement_plan
from src.pipeline.io import load_json, save_json
from src.pipeline.paths import (
    capture_targets_json,
    doctors_json,
    ensure_workspace,
    export_index_json,
    missing_roster_xlsx,
    reconcile_result_json,
    supplement_plan_json,
    to_supplement_json,
)
from src.reconcile import (
    iter_institution_capture_targets,
    iter_nhc_capture_targets,
    iter_payloads,
    reconcile_doctors,
    save_missing_roster,
)


def _workspace(args: argparse.Namespace) -> Path:
    if args.workspace is not None:
        args.workspace.mkdir(parents=True, exist_ok=True)
        return args.workspace
    return ensure_workspace()


def _load_doctors(args: argparse.Namespace, workspace: Path) -> list:
    if args.doctors:
        return load_json(args.doctors)
    api_cfg = merge_api_config(load_api_config(args.config))
    if args.page_size is not None:
        api_cfg["pageSize"] = args.page_size
    return fetch_doctors_with_cache(
        api_cfg,
        workspace,
        refresh=bool(getattr(args, "refresh_cache", False)),
        max_pages=args.max_pages,
    )


def _load_export_index(args: argparse.Namespace) -> dict:
    if args.export_index:
        return load_json(args.export_index)
    exports_dir = args.exports_dir or (project_root() / "exports")
    return build_export_index(exports_dir)


def cmd_fetch(args: argparse.Namespace) -> int:
    try:
        workspace = _workspace(args)
        api_cfg = merge_api_config(load_api_config(args.config))
        if args.page_size is not None:
            api_cfg["pageSize"] = args.page_size

        records = fetch_doctors_with_cache(
            api_cfg,
            workspace,
            refresh=bool(getattr(args, "refresh_cache", False)),
            max_pages=args.max_pages,
        )

        if args.output_json or args.save_json or args.debug:
            out_json = args.output_json or doctors_json(workspace)
            save_json(out_json, records)
            print(f"saved {len(records)} doctors to {out_json}")
        else:
            print(f"fetched {len(records)} doctors (not saved; use --save-json or --output-json)")

        if args.output_xlsx:
            save_xlsx(records, args.output_xlsx)
        elif args.save_xlsx:
            xlsx_path = default_output_path(api_cfg)
            save_xlsx(records, xlsx_path)
            print(f"saved xlsx: {xlsx_path}")

        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_parse_exports(args: argparse.Namespace) -> int:
    try:
        workspace = _workspace(args)
        exports_dir = args.exports_dir or (project_root() / "exports")
        index = build_export_index(exports_dir)

        sources = index.get("sources", {})
        counts = index.get("counts", {})
        print(f"main: {counts.get('main', 0)} rows from {sources.get('main')}")
        print(f"multi: {counts.get('multi', 0)} rows from {sources.get('multi')}")

        if args.output or args.save_json or args.debug:
            out_path = args.output or export_index_json(workspace)
            save_json(out_path, index)
            print(f"saved export index to {out_path}")
        else:
            print("export index not saved (use --save-json or --output)")

        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_reconcile(args: argparse.Namespace) -> int:
    try:
        workspace = _workspace(args)
        doctors = _load_doctors(args, workspace)
        export_index = _load_export_index(args)
        result = reconcile_doctors(doctors, export_index)

        payloads = result.get("payloads") or []
        supplement_path = args.output or to_supplement_json(workspace)
        save_json(supplement_path, payloads)

        exports_dir = args.exports_dir or (project_root() / "exports")
        missing_path = args.missing_output or missing_roster_xlsx(exports_dir)
        save_missing_roster(result.get("missing", []), missing_path)

        if args.debug:
            save_json(doctors_json(workspace), doctors)
            save_json(export_index_json(workspace), export_index)
            save_json(reconcile_result_json(workspace), result)
            save_json(
                capture_targets_json(workspace),
                {
                    "institution": iter_institution_capture_targets(payloads),
                    "nhc": iter_nhc_capture_targets(payloads),
                },
            )
            print("[debug] saved doctors.json, export_index.json, reconcile_result.json")

        summary = result.get("summary", {})
        print(
            "reconcile: "
            f"doctors={summary.get('doctors', 0)} "
            f"matchedKeys={summary.get('matchedKeys', 0)} "
            f"matchedRecords={summary.get('matchedRecords', 0)} "
            f"missing={summary.get('missing', 0)} "
            f"missingNoIdCard={summary.get('missingNoIdCard', 0)} "
            f"missingNotInExport={summary.get('missingNotInExport', 0)} "
            f"nameMismatch={summary.get('nameMismatch', 0)}"
        )
        print(f"saved to_supplement.json to {supplement_path}")
        print(f"saved missing roster to {missing_path}")
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_supplement(args: argparse.Namespace) -> int:
    try:
        workspace = _workspace(args)
        plan_path = args.plan or to_supplement_json(workspace)
        if not plan_path.exists():
            raise FileNotFoundError(f"to_supplement.json not found: {plan_path}")

        plan = load_json(plan_path)
        api_cfg = merge_api_config(load_api_config(args.config))
        dry_run = not args.commit
        results = apply_supplement_plan(
            plan, api_cfg, dry_run=dry_run, include_images=args.include_images
        )

        ok = sum(1 for item in results if item.ok)
        failed = len(results) - ok
        for item in results:
            status = "OK" if item.ok else "FAIL"
            print(f"[{status}] aId={item.a_id} {item.doctor_name}: {item.message}")

        mode = "dry-run" if dry_run else "commit"
        print(f"supplement ({mode}): total={len(results)} ok={ok} failed={failed}")
        if failed and not dry_run:
            return 1
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_capture_institution(args: argparse.Namespace) -> int:
    try:
        workspace = _workspace(args)
        plan_path = args.plan or to_supplement_json(workspace)
        if not plan_path.exists():
            raise FileNotFoundError(f"to_supplement.json not found: {plan_path}")

        to_supplement = load_json(plan_path)
        targets = iter_institution_capture_targets(to_supplement)
        captures_root = getattr(args, "captures_dir", None) or (project_root() / "captures")
        code = run_institution_capture(
            targets,
            config_path=args.config,
            workspace=workspace,
            captures_root=captures_root,
            dry_run=args.dry_run,
        )
        print(f"institution capture targets from plan: {len(targets)}")
        return code
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_capture_nhc(args: argparse.Namespace) -> int:
    try:
        workspace = _workspace(args)
        plan_path = args.plan or to_supplement_json(workspace)
        if not plan_path.exists():
            raise FileNotFoundError(f"to_supplement.json not found: {plan_path}")

        to_supplement = load_json(plan_path)
        targets = iter_nhc_capture_targets(to_supplement)

        nhc_cfg = {}
        try:
            full_cfg = load_json(args.config)
            if isinstance(full_cfg, dict):
                nhc_cfg = full_cfg.get("nhcCapture") or {}
        except Exception:
            nhc_cfg = {}

        code = run_nhc_capture(
            targets,
            workspace=workspace,
            output_dir=args.output_dir,
            province=args.province or nhc_cfg.get("province"),
            hospital=args.hospital or nhc_cfg.get("hospital"),
            interval=args.interval if args.interval is not None else nhc_cfg.get("interval"),
            headless=not args.show_browser,
            dry_run=args.dry_run,
        )
        print(f"nhc capture targets: {len(targets)}")
        return code
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_upload_images(args: argparse.Namespace) -> int:
    try:
        from src.lianou.writeback import encode_image_base64
        from src.reconcile.to_supplement import (
            capture_meta,
            needs_institution_capture,
            needs_nhc_capture,
            normalize_payloads,
        )

        workspace = _workspace(args)
        plan_path = args.plan or to_supplement_json(workspace)
        if not plan_path.exists():
            raise FileNotFoundError(f"to_supplement.json not found: {plan_path}")

        payloads = normalize_payloads(load_json(plan_path))
        api_cfg = merge_api_config(load_api_config(args.config))
        client = LianouWritebackClient(api_cfg)
        dry_run = not args.commit

        root = project_root()
        captures_root = args.captures_dir or (root / "captures")
        nhc_root = args.nhc_dir or default_nhc_captures_dir(root)

        ok = skipped = failed = filled = 0
        exit_code = 0
        for payload in payloads:
            meta = capture_meta(payload)
            name = str(payload.get("doctorName") or "")
            id_card = str(meta.get("idCard") or "")
            cert_code = meta.get("certCode")

            touched = False
            if needs_institution_capture(payload):
                image = find_institution_image(captures_root, name, id_card)
                if image:
                    payload["institutionBase"] = encode_image_base64(
                        image, data_uri=client.image_data_uri
                    )
                    touched = True
                    filled += 1
                    print(f"[FILL] {name} institutionBase <- {image.name}")
                else:
                    print(f"[SKIP] {name} institutionBase: image not found")
                    skipped += 1

            if needs_nhc_capture(payload):
                image = find_nhc_image(nhc_root, name, cert_code)
                if image:
                    payload["healthCommissionBase"] = encode_image_base64(
                        image, data_uri=client.image_data_uri
                    )
                    touched = True
                    filled += 1
                    print(f"[FILL] {name} healthCommissionBase <- {image.name}")
                else:
                    print(f"[SKIP] {name} healthCommissionBase: image not found")
                    skipped += 1

            if touched and not dry_run:
                result = client.update_from_payload(payload)
                status = "OK" if result.ok else "FAIL"
                print(f"[{status}] AId={payload.get('AId')} {name}: {result.message}")
                if result.ok:
                    ok += 1
                else:
                    failed += 1
                    exit_code = 1
            elif touched and dry_run:
                print(f"[DRY] AId={payload.get('AId')} {name}: would upload after fill")

        save_json(plan_path, payloads)

        mode = "dry-run" if dry_run else "commit"
        print(f"upload-images ({mode}): filled={filled} ok={ok} skipped={skipped} failed={failed}")
        print(f"saved {plan_path}")
        return exit_code
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_run_all(args: argparse.Namespace) -> int:
    steps = [
        ("reconcile", cmd_reconcile),
    ]
    if not args.skip_supplement:
        steps.append(("supplement", cmd_supplement))
    if not args.skip_capture:
        steps.extend(
            [
                ("capture-institution", cmd_capture_institution),
                ("capture-nhc", cmd_capture_nhc),
                ("upload-images", cmd_upload_images),
            ]
        )

    for name, handler in steps:
        print(f"\n=== {name} ===")
        code = handler(args)
        if code != 0:
            print(f"[ERROR] step failed: {name}", file=sys.stderr)
            return code
    print("\nrun-all completed")
    return 0


def add_pipeline_commands(subparsers: argparse._SubParsersAction) -> None:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--config",
        type=Path,
        default=project_root() / "config.json",
        help="Path to config.json",
    )
    common.add_argument(
        "--workspace",
        type=Path,
        default=None,
        help="Pipeline workspace directory (default: ./workspace)",
    )
    common.add_argument(
        "--debug",
        action="store_true",
        help="Save intermediate debug artifacts (doctors.json, export_index.json, etc.)",
    )
    common.add_argument(
        "--refresh-cache",
        action="store_true",
        help="Ignore doctors API cache and fetch fresh data (default: reuse 24h cache)",
    )

    fetch = subparsers.add_parser("fetch", parents=[common], help="Fetch Lianou doctors")
    fetch.add_argument("--output-json", type=Path, default=None, help="Output doctors.json path")
    fetch.add_argument("--save-json", action="store_true", help="Save doctors.json to workspace")
    fetch.add_argument("--output-xlsx", type=Path, default=None, help="Optional xlsx output path")
    fetch.add_argument("--save-xlsx", action="store_true", help="Also save default exports xlsx")
    fetch.add_argument("--page-size", type=int, default=None)
    fetch.add_argument("--max-pages", type=int, default=None)
    fetch.set_defaults(func=cmd_fetch)

    parse_exports = subparsers.add_parser(
        "parse-exports", parents=[common], help="Parse latest institution UI exports"
    )
    parse_exports.add_argument(
        "--exports-dir",
        type=Path,
        default=None,
        help="Directory containing 主执业导出 / 多执业导出 files",
    )
    parse_exports.add_argument("--output", type=Path, default=None)
    parse_exports.add_argument("--save-json", action="store_true", help="Save export_index.json")
    parse_exports.set_defaults(func=cmd_parse_exports)

    reconcile = subparsers.add_parser(
        "reconcile", parents=[common], help="Reconcile doctors and build to_supplement.json"
    )
    reconcile.add_argument("--doctors", type=Path, default=None, help="Use existing doctors.json")
    reconcile.add_argument("--export-index", type=Path, default=None, help="Use existing export index")
    reconcile.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output to_supplement.json path (default: workspace/to_supplement.json)",
    )
    reconcile.add_argument("--missing-output", type=Path, default=None)
    reconcile.add_argument("--exports-dir", type=Path, default=None)
    reconcile.add_argument("--page-size", type=int, default=None)
    reconcile.add_argument("--max-pages", type=int, default=None)
    reconcile.set_defaults(func=cmd_reconcile)

    supplement = subparsers.add_parser(
        "supplement", parents=[common], help="Write mapped fields back to Lianou"
    )
    supplement.add_argument(
        "--plan",
        type=Path,
        default=None,
        help="Path to to_supplement.json (default: workspace/to_supplement.json)",
    )
    supplement.add_argument(
        "--include-images",
        action="store_true",
        help="Also submit healthCommissionBase/institutionBase when present in JSON",
    )
    supplement.add_argument(
        "--commit", action="store_true", help="Actually call the update API (default: dry-run)"
    )
    supplement.set_defaults(func=cmd_supplement)

    capture_institution = subparsers.add_parser(
        "capture-institution",
        parents=[common],
        help="Capture institution-side screenshots for missing institutionBase",
    )
    capture_institution.add_argument(
        "--plan",
        type=Path,
        default=None,
        help="Path to to_supplement.json (default: workspace/to_supplement.json)",
    )
    capture_institution.add_argument(
        "--captures-dir",
        type=Path,
        default=None,
        help="Existing screenshot root (default: ./captures)",
    )
    capture_institution.add_argument("--dry-run", action="store_true")
    capture_institution.set_defaults(func=cmd_capture_institution)

    capture_nhc = subparsers.add_parser(
        "capture-nhc",
        parents=[common],
        help="Capture NHC screenshots for missing healthCommissionBase",
    )
    capture_nhc.add_argument(
        "--plan",
        type=Path,
        default=None,
        help="Path to to_supplement.json (default: workspace/to_supplement.json)",
    )
    capture_nhc.add_argument("--output-dir", type=Path, default=None)
    capture_nhc.add_argument("--province", default=None, help="所在省份（默认读 config 或广东省）")
    capture_nhc.add_argument("--hospital", default=None, help="所在医疗机构（默认读 config 或莲藕健康医院）")
    capture_nhc.add_argument("--interval", type=int, default=None, help="查询间隔秒数")
    capture_nhc.add_argument("--show-browser", action="store_true", help="显示浏览器（默认无头）")
    capture_nhc.add_argument("--dry-run", action="store_true")
    capture_nhc.set_defaults(func=cmd_capture_nhc)

    upload_images = subparsers.add_parser(
        "upload-images",
        parents=[common],
        help="Upload captured images to Lianou (base64 via UpdateDoctorMedical)",
    )
    upload_images.add_argument(
        "--plan",
        type=Path,
        default=None,
        help="Path to to_supplement.json (default: workspace/to_supplement.json)",
    )
    upload_images.add_argument("--captures-dir", type=Path, default=None)
    upload_images.add_argument("--nhc-dir", type=Path, default=None)
    upload_images.add_argument(
        "--commit", action="store_true", help="Actually call the update API (default: dry-run)"
    )
    upload_images.set_defaults(func=cmd_upload_images)

    run_all = subparsers.add_parser("run-all", parents=[common], help="Run full pipeline")
    run_all.add_argument("--exports-dir", type=Path, default=None)
    run_all.add_argument("--doctors", type=Path, default=None)
    run_all.add_argument("--export-index", type=Path, default=None)
    run_all.add_argument("--output", type=Path, default=None)
    run_all.add_argument("--missing-output", type=Path, default=None)
    run_all.add_argument("--plan", type=Path, default=None)
    run_all.add_argument("--captures-dir", type=Path, default=None)
    run_all.add_argument("--nhc-dir", type=Path, default=None)
    run_all.add_argument("--output-dir", type=Path, default=None)
    run_all.add_argument("--province", default=None)
    run_all.add_argument("--hospital", default=None)
    run_all.add_argument("--interval", type=int, default=None)
    run_all.add_argument("--page-size", type=int, default=None)
    run_all.add_argument("--max-pages", type=int, default=None)
    run_all.add_argument("--show-browser", action="store_true")
    run_all.add_argument("--dry-run", action="store_true", help="Dry-run captures")
    run_all.add_argument(
        "--commit", action="store_true", help="Actually write back to Lianou (supplement/upload)"
    )
    run_all.add_argument("--include-images", action="store_true")
    run_all.add_argument("--skip-supplement", action="store_true")
    run_all.add_argument("--skip-capture", action="store_true")
    run_all.set_defaults(func=cmd_run_all)
