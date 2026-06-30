from __future__ import annotations

import argparse
import sys
from pathlib import Path

from src.api import (
    fetch_doctors_with_cache,
    load_api_config,
    merge_api_config,
    project_root,
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
    doctors_json,
    ensure_workspace,
    export_index_json,
    reconcile_report_xlsx,
    reconcile_result_json,
    reconcile_summary_json,
    to_submit_json,
)
from src.reconcile import (
    iter_institution_capture_targets,
    iter_nhc_capture_targets,
    reconcile_doctors,
)
from src.reconcile.missing_roster import save_reconcile_report


def _workspace(args: argparse.Namespace) -> Path:
    if getattr(args, "workspace", None) is not None:
        args.workspace.mkdir(parents=True, exist_ok=True)
        return args.workspace
    return ensure_workspace()


def _plan_path(args: argparse.Namespace, workspace: Path) -> Path:
    return getattr(args, "plan", None) or to_submit_json(workspace)


def _load_doctors(args: argparse.Namespace, workspace: Path) -> list:
    if getattr(args, "doctors", None):
        data = load_json(args.doctors)
        if isinstance(data, dict) and isinstance(data.get("records"), list):
            return data["records"]
        return data
    api_cfg = merge_api_config(load_api_config(args.config))
    if getattr(args, "page_size", None) is not None:
        api_cfg["pageSize"] = args.page_size
    return fetch_doctors_with_cache(
        api_cfg,
        workspace,
        refresh=bool(getattr(args, "refresh_cache", False)),
        max_pages=getattr(args, "max_pages", None),
    )


def _load_export_index(args: argparse.Namespace) -> dict:
    if getattr(args, "export_index", None):
        return load_json(args.export_index)
    exports_dir = getattr(args, "exports_dir", None) or (project_root() / "exports")
    return build_export_index(exports_dir)


