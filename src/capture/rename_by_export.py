"""Rename institution capture PNGs using export 身份证号 → 执业证书编码 mapping."""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from src.institution_export import extract_cert_code, parse_export_file
from src.institution_export.parser import find_latest_exports
from src.institution_export.paths import EXPORT_UI_DIR
from src.reconcile.matcher import normalize_id_card, normalize_name

_ID_SUFFIX_PATTERN = re.compile(r"^(?P<name>.+)_(?P<suffix>[0-9A-Za-z]{15,18})$")


@dataclass
class RenameResult:
    renamed: int = 0
    skipped_already: int = 0
    skipped_no_match: int = 0
    skipped_name_mismatch: int = 0
    conflicts: int = 0
    deleted: int = 0
    ocr_failed: int = 0
    errors: list[str] | None = None

    def __post_init__(self) -> None:
        if self.errors is None:
            self.errors = []


def _export_id_card(row: dict[str, Any]) -> str:
    for key in ("身份证号", "身份证", "iDCard", "idCard"):
        value = row.get(key)
        if value is not None and str(value).strip():
            return normalize_id_card(str(value))
    return ""


def _export_name(row: dict[str, Any]) -> str:
    return normalize_name(row.get("姓名") or row.get("doctorName"))


def build_id_lookup(rows: list[dict[str, Any]]) -> dict[str, dict[str, str]]:
    """身份证号 → {name, certCode}（同证号多行时保留首条）。"""
    out: dict[str, dict[str, str]] = {}
    for row in rows:
        id_card = _export_id_card(row)
        cert = extract_cert_code(row)
        if not id_card or not cert:
            continue
        if id_card in out:
            continue
        out[id_card] = {"name": _export_name(row), "certCode": cert}
    return out


def build_cert_lookup(rows: list[dict[str, Any]]) -> dict[str, dict[str, str]]:
    """执业证书编码 → {name, certCode}。"""
    out: dict[str, dict[str, str]] = {}
    for row in rows:
        cert = extract_cert_code(row)
        if not cert:
            continue
        norm_cert = normalize_id_card(cert)
        if norm_cert in out:
            continue
        out[norm_cert] = {"name": _export_name(row), "certCode": cert}
    return out


def load_ui_export_lookups(
    exports_root: Path,
) -> tuple[dict[str, dict[str, str]], dict[str, dict[str, str]], dict[str, dict[str, str]], dict[str, dict[str, str]]]:
    ui_dir = exports_root / EXPORT_UI_DIR
    main_path = multi_path = None
    for path in sorted(ui_dir.glob("主执业导出-*.*")):
        if path.stat().st_size > 0:
            main_path = path
    for path in sorted(ui_dir.glob("多执业导出-*.*")):
        if path.stat().st_size > 0:
            multi_path = path

    main_rows = parse_export_file(main_path) if main_path else []
    multi_rows = parse_export_file(multi_path) if multi_path else []
    main_id = build_id_lookup(main_rows)
    multi_id = build_id_lookup(multi_rows)
    main_cert = build_cert_lookup(main_rows)
    multi_cert = build_cert_lookup(multi_rows)
    return main_id, multi_id, main_cert, multi_cert


def load_all_export_cert_lookup(exports_root: Path) -> dict[str, dict[str, str]]:
    """合并 exports/ui 与 exports/reg-api 全部导出中的执业证书编码。"""
    rows: list[dict[str, Any]] = []
    ui_dir = exports_root / EXPORT_UI_DIR
    if ui_dir.is_dir():
        for pattern in ("主执业导出-*.*", "多执业导出-*.*"):
            for path in ui_dir.glob(pattern):
                if path.stat().st_size > 0:
                    rows.extend(parse_export_file(path))
    latest = find_latest_exports(exports_root)
    if latest.main:
        rows.extend(parse_export_file(latest.main))
    if latest.multi:
        rows.extend(parse_export_file(latest.multi))
    return build_cert_lookup(rows)


def _filename_name(path: Path) -> str:
    stem = path.stem
    if "_" in stem:
        return stem.rsplit("_", 1)[0]
    return stem


def iter_unmatched_capture_paths(
    captures_root: Path,
    exports_root: Path,
) -> list[Path]:
    main_id, multi_id, main_cert, multi_cert = load_ui_export_lookups(exports_root)
    all_cert = load_all_export_cert_lookup(exports_root)
    unmatched: list[Path] = []

    for folder_name in ("主执业", "多执业"):
        folder = captures_root / folder_name
        if not folder.is_dir():
            continue
        for path in sorted(folder.glob("*.png")):
            parsed = _parse_capture_filename(path)
            if parsed:
                file_name, suffix = parsed
                if _already_cert_named(file_name, suffix, folder_name, main_cert, multi_cert):
                    continue
                if _lookup_for_folder(folder_name, suffix, main_id, multi_id):
                    continue
                if suffix in all_cert:
                    continue
            unmatched.append(path)
    return unmatched