def cmd_export_reg(args: argparse.Namespace) -> int:
    """调用机构端 SOAP 接口导出最新主执业/多执业 xlsx 到 exports/reg-api。"""
    try:
        from src.minke_reg import (
            default_output_path as reg_default_output_path,
            export_main_records,
            export_multi_records,
            load_minke_reg_config,
            login_minke_reg,
            save_reg_workbook,
            save_reg_xlsx,
        )

        cfg = load_minke_reg_config(args.config)
        print("正在登录医师注册系统...")
        session = login_minke_reg(cfg)
        print(f"登录成功：{session.organ_name or session.login_id}")

        if not args.skip_main:
            print("正在拉取主执业列表并补全证号...")
            sheets = export_main_records(cfg, session)
            main_out = reg_default_output_path(cfg, "主执业")
            total = save_reg_workbook(sheets, main_out)
            print(f"主执业已保存 {total} 条到 {main_out}")

        if not args.skip_multi:
            print("正在拉取多执业医师列表...")
            multi_records = export_multi_records(cfg, session)
            multi_out = reg_default_output_path(cfg, "多执业")
            save_reg_xlsx(multi_records, multi_out)
            print(f"多执业已保存 {len(multi_records)} 条到 {multi_out}")

        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


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

        to_submit = result.get("toSubmit") or []
        submit_path = args.output or to_submit_json(workspace)
        save_json(submit_path, to_submit)

        report_path = args.report_output or reconcile_report_xlsx(workspace)
        save_reconcile_report(
            lianou_only=result.get("lianouOnly", []),
            export_only=result.get("exportOnly", []),
            to_submit=to_submit,
            output_path=report_path,
        )

        summary = result.get("summary", {})
        export_sources = (export_index.get("sources") or {}) if isinstance(export_index, dict) else {}
        save_json(
            reconcile_summary_json(workspace),
            {
                "summary": summary,
                "exportSources": export_sources,
                "artifacts": {
                    "toSubmit": str(submit_path),
                    "reconcileReport": str(report_path),
                },
            },
        )

        if args.debug:
            save_json(doctors_json(workspace), doctors)
            save_json(export_index_json(workspace), export_index)
            save_json(reconcile_result_json(workspace), result)
            print("[debug] saved debug/doctors.json, debug/export_index.json, debug/reconcile_result.json")
        print(
            "reconcile: "
            f"doctors={summary.get('doctors', 0)} "
            f"matchedDoctors={summary.get('matchedDoctors', 0)} "
            f"createOps={summary.get('createOps', 0)} "
            f"updateOps={summary.get('updateOps', 0)} "
            f"submitOps={summary.get('submitOps', 0)} "
            f"lianouOnly={summary.get('lianouOnly', 0)} "
            f"(noCert={summary.get('missingNoCert', 0)} "
            f"notInExport={summary.get('missingNotInExport', 0)} "
            f"nameMismatch={summary.get('nameMismatch', 0)}) "
            f"exportOnly={summary.get('exportOnly', 0)}"
        )
        print(f"saved to_submit.json -> {submit_path}")
        print(f"saved reconcile_report.xlsx -> {report_path}")
        print(f"saved reconcile_summary.json -> {reconcile_summary_json(workspace)}")

        dropped = summary.get("droppedFields") or {}
        if dropped:
            parts = [f"{field}={count}" for field, count in sorted(dropped.items(), key=lambda kv: (-kv[1], kv[0]))]
            print(
                "[WARN] 以下字段被莲藕 API 点名缺失，但机构端导出无法填充（已跳过）： "
                + ", ".join(parts),
                file=sys.stderr,
            )
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_submit(args: argparse.Namespace) -> int:
    try:
        workspace = _workspace(args)
        plan_path = _plan_path(args, workspace)
        if not plan_path.exists():
            raise FileNotFoundError(f"to_submit.json not found: {plan_path}")

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
        print(f"submit ({mode}): total={len(results)} ok={ok} failed={failed}")
        if failed and not dry_run:
            return 1
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_capture_institution(args: argparse.Namespace) -> int:
    try:
        workspace = _workspace(args)
        plan_path = _plan_path(args, workspace)
        if not plan_path.exists():
            raise FileNotFoundError(f"to_submit.json not found: {plan_path}")

        to_submit = load_json(plan_path)
        targets = iter_institution_capture_targets(to_submit)
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
        plan_path = _plan_path(args, workspace)
        if not plan_path.exists():
            raise FileNotFoundError(f"to_submit.json not found: {plan_path}")

        to_submit = load_json(plan_path)
        targets = iter_nhc_capture_targets(to_submit)

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


def cmd_rename_captures(args: argparse.Namespace) -> int:
    try:
        from src.capture.rename_by_export import rename_captures_by_ui_export, salvage_unmatched_by_ocr

        root = project_root()
        captures_root = args.captures_dir or (root / "captures")
        exports_root = args.exports_dir or (root / "exports")
        dry_run = not args.commit

        result = rename_captures_by_ui_export(
            captures_root=captures_root,
            exports_root=exports_root,
            dry_run=dry_run,
        )
        if getattr(args, "ocr_unmatched", False):
            ocr_result = salvage_unmatched_by_ocr(
                captures_root=captures_root,
                exports_root=exports_root,
                dry_run=dry_run,
            )
            result.renamed += ocr_result.renamed
            result.skipped_already += ocr_result.skipped_already
            result.conflicts += ocr_result.conflicts
            result.deleted += ocr_result.deleted
            result.ocr_failed += ocr_result.ocr_failed
            result.errors.extend(ocr_result.errors or [])

        mode = "dry-run" if dry_run else "commit"
        print(
            f"rename-captures ({mode}): renamed={result.renamed} "
            f"already={result.skipped_already} no_match={result.skipped_no_match} "
            f"name_mismatch={result.skipped_name_mismatch} conflicts={result.conflicts} "
            f"deleted={result.deleted} ocr_failed={result.ocr_failed}"
        )
        if result.errors:
            print(f"issues ({len(result.errors)}):")
            for line in result.errors[:30]:
                print(f"  {line}")
            if len(result.errors) > 30:
                print(f"  ... and {len(result.errors) - 30} more")
        if result.conflicts and not dry_run:
            return 1
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_rename_nhc(args: argparse.Namespace) -> int:
    try:
        from src.capture.paths import default_nhc_captures_dir
        from src.capture.rename_nhc import rename_nhc_screenshots

        root = project_root()
        source = args.source_dir or (root / "captures" / "screenshots")
        target = args.target_dir or default_nhc_captures_dir(root)
        dry_run = not args.commit

        result = rename_nhc_screenshots(
            source_dir=source,
            target_dir=target,
            exports_root=root / "exports",
            dry_run=dry_run,
            delete_source=not bool(getattr(args, "keep_source", False)),
        )
        mode = "dry-run" if dry_run else "commit"
        print(
            f"rename-nhc ({mode}): renamed={result.renamed} "
            f"already={result.skipped_already} unparsed={result.skipped_unparsed} "
            f"conflicts={result.conflicts}"
        )
        if result.errors:
            print(f"issues ({len(result.errors)}):")
            for line in result.errors[:20]:
                print(f"  {line}")
            if len(result.errors) > 20:
                print(f"  ... and {len(result.errors) - 20} more")
        if result.conflicts and not dry_run:
            return 1
        return 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_verify_nhc_captures(args: argparse.Namespace) -> int:
    try:
        from src.capture.verify_nhc import verify_nhc_captures
        from src.capture.paths import default_nhc_captures_dir

        root = project_root()
        nhc_dir = args.nhc_dir or default_nhc_captures_dir(root)
        report = args.report or (root / "logs" / "verify-nhc-report.csv")
        summary = verify_nhc_captures(
            captures_dir=nhc_dir,
            report_path=report,
            limit=int(args.limit or 0),
            force=bool(args.force),
        )
        problems = (
            summary.cert_mismatch
            + summary.name_mismatch
            + summary.both_mismatch
            + summary.bad_filename
        )
        return 1 if problems else 0
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_fill_images(args: argparse.Namespace) -> int:
    try:
        from src.lianou.writeback import encode_image_base64
        from src.reconcile.to_supplement import (
            capture_meta,
            needs_institution_capture,
            needs_nhc_capture,
            normalize_payloads,
            set_supplement_field,
        )

        workspace = _workspace(args)
        plan_path = _plan_path(args, workspace)
        if not plan_path.exists():
            raise FileNotFoundError(f"to_submit.json not found: {plan_path}")

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
            cert_code = str(meta.get("certCode") or "")

            touched = False
            if needs_institution_capture(payload):
                image = find_institution_image(captures_root, name, cert_code)
                if image:
                    set_supplement_field(
                        payload,
                        "institutionBase",
                        encode_image_base64(image, data_uri=client.image_data_uri),
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
                    set_supplement_field(
                        payload,
                        "healthCommissionBase",
                        encode_image_base64(image, data_uri=client.image_data_uri),
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
                print(f"[{status}] aId={result.a_id} {name}: {result.message}")
                if result.ok:
                    ok += 1
                else:
                    failed += 1
                    exit_code = 1
            elif touched and dry_run:
                print(f"[DRY] {name}: would upload after fill")

        save_json(plan_path, payloads)

        mode = "dry-run" if dry_run else "commit"
        print(f"fill-images ({mode}): filled={filled} ok={ok} skipped={skipped} failed={failed}")
        print(f"saved {plan_path}")
        return exit_code
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        return 1


def cmd_run_all(args: argparse.Namespace) -> int:
    steps = []
    if getattr(args, "with_export", False):
        steps.append(("export-reg", cmd_export_reg))
    steps.append(("reconcile", cmd_reconcile))
    if not args.skip_capture:
        steps.extend(
            [
                ("capture-institution", cmd_capture_institution),
                ("capture-nhc", cmd_capture_nhc),
                ("fill-images", cmd_fill_images),
            ]
        )
    if not args.skip_submit:
        steps.append(("submit", cmd_submit))

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

    export_reg = subparsers.add_parser(
        "export-reg", parents=[common], help="Export institution xlsx via Minke SOAP API"
    )
    export_reg.add_argument("--skip-main", action="store_true", help="跳过主执业导出")
    export_reg.add_argument("--skip-multi", action="store_true", help="跳过多执业导出")
    export_reg.set_defaults(func=cmd_export_reg)

    fetch = subparsers.add_parser("fetch", parents=[common], help="Fetch Lianou doctors")
    fetch.add_argument("--output-json", type=Path, default=None, help="Output doctors.json path")
    fetch.add_argument("--save-json", action="store_true", help="Save doctors.json to workspace")
    fetch.add_argument("--page-size", type=int, default=None)
    fetch.add_argument("--max-pages", type=int, default=None)
    fetch.set_defaults(func=cmd_fetch)

    parse_exports = subparsers.add_parser(
        "parse-exports", parents=[common], help="Parse latest institution exports"
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
        "reconcile", parents=[common], help="Reconcile doctors and build to_submit.json"
    )
    reconcile.add_argument("--doctors", type=Path, default=None, help="Use existing doctors.json")
    reconcile.add_argument("--export-index", type=Path, default=None, help="Use existing export index")
    reconcile.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output to_submit.json path (default: workspace/to_submit.json)",
    )
    reconcile.add_argument(
        "--report-output",
        type=Path,
        default=None,
        help="核对报告 xlsx（默认 workspace/reconcile_report.xlsx，含三个 sheet）",
    )
    reconcile.add_argument("--exports-dir", type=Path, default=None)
    reconcile.add_argument("--page-size", type=int, default=None)
    reconcile.add_argument("--max-pages", type=int, default=None)
    reconcile.set_defaults(func=cmd_reconcile)

    submit = subparsers.add_parser(
        "submit",
        parents=[common],
        aliases=["supplement"],
        help="Submit operations to Lianou (UpdateDoctorMedical, operationType 0/1)",
    )
    submit.add_argument(
        "--plan",
        type=Path,
        default=None,
        help="Path to to_submit.json (default: workspace/to_submit.json)",
    )
    submit.add_argument(
        "--include-images",
        action="store_true",
        help="Also submit healthCommissionBase/institutionBase when present in JSON",
    )
    submit.add_argument(
        "--commit", action="store_true", help="Actually call the update API (default: dry-run)"
    )
    submit.set_defaults(func=cmd_submit)

    capture_institution = subparsers.add_parser(
        "capture-institution",
        parents=[common],
        help="Capture institution-side screenshots for missing institutionBase",
    )
    capture_institution.add_argument(
        "--plan",
        type=Path,
        default=None,
        help="Path to to_submit.json (default: workspace/to_submit.json)",
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
        help="Path to to_submit.json (default: workspace/to_submit.json)",
    )
    capture_nhc.add_argument("--output-dir", type=Path, default=None)
    capture_nhc.add_argument("--province", default=None, help="所在省份（默认读 config 或广东省）")
    capture_nhc.add_argument("--hospital", default=None, help="所在医疗机构（默认读 config 或莲藕健康医院）")
    capture_nhc.add_argument("--interval", type=int, default=None, help="查询间隔秒数")
    capture_nhc.add_argument("--show-browser", action="store_true", help="显示浏览器（默认无头）")
    capture_nhc.add_argument("--dry-run", action="store_true")
    capture_nhc.set_defaults(func=cmd_capture_nhc)

    rename_captures = subparsers.add_parser(
        "rename-captures",
        parents=[common],
        help="Rename capture PNGs via exports/ui 身份证号→执业证书编码",
    )
    rename_captures.add_argument("--captures-dir", type=Path, default=None)
    rename_captures.add_argument(
        "--exports-dir",
        type=Path,
        default=None,
        help="Root exports directory (reads exports/ui/*.xls|xlsx)",
    )
    rename_captures.add_argument(
        "--ocr-unmatched",
        action="store_true",
        help="对仍未匹配的图片 OCR 执业证书编码：在导出表中有则重命名，否则删除",
    )
    rename_captures.add_argument(
        "--commit", action="store_true", help="Actually rename files (default: dry-run)"
    )
    rename_captures.set_defaults(func=cmd_rename_captures)

    rename_nhc = subparsers.add_parser(
        "rename-nhc",
        parents=[common],
        help="Normalize 卫健委 screenshots to 姓名_执业证书编号.png under captures/卫健委",
    )
    rename_nhc.add_argument(
        "--source-dir",
        type=Path,
        default=None,
        help="Source NHC screenshots (default: captures/screenshots)",
    )
    rename_nhc.add_argument(
        "--target-dir",
        type=Path,
        default=None,
        help="Output directory (default: captures/卫健委)",
    )
    rename_nhc.add_argument(
        "--keep-source",
        action="store_true",
        help="Copy/rename in place; do not remove duplicates from source after move",
    )
    rename_nhc.add_argument(
        "--commit", action="store_true", help="Actually rename/move files (default: dry-run)"
    )
    rename_nhc.set_defaults(func=cmd_rename_nhc)

    verify_nhc = subparsers.add_parser(
        "verify-nhc-captures",
        parents=[common],
        help="OCR verify 卫健委 screenshots: filename 姓名/证号 vs screenshot content",
    )
    verify_nhc.add_argument(
        "--nhc-dir",
        type=Path,
        default=None,
        help="NHC captures directory (default: captures/卫健委)",
    )
    verify_nhc.add_argument(
        "--report",
        type=Path,
        default=None,
        help="CSV report path (default: logs/verify-nhc-report.csv)",
    )
    verify_nhc.add_argument(
        "--limit",
        type=int,
        default=0,
        help="Only verify the first N files (0 = all pending)",
    )
    verify_nhc.add_argument(
        "--force",
        action="store_true",
        help="Re-verify all files, ignoring previously passed records in the report",
    )
    verify_nhc.set_defaults(func=cmd_verify_nhc_captures)

    fill_images = subparsers.add_parser(
        "fill-images",
        parents=[common],
        aliases=["upload-images"],
        help="Fill captured images (base64) into to_submit.json and optionally upload",
    )
    fill_images.add_argument(
        "--plan",
        type=Path,
        default=None,
        help="Path to to_submit.json (default: workspace/to_submit.json)",
    )
    fill_images.add_argument("--captures-dir", type=Path, default=None)
    fill_images.add_argument("--nhc-dir", type=Path, default=None)
    fill_images.add_argument(
        "--commit", action="store_true", help="Actually call the update API (default: dry-run)"
    )
    fill_images.set_defaults(func=cmd_fill_images)

    run_all = subparsers.add_parser("run-all", parents=[common], help="Run full pipeline")
    run_all.add_argument("--with-export", action="store_true", help="先跑机构端 SOAP 导出")
    run_all.add_argument("--skip-main", action="store_true")
    run_all.add_argument("--skip-multi", action="store_true")
    run_all.add_argument("--exports-dir", type=Path, default=None)
    run_all.add_argument("--doctors", type=Path, default=None)
    run_all.add_argument("--export-index", type=Path, default=None)
    run_all.add_argument("--output", type=Path, default=None)
    run_all.add_argument("--report-output", type=Path, default=None)
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
        "--commit", action="store_true", help="Actually write back to Lianou (submit/fill-images)"
    )
    run_all.add_argument("--include-images", action="store_true")
    run_all.add_argument("--skip-submit", action="store_true")
    run_all.add_argument("--skip-capture", action="store_true")
    run_all.set_defaults(func=cmd_run_all)