def salvage_unmatched_by_ocr(
    *,
    captures_root: Path,
    exports_root: Path,
    dry_run: bool = True,
) -> RenameResult:
    """对仍未匹配的图片 OCR 执业证书编码：在导出表中有则重命名，否则删除。"""
    all_cert = load_all_export_cert_lookup(exports_root)
    result = RenameResult()
    paths = iter_unmatched_capture_paths(captures_root, exports_root)

    from .cert_ocr import make_ocr_engine, ocr_cert_from_image

    engine = make_ocr_engine()
    for path in paths:
        file_name = _filename_name(path)
        try:
            ocr_cert, conf = ocr_cert_from_image(engine, path)
        except Exception as exc:
            result.ocr_failed += 1
            result.errors.append(f"ocr error {path.name}: {exc}")
            if dry_run:
                print(f"[DRY DELETE] {path.name} (OCR 异常: {exc})")
            else:
                path.unlink()
                print(f"[DELETE] {path.name} (OCR 异常: {exc})")
            result.deleted += 1
            continue

        if not ocr_cert:
            result.ocr_failed += 1
            if dry_run:
                print(f"[DRY DELETE] {path.name} (OCR 未识别到执业证书编码)")
            else:
                path.unlink()
                print(f"[DELETE] {path.name} (OCR 未识别到执业证书编码)")
            result.deleted += 1
            result.errors.append(f"ocr missing cert: {path.name}")
            continue

        norm_cert = normalize_id_card(ocr_cert)
        entry = all_cert.get(norm_cert)
        if entry is None:
            if dry_run:
                print(f"[DRY DELETE] {path.name} (OCR={ocr_cert} 不在导出表)")
            else:
                path.unlink()
                print(f"[DELETE] {path.name} (OCR={ocr_cert} 不在导出表)")
            result.deleted += 1
            result.errors.append(f"ocr cert not in export {ocr_cert}: {path.name}")
            continue

        export_name = entry["name"]
        cert = entry["certCode"]
        target = path.parent / f"{file_name}_{cert}.png"
        if path.resolve() == target.resolve():
            result.skipped_already += 1
            continue
        if target.exists() and target.resolve() != path.resolve():
            result.conflicts += 1
            result.errors.append(f"target exists: {target.name} (from {path.name}, ocr={ocr_cert})")
            continue
        if export_name and normalize_name(file_name) != export_name:
            result.errors.append(
                f"ocr rename name note file={file_name} export={export_name} cert={cert}"
            )

        if dry_run:
            print(f"[DRY OCR] {path.name} -> {target.name} (ocr={ocr_cert}, conf={conf:.3f})")
        else:
            path.rename(target)
            print(f"[OK OCR] {path.name} -> {target.name} (ocr={ocr_cert}, conf={conf:.3f})")
        result.renamed += 1

    return result


def _parse_capture_filename(path: Path) -> tuple[str, str] | None:
    match = _ID_SUFFIX_PATTERN.match(path.stem)
    if not match:
        return None
    name = match.group("name")
    suffix = normalize_id_card(match.group("suffix"))
    if not suffix:
        return None
    return name, suffix


def _lookup_for_folder(
    folder_name: str,
    key: str,
    main_lookup: dict[str, dict[str, str]],
    multi_lookup: dict[str, dict[str, str]],
) -> dict[str, str] | None:
    if folder_name == "多执业":
        return multi_lookup.get(key) or main_lookup.get(key)
    return main_lookup.get(key) or multi_lookup.get(key)


def _already_cert_named(
    file_name: str,
    suffix: str,
    folder_name: str,
    main_cert: dict[str, dict[str, str]],
    multi_cert: dict[str, dict[str, str]],
) -> bool:
    entry = _lookup_for_folder(folder_name, suffix, main_cert, multi_cert)
    if entry is None:
        return False
    export_name = entry["name"]
    return not export_name or normalize_name(file_name) == export_name


def rename_captures_by_ui_export(
    *,
    captures_root: Path,
    exports_root: Path,
    dry_run: bool = True,
) -> RenameResult:
    main_id, multi_id, main_cert, multi_cert = load_ui_export_lookups(exports_root)
    result = RenameResult()

    for folder_name in ("主执业", "多执业"):
        folder = captures_root / folder_name
        if not folder.is_dir():
            continue
        for path in sorted(folder.glob("*.png")):
            parsed = _parse_capture_filename(path)
            if parsed is None:
                result.skipped_no_match += 1
                result.errors.append(f"unrecognized filename: {path}")
                continue

            file_name, id_card = parsed

            if _already_cert_named(file_name, id_card, folder_name, main_cert, multi_cert):
                result.skipped_already += 1
                continue

            entry = _lookup_for_folder(folder_name, id_card, main_id, multi_id)
            if entry is None:
                result.skipped_no_match += 1
                result.errors.append(f"no export row for id {id_card}: {path.name}")
                continue

            export_name = entry["name"]
            cert = entry["certCode"]
            if export_name and normalize_name(file_name) != export_name:
                result.skipped_name_mismatch += 1
                result.errors.append(
                    f"name mismatch file={file_name} export={export_name} id={id_card}: {path.name}"
                )
                continue

            # 已是 姓名_执业证书编码.png（lookup 命中身份证分支时的冗余保护）
            if id_card == cert or normalize_id_card(cert) == id_card:
                result.skipped_already += 1
                continue

            target = folder / f"{file_name}_{cert}.png"
            if path.resolve() == target.resolve():
                result.skipped_already += 1
                continue
            if target.exists() and target.resolve() != path.resolve():
                result.conflicts += 1
                result.errors.append(f"target exists: {target.name} (from {path.name})")
                continue

            if dry_run:
                print(f"[DRY] {path.name} -> {target.name}")
            else:
                path.rename(target)
                print(f"[OK] {path.name} -> {target.name}")
            result.renamed += 1

    return result
